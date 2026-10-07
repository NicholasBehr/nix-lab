{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.tierMover;
  inherit (lib) mkEnableOption mkIf mkOption types;
  absolutePath = types.strMatching "/[a-zA-Z0-9_./-]+";
  absoluteSize = types.strMatching "[0-9]+(B|K|KiB|KB|M|MiB|MB|G|GiB|GB|T|TiB|TB)?";
  package = pkgs.callPackage ../../pkgs/tier-mover {};
  storageRoots = [cfg.source] ++ cfg.destinations;
  filesystemAt = path: let
    filesystem = config.fileSystems.${path} or {};
  in {
    device = filesystem.device or "";
    fsType = filesystem.fsType or "";
  };
  sourceFilesystem = filesystemAt cfg.source;
  sourceUsesZfs = sourceFilesystem.fsType == "zfs";
  expectedFilesystems = builtins.listToAttrs (
    map (path: lib.nameValuePair path (filesystemAt path)) storageRoots
  );
  unitNames = map (name: "${name}.service") cfg.quiesceServices;
  inactiveUnitNames = map (name: "${name}.service") cfg.requireInactiveServices;
  guardedServices = lib.unique (cfg.quiesceServices ++ cfg.requireInactiveServices);
  runtimeConfig = {
    inherit
      (cfg)
      source
      destinations
      stateDirectory
      startAboveUsed
      stopAtUsed
      initialMinFileSize
      minimumFileSize
      sizeThresholdPercent
      destinationFreeReserve
      minimumModificationAgeSeconds
      maximumRunSeconds
      exclude
      ;
    inherit expectedFilesystems;
    allowSameFilesystem = false;
    requireMountpoints = true;
    usage =
      if sourceUsesZfs
      then "zfs"
      else "filesystem";
    zfsDataset =
      if sourceUsesZfs
      then sourceFilesystem.device
      else null;
    accountingSettleSeconds = 5;
    noProgressLimit = 3;
    maxParallelMoves = builtins.length cfg.destinations;
    quiesceUnits = unitNames;
    requireInactiveUnits = inactiveUnitNames;
  };
  configFile = pkgs.writeText "tier-mover.json" (builtins.toJSON runtimeConfig);
in {
  options.homelab.tierMover = {
    enable = mkEnableOption "one-way storage tier mover";
    source = mkOption {
      type = absolutePath;
      description = "Fast source mountpoint; it must be declared in NixOS fileSystems.";
    };
    destinations = mkOption {
      type = types.listOf absolutePath;
      description = "Independent destination mountpoints declared in NixOS fileSystems.";
    };
    stateDirectory = mkOption {
      type = absolutePath;
      default = "/var/lib/tier-mover";
      description = "Persistent transaction journal directory.";
    };
    startAboveUsed = mkOption {
      type = absoluteSize;
      default = "2T";
      description = "Start moving when source usage exceeds this absolute size.";
    };
    stopAtUsed = mkOption {
      type = absoluteSize;
      default = "1800G";
      description = "Stop moving when source usage reaches this absolute size.";
    };
    initialMinFileSize = mkOption {
      type = absoluteSize;
      default = "40G";
      description = "Initial minimum logical size of a move candidate.";
    };
    minimumFileSize = mkOption {
      type = absoluteSize;
      default = "1M";
      description = "Lowest minimum candidate size after threshold reduction.";
    };
    sizeThresholdPercent = mkOption {
      type = types.ints.between 1 99;
      default = 90;
      description = "Percentage retained each time the candidate-size threshold shrinks.";
    };
    destinationFreeReserve = mkOption {
      type = absoluteSize;
      default = "100G";
      description = "Free space reserved independently on every destination.";
    };
    minimumModificationAgeSeconds = mkOption {
      type = types.ints.unsigned;
      default = 3600;
      description = "Minimum age of both modification and inode-change timestamps.";
    };
    maximumRunSeconds = mkOption {
      type = types.ints.positive;
      default = 7200;
      description = "Maximum duration of one mover invocation.";
    };
    exclude = mkOption {
      type = types.listOf types.str;
      default = [".snapraid" ".zfs" "lost+found"];
      description = "Relative source paths to exclude, including all descendants.";
    };
    quiesceServices = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+");
      default = [];
      description = "Services stopped during moves and guarded while recovery is pending; omit .service.";
    };
    requireInactiveServices = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+");
      default = [];
      description = "Services that must be inactive and are guarded while moving; omit .service.";
    };
    timer = {
      enable = mkEnableOption "periodic tier-mover runs";
      interval = mkOption {
        type = types.str;
        default = "hourly";
        description = "systemd OnCalendar expression.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.destinations != [];
        message = "homelab.tierMover.destinations must not be empty.";
      }
      {
        assertion = builtins.length storageRoots == builtins.length (lib.unique storageRoots);
        message = "homelab.tierMover source and destinations must be distinct.";
      }
      {
        assertion = lib.all (path: builtins.hasAttr path config.fileSystems) storageRoots;
        message = "homelab.tierMover storage roots must be declared NixOS fileSystems.";
      }
      {
        assertion = lib.all (path: let
          filesystem = filesystemAt path;
        in
          filesystem.device != "" && filesystem.fsType != "")
        storageRoots;
        message = "homelab.tierMover storage roots must declare a device and filesystem type.";
      }
    ];

    environment = {
      etc."tier-mover/config.json".source = configFile;
      systemPackages = [package];
    };

    systemd = {
      tmpfiles.rules = ["d ${cfg.stateDirectory} 0700 root root -"];

      services =
        {
          tier-mover = {
            description = "Move cold files out of the source storage tier";
            path =
              [pkgs.systemd pkgs.util-linux]
              ++ lib.optional sourceUsesZfs config.boot.zfs.package;
            unitConfig = {
              RequiresMountsFor = [cfg.source cfg.stateDirectory] ++ cfg.destinations;
              After = ["local-fs.target"] ++ unitNames;
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${package}/bin/tier-mover --config /etc/tier-mover/config.json";
              SuccessExitStatus = [2];
              Nice = 19;
              IOSchedulingClass = "idle";
              IOSchedulingPriority = 7;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectSystem = "strict";
              ProtectHome = "read-only";
              ReadWritePaths = [cfg.source cfg.stateDirectory] ++ cfg.destinations;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
            };
          };
        }
        // lib.genAttrs guardedServices (_: {
          unitConfig.ConditionPathExists = lib.mkAfter ["!${cfg.stateDirectory}/maintenance.json"];
        });

      timers.tier-mover = mkIf cfg.timer.enable {
        description = "Periodically check the source storage tier";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.timer.interval;
          Persistent = true;
          RandomizedDelaySec = "10m";
          Unit = "tier-mover.service";
        };
      };
    };
  };
}
