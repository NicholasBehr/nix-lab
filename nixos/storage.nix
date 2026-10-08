{
  config,
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
  maintenance = config.homelab.maintenance;
  runner = "${maintenance.package}/bin/maintenance-runner";
  storageGuard = "${runner} check-storage ${lib.escapeShellArg maintenance.stateDirectory}";
  storageWriters = lib.unique (lib.concatMap (participant: participant.writerUnits) (lib.attrValues maintenance.participants));

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

  # The coordinator owns suspension; the mover only owns file transactions.
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
    maintenanceStateDirectory = maintenance.stateDirectory;
    requireInactiveServices =
      [
        "snapraid-sync"
        "snapraid-scrub"
      ]
      ++ map (lib.removeSuffix ".service") storageWriters;
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

    scrub = {
      plan = 8;
      olderThan = 10;
    };
  };

  homelab.maintenance = {
    requiredMounts = [dataPoolMountpoint cacheMountpoint] ++ disks.hddMountpoints;
    conflictingUnits = ["tier-mover.service" "snapraid-sync.service" "snapraid-scrub.service"];
    storageTasks = [
      {
        name = "tier-mover";
        script = "exec ${config.homelab.tierMover.command}";
        recovery = "exec ${config.homelab.tierMover.command} --recover-only";
        timeoutSeconds = config.homelab.tierMover.maximumRunSeconds + 300;
        successExitCodes = [0 2];
      }
      {
        name = "snapraid-sync";
        script = ''
          ${storageGuard}
          # Retain SnapRAID's missing-disk/empty-file safety checks; never pass
          # force flags during automatic maintenance.
          ${pkgs.snapraid}/bin/snapraid touch
          exec ${pkgs.snapraid}/bin/snapraid sync
        '';
      }
      {
        name = "snapraid-scrub";
        weekdays = [7];
        script = ''
          ${storageGuard}
          exec ${pkgs.snapraid}/bin/snapraid scrub \
            -p ${toString config.services.snapraid.scrub.plan} \
            -o ${toString config.services.snapraid.scrub.olderThan}
        '';
      }
    ];
  };

  systemd = {
    tmpfiles.rules = map (
      mountpoint: "d ${mountpoint}/${snapraidMetadataDirectory} 0700 root root -"
    ) ([cacheMountpoint] ++ disks.hddMountpoints);

    services = {
      snapraid-sync = {
        startAt = lib.mkForce [];
        # Keep the old entry point from starting an independent sync. The
        # actual foreground command is owned by maintenance above.
        serviceConfig.ExecStartPre = lib.mkForce [storageGuard];
        unitConfig.RequiresMountsFor =
          [cacheMountpoint] ++ disks.hddMountpoints;
      };

      snapraid-scrub = {
        startAt = lib.mkForce [];
        serviceConfig.ExecStartPre = storageGuard;
        unitConfig.RequiresMountsFor = [cacheMountpoint] ++ disks.hddMountpoints;
      };
    };
  };
}
