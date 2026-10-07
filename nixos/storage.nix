{
  lib,
  pkgs,
  ...
}: let
  disks = import ./disks.nix;

  cacheMountpoint = disks.nvmeDataMountpoint;
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
        "fsname=mergerfs-data"
      ];
  };

  # Move cold files directly between backing filesystems. Applications keep
  # using /data, and are stopped only when a run actually needs to move files.
  homelab.tierMover = {
    enable = true;
    source = cacheMountpoint;
    destinations = disks.hddDataMountpoints;
    stateDirectory = "/persist128/var/lib/tier-mover";
    startAboveUsed = "2T";
    stopAtUsed = "1800G";
    initialMinFileSize = "40G";
    minimumFileSize = "1M";
    sizeThresholdPercent = 90;
    destinationFreeReserve = "100G";
    quiesceServices = [
      "nextcloud-setup"
      "phpfpm-nextcloud"
      "nextcloud-cron"
      "nextcloud-update-db"
    ];
    requireInactiveServices = [
      "snapraid-sync"
      "snapraid-scrub"
    ];
    timer = {
      enable = true;
      interval = "hourly";
    };
  };

  services.snapraid = {
    enable = true;
    inherit dataDisks parityFiles contentFiles;
    exclude = [
      "/lost+found/"
      "/.snapraid/"
      "/.tier-mover/"
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
