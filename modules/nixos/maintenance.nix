# Fixed lifecycle; application/storage modules contribute opaque foreground hooks.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.maintenance;
  inherit (lib) mkEnableOption mkIf mkOption types;
  absolutePath = types.strMatching "/[a-zA-Z0-9_./-]+";
  serviceUnit = types.strMatching "[a-zA-Z0-9_.@-]+\\.service";
  activatorUnit = types.strMatching "[a-zA-Z0-9_.@-]+\\.(timer|socket|path)";
  package = pkgs.callPackage ../../pkgs/maintenance-runner {};
  scriptTask = name: script: timeoutSeconds: successExitCodes: {
    inherit name timeoutSeconds successExitCodes;
    command = [
      (pkgs.writeShellScript "maintenance-${name}" ''
        set -euo pipefail
        ${script}
      '').outPath
    ];
  };
  hook = name: phase: participant:
    if participant.${phase} == ""
    then null
    else scriptTask "${name}-${phase}" participant.${phase} participant.timeoutSeconds [0];
  participants =
    lib.mapAttrs (name: participant: {
      inherit (participant) backupSources writerUnits activatorUnits resumeUnits;
      prepare = hook name "prepare" participant;
      capture = hook name "capture" participant;
      resume = hook name "resume" participant;
    })
    cfg.participants;
  archiveTasks = lib.imap0 (index: script: scriptTask "archive-${toString index}" script cfg.archiveTimeoutSeconds [0]) cfg.archive;
  storageTasks = map (task: (scriptTask task.name task.script task.timeoutSeconds task.successExitCodes) // {inherit (task) weekdays;}) cfg.storageTasks;
  recoveryTasks = lib.concatMap (task:
    lib.optional (task.recovery != "") (scriptTask "${task.name}-recover" task.recovery task.timeoutSeconds [0]))
  cfg.storageTasks;
  guardedUnits = lib.unique (lib.concatMap (p: p.writerUnits ++ p.activatorUnits) (lib.attrValues cfg.participants));
  runtimeConfig = pkgs.writeText "maintenance.json" (builtins.toJSON {
    inherit participants archiveTasks storageTasks recoveryTasks;
    inherit (cfg) stateDirectory requiredMounts conflictingUnits stopTimeoutSeconds minimumFreeBytes keepSuccessfulRuns;
    systemctl = "${pkgs.systemd}/bin/systemctl";
    mountpoint = "${pkgs.util-linux}/bin/mountpoint";
    date = "${pkgs.coreutils}/bin/date";
  });
  runner = "${package}/bin/maintenance-runner";
  commonService = {
    path = [pkgs.coreutils pkgs.systemd pkgs.util-linux package] ++ cfg.pathPackages;
    requires = cfg.supportUnits;
    after = ["local-fs.target"] ++ cfg.supportUnits;
    unitConfig.RequiresMountsFor = [cfg.stateDirectory] ++ cfg.requiredMounts;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "infinity"; # Each hook has its own bounded deadline.
      TimeoutStopSec = cfg.cleanupTimeoutSeconds;
      KillMode = "mixed"; # Give the runner time to stop children and recover.
      UMask = "0077";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
in {
  options.homelab.maintenance = {
    enable = mkEnableOption "the shared maintenance lifecycle";
    stateDirectory = mkOption {
      type = absolutePath;
      default = "/var/lib/maintenance";
      description = "Private persistent state and per-run exports; must survive reboot.";
    };
    minimumFreeBytes = mkOption {
      type = types.ints.unsigned;
      default = 1073741824;
      description = "Minimum available bytes on the export filesystem before preparing applications; size for expected exports.";
    };
    keepSuccessfulRuns = mkOption {
      type = types.ints.positive;
      default = 7;
      description = "Number of successful local run directories retained. Failed runs require inspection/manual cleanup.";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = package;
      description = "Maintenance runner and hook helpers.";
    };
    participants = mkOption {
      default = {};
      description = "Application-owned contracts; hooks are synchronous root shell scripts.";
      type = types.attrsOf (types.submodule {
        options = {
          prepare = mkOption {
            type = types.lines;
            default = "";
            description = "Prepare consistent capture; remember previous state before changing it.";
          };
          capture = mkOption {
            type = types.lines;
            default = "";
            description = "Provide a complete consistent restore set, stable through archive.";
          };
          resume = mkOption {
            type = types.lines;
            default = "";
            description = "Idempotently undo even partially completed preparation.";
          };
          backupSources = mkOption {
            type = types.listOf absolutePath;
            default = [];
            description = "Stable files/directories for archive; this run's capture export directory is added automatically.";
          };
          writerUnits = mkOption {
            type = types.listOf serviceUnit;
            default = [];
            description = "All services that can write the storage being moved.";
          };
          activatorUnits = mkOption {
            type = types.listOf activatorUnit;
            default = [];
            description = "Timers, sockets and paths which can reactivate writers.";
          };
          resumeUnits = mkOption {
            type = types.listOf serviceUnit;
            default = [];
            description = "Writer daemons eligible for restart if active before the run; omit setup/migration jobs.";
          };
          timeoutSeconds = mkOption {
            type = types.ints.positive;
            default = 1800;
            description = "Deadline for each application hook.";
          };
        };
      });
    };
    archive = mkOption {
      type = types.listOf types.lines;
      default = [];
      description = "Ordered archive scripts. Read the exact source list from MAINTENANCE_SOURCES_FILE. Missing configuration aborts before preparation.";
    };
    archiveTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 14400;
      description = "Deadline per archive script.";
    };
    storageTasks = mkOption {
      default = [];
      description = "Ordered storage tasks, run only after archive and verified writer suspension.";
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.strMatching "[a-zA-Z0-9_-]+";
            description = "Readable task name.";
          };
          script = mkOption {
            type = types.lines;
            description = "Foreground storage command.";
          };
          recovery = mkOption {
            type = types.lines;
            default = "";
            description = "Idempotent recovery, attempted before any application resumes, including after reboot.";
          };
          timeoutSeconds = mkOption {
            type = types.ints.positive;
            default = 14400;
            description = "Deadline for task and recovery.";
          };
          successExitCodes = mkOption {
            type = types.listOf types.int;
            default = [0];
            description = "Safe successful exit codes; nonzero accepted codes should report their warning.";
          };
          weekdays = mkOption {
            type = types.listOf (types.ints.between 1 7);
            default = [];
            description = "Run on these local weekdays (Monday=1); empty means every run.";
          };
        };
      });
    };
    requiredMounts = mkOption {
      type = types.listOf absolutePath;
      default = [];
      description = "Mountpoints checked before preparation and required by runner services.";
    };
    supportUnits = mkOption {
      type = types.listOf serviceUnit;
      default = [];
      description = "Infrastructure needed by hooks/recovery; must not be guarded writers.";
    };
    pathPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Host tools required on PATH by participant, archive, storage or saved recovery hooks.";
    };
    conflictingUnits = mkOption {
      type = types.listOf serviceUnit;
      default = [];
      description = "Independent maintenance tools that must be inactive before preparation.";
    };
    stopTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 120;
      description = "Grace for stopping hooks and systemd operations.";
    };
    cleanupTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 1800;
      description = "Systemd grace for coordinator cancellation and cleanup.";
    };
    timer = {
      enable = mkEnableOption "scheduled maintenance";
      calendar = mkOption {
        type = types.str;
        default = "*-*-* 02:00:00";
        description = "Nightly local systemd calendar expression.";
      };
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z0-9_-]+" name != null) (lib.attrNames cfg.participants);
        message = "Maintenance participant names must be simple directory names.";
      }
      {
        assertion = lib.all (p: lib.all (unit: builtins.elem unit p.writerUnits) p.resumeUnits) (lib.attrValues cfg.participants);
        message = "Maintenance resumeUnits must be declared writerUnits.";
      }
      {
        assertion = lib.all (unit: !(builtins.elem unit guardedUnits)) cfg.supportUnits;
        message = "Maintenance supportUnits cannot also be guarded writers.";
      }
      {
        assertion = !cfg.timer.enable || cfg.archive != [] || cfg.participants == {};
        message = "Configure maintenance.archive before enabling the nightly timer.";
      }
      {
        assertion = lib.all (entry: lib.all (service: builtins.elem "${service}.service" guardedUnits) entry.services) (lib.attrValues (config.homelab.bulkStorage or {}));
        message = "Every bulk-storage consumer must be registered as a maintenance writer (including setup/migration jobs).";
      }
    ];
    environment = {
      systemPackages = [package];
      etc."maintenance/config.json".source = runtimeConfig;
    };
    systemd = {
      tmpfiles.rules = ["d ${cfg.stateDirectory} 0700 root root -"];
      services =
        {
          maintenance-run = lib.recursiveUpdate commonService {
            description = "Prepare, capture, archive, maintain storage, and resume";
            requires = cfg.supportUnits ++ ["maintenance-recover.service"];
            after = ["local-fs.target" "maintenance-recover.service"] ++ cfg.supportUnits;
            serviceConfig.ExecStart = "${runner} run --config ${runtimeConfig}";
            serviceConfig.ExecStopPost = "${runner} recover --config ${runtimeConfig}";
          };
          maintenance-recover = lib.recursiveUpdate commonService {
            description = "Recover an interrupted maintenance run before resuming writers";
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${runner} recover --config ${runtimeConfig}";
          };
        }
        // lib.genAttrs (map (unit: lib.removeSuffix ".service" unit) (lib.filter (lib.hasSuffix ".service") guardedUnits)) (_: {
          unitConfig.ConditionPathExists = lib.mkAfter ["!${cfg.stateDirectory}/pending.json"];
        });
      # Apply the same persistent startup guard to activation sources.
      timers =
        {
          maintenance-run = mkIf cfg.timer.enable {
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = cfg.timer.calendar;
              Persistent = false;
              Unit = "maintenance-run.service";
            };
          };
        }
        // lib.genAttrs (map (unit: lib.removeSuffix ".timer" unit) (lib.filter (lib.hasSuffix ".timer") guardedUnits)) (_: {
          unitConfig.ConditionPathExists = lib.mkAfter ["!${cfg.stateDirectory}/pending.json"];
        });
      sockets = lib.genAttrs (map (unit: lib.removeSuffix ".socket" unit) (lib.filter (lib.hasSuffix ".socket") guardedUnits)) (_: {
        unitConfig.ConditionPathExists = lib.mkAfter ["!${cfg.stateDirectory}/pending.json"];
      });
      paths = lib.genAttrs (map (unit: lib.removeSuffix ".path" unit) (lib.filter (lib.hasSuffix ".path") guardedUnits)) (_: {
        unitConfig.ConditionPathExists = lib.mkAfter ["!${cfg.stateDirectory}/pending.json"];
      });
    };
  };
}
