{
  lib,
  pkgs,
  ...
}: let
  disks = import ./disks.nix;

  cacheMountpoint = disks.nvmeDataMountpoint;
  hddPoolMountpoint = "/hdd_data";
  dataPoolMountpoint = "/data";
  snapraidMetadataDirectory = ".snapraid";

  dataDisks = builtins.listToAttrs (
    lib.imap1 (index: mountpoint: {
      name = "data${toString index}";
      value = mountpoint;
    })
    disks.hddDataMountpoints
  );

  parityFiles =
    map (
      mountpoint: "${mountpoint}/snapraid.parity"
    )
    disks.hddParityMountpoints;

  # Keep redundant content files on independent disks. SnapRAID requires at
  # least one more content file than the configured number of parity files.
  contentFiles = map (
    mountpoint: "${mountpoint}/${snapraidMetadataDirectory}/snapraid.content"
  ) ([cacheMountpoint] ++ disks.hddMountpoints);

  allDataBranches = [cacheMountpoint] ++ disks.hddDataMountpoints;

  mergerfsCommonOptions = [
    "cache.files=off"
    "func.getattr=newest"
    "dropcacheonclose=false"
    "minfreespace=100G"
    # NixOS `depends` below already requires and orders the branch mounts.
    # mergerFS 2.40.2 supports this wait option, but not the newer
    # `branches-mount-timeout-fail` option.
    "branches-mount-timeout=30"
  ];
in {
  environment.systemPackages = [
    pkgs.mergerfs
  ];

  # HDD-only pool. mfs selects the eligible HDD
  # with the most absolute free space for each new file.
  fileSystems.${hddPoolMountpoint} = {
    fsType = "fuse.mergerfs";
    device = builtins.concatStringsSep ":" disks.hddDataMountpoints;
    depends = disks.hddDataMountpoints;
    options =
      mergerfsCommonOptions
      ++ [
        "category.create=mfs"
        "moveonenospc=mfs"
        "fsname=mergerfs-hdd-data"
      ];
  };

  # User-facing pool. ff selects the first eligible branch, so new files land
  # on NVMe while it has at least minfreespace available, then spill to HDD.
  fileSystems.${dataPoolMountpoint} = {
    fsType = "fuse.mergerfs";
    device = builtins.concatStringsSep ":" allDataBranches;
    depends = allDataBranches;
    options =
      mergerfsCommonOptions
      ++ [
        "category.create=ff"
        "moveonenospc=mfs"
        "fsname=mergerfs-data"
      ];
  };

  services.snapraid = {
    enable = true;
    inherit dataDisks parityFiles contentFiles;
    exclude = [
      "/lost+found/"
      "/.snapraid/"
      ".Trash-*/"
      "@Recycle/"
    ];

    sync.interval = "*-*-* 03:00:00";
    scrub = {
      interval = "Sun *-*-* 04:00:00";
      plan = 8;
      olderThan = 10;
    };
  };

  systemd = {
    tmpfiles.rules = map (
      mountpoint: "d ${mountpoint}/${snapraidMetadataDirectory} 0700 root root -"
    ) ([cacheMountpoint] ++ disks.hddMountpoints);

    services = {
      snapraid-sync = {
        unitConfig.RequiresMountsFor =
          [cacheMountpoint] ++ disks.hddMountpoints;
      };

      snapraid-scrub.unitConfig.RequiresMountsFor =
        [cacheMountpoint] ++ disks.hddMountpoints;
    };
  };
}
