# Keep application paths stable while their bulk files live on another volume.
# Unlike early-boot impermanence, this also works with stage-2 mounts (mergerFS):
# backing filesystem -> owned source directory -> bind mount -> consuming units.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.bulkStorage;
  contains = parent: path: parent == path || lib.hasPrefix "${parent}/" path;
  directoryPath = lib.types.addCheck (lib.types.strMatching "/[a-zA-Z0-9_./-]+") (
    path: lib.all (part: !builtins.elem part ["" "." ".."]) (lib.tail (lib.splitString "/" path))
  );
in {
  options.homelab.bulkStorage = lib.mkOption {
    default = {};
    description = "Named bulk-storage bind mounts; backing filesystems and users must already be declared.";
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        source = lib.mkOption {
          type = directoryPath;
          description = "Absolute source directory on the backing filesystem (not a Nix store path).";
        };
        target = lib.mkOption {
          type = directoryPath;
          description = "Absolute application directory to mount over; existing contents are not migrated.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          description = "Existing user owning the source directory.";
        };
        group = lib.mkOption {
          type = lib.types.str;
          description = "Existing group owning the source directory.";
        };
        mode = lib.mkOption {
          type = lib.types.strMatching "0[0-7]{3}";
          default = "0750";
          description = "Source directory permissions; ownership and mode are not applied recursively.";
        };
        services = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Consuming systemd service names, without the .service suffix.";
        };
      };
    });
  };

  config = {
    assertions = let
      targets = map (entry: entry.target) (lib.attrValues cfg);
    in
      [
        {
          assertion = builtins.length targets == builtins.length (lib.unique targets);
          message = "homelab.bulkStorage: each target must be unique.";
        }
      ]
      ++ lib.concatLists (lib.mapAttrsToList (name: entry: [
          {
            assertion = builtins.match "[a-zA-Z0-9_-]+" name != null;
            message = "homelab.bulkStorage: entry names must use letters, digits, underscores or hyphens.";
          }
          {
            assertion = !(contains entry.source entry.target || contains entry.target entry.source);
            message = "homelab.bulkStorage.${name}: source and target must not contain one another.";
          }
        ])
        cfg);

    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: entry:
      {
        "bulk-storage-${name}" = {
          description = "Prepare bulk storage for ${name}";
          unitConfig = {
            # Normal services wait for sysinit, which waits for local-fs. This
            # service must run BEFORE its bind mount and thus before local-fs.
            DefaultDependencies = false;
            RequiresMountsFor = [entry.source];
          };
          serviceConfig.Type = "oneshot";
          script = ''
            exec ${pkgs.coreutils}/bin/install -d ${lib.escapeShellArgs ["-m" entry.mode "-o" entry.user "-g" entry.group "--" entry.source]}
          '';
        };
      }
      // lib.genAttrs entry.services (_: {
        # Merge lists so a service can depend on several bulk-storage entries.
        unitConfig.RequiresMountsFor = [entry.target];
      }))
    cfg);

    systemd.mounts =
      lib.mapAttrsToList (name: entry: {
        description = "Bulk storage for ${name}";
        what = entry.source;
        where = entry.target;
        type = "none";
        options = "bind";
        wantedBy = ["local-fs.target"];
        before = ["local-fs.target"];
        requires = ["bulk-storage-${name}.service"];
        after = ["bulk-storage-${name}.service"];
        # Wait for both the backing volume and any persisted target parent.
        unitConfig.RequiresMountsFor = [entry.source (builtins.dirOf entry.target)];
      })
      cfg;
  };
}
