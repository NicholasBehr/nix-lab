{
  config,
  lib,
  pkgs,
  ...
}:
let
  disks = import ./disks.nix;

  # Keep this small while validating eviction. Change to "2T" for production.
  cacheLimit = "2G";
  cacheMountpoint = disks.nvmeDataMountpoint;
  hddPoolMountpoint = "/hdd_data";
  dataPoolMountpoint = "/data";
  snapraidMetadataDirectory = ".snapraid";

  dataDisks = builtins.listToAttrs (
    lib.imap1 (index: mountpoint: {
      name = "data${toString index}";
      value = mountpoint;
    }) disks.hddDataMountpoints
  );

  parityFiles = map (
    mountpoint: "${mountpoint}/snapraid.parity"
  ) disks.hddParityMountpoints;

  # Keep redundant content files on independent disks. SnapRAID requires at
  # least one more content file than the configured number of parity files.
  contentFiles = map (
    mountpoint: "${mountpoint}/${snapraidMetadataDirectory}/snapraid.content"
  ) ([ cacheMountpoint ] ++ disks.hddMountpoints);

  allDataBranches = [ cacheMountpoint ] ++ disks.hddDataMountpoints;

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

  storageMover = pkgs.writers.writePython3Bin "storage-mover" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./storage-mover.py);
in
{
  environment.systemPackages = [
    pkgs.mergerfs
    storageMover
  ];

  # HDD-only pool used as the mover destination. mfs selects the eligible HDD
  # with the most absolute free space for each new file.
  fileSystems.${hddPoolMountpoint} = {
    fsType = "fuse.mergerfs";
    device = builtins.concatStringsSep ":" disks.hddDataMountpoints;
    depends = disks.hddDataMountpoints;
    options = mergerfsCommonOptions ++ [
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
    options = mergerfsCommonOptions ++ [
      "category.create=ff"
      "moveonenospc=mfs"
      "fsname=mergerfs-data"
    ];
  };

  systemd.tmpfiles.rules = map (
    mountpoint:
    "d ${mountpoint}/${snapraidMetadataDirectory} 0700 root root -"
  ) ([ cacheMountpoint ] ++ disks.hddMountpoints);

  services.snapraid = {
    enable = true;
    inherit dataDisks parityFiles contentFiles;
    exclude = [
      "/lost+found/"
      "/.snapraid/"
      ".Trash-*/"
      "@Recycle/"
      ".storage-mover-tmp-*"
    ];

    # Run after the 02:00 mover. Explicit service ordering also makes a late
    # mover delay the sync rather than allowing both to touch the HDDs.
    sync.interval = "*-*-* 03:00:00";
    scrub = {
      interval = "Sun *-*-* 04:00:00";
      plan = 8;
      olderThan = 10;
    };
  };

  systemd.services = {
    # Disko applies dataset properties when it creates/formats storage. Enforce
    # these two mutable properties at boot as well for an existing dataset.
    nvme-data-atime = {
      description = "Enable relative access times on the NVMe data dataset";
      wantedBy = [ "multi-user.target" ];
      before = [ "storage-mover.service" ];
      unitConfig.RequiresMountsFor = cacheMountpoint;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.boot.zfs.package}/bin/zfs set atime=on relatime=on zpool/nvme_data1";
      };
    };

    storage-mover = {
      description = "Evict least-recently-accessed files from NVMe to HDD";
      requires = [ "nvme-data-atime.service" ];
      after = [ "nvme-data-atime.service" ];
      unitConfig.RequiresMountsFor = [
        cacheMountpoint
        hddPoolMountpoint
      ];
      before = [ "snapraid-sync.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.concatStringsSep " " [
          "${storageMover}/bin/storage-mover"
          "--source ${lib.escapeShellArg cacheMountpoint}"
          "--destination ${lib.escapeShellArg hddPoolMountpoint}"
          "--limit ${lib.escapeShellArg cacheLimit}"
          "--minimum-mtime-age 300"
          # A crashed copy is tracked on NVMe and removed after this grace
          # period; no full scan of the HDD pool is needed.
          "--stale-temp-age 3600"
          "--rsync ${pkgs.rsync}/bin/rsync"
          "--fuser ${pkgs.psmisc}/bin/fuser"
        ];
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
        CPUSchedulingPolicy = "batch";

        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
          "CAP_SYS_PTRACE"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cacheMountpoint
          hddPoolMountpoint
        ];
        RestrictAddressFamilies = "none";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
        SystemCallErrorNumber = "EPERM";
      };
    };

    snapraid-sync = {
      after = [ "storage-mover.service" ];
      unitConfig.RequiresMountsFor =
        [ cacheMountpoint ] ++ disks.hddMountpoints;
    };

    snapraid-scrub.unitConfig.RequiresMountsFor =
      [ cacheMountpoint ] ++ disks.hddMountpoints;
  };

  systemd.timers.storage-mover = {
    description = "Nightly NVMe cache eviction";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
      Unit = "storage-mover.service";
    };
  };
}
