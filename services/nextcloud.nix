# Nextcloud is a host application; its persistence belongs here, not in disko.
#
# Storage layout (the /var/lib paths are the application's stable interface):
#   /data/nextcloud                  -> /var/lib/nextcloud/data (bulk files)
#   /persist128/var/lib/nextcloud    -> /var/lib/nextcloud (config/instance state)
#   /persist16/var/lib/postgresql    -> /var/lib/postgresql (database metadata)
# The data directory also holds versions, trash, previews and appdata: not all
# application metadata can be separated from bulk storage. Redis is disposable.
# Temporary files use standard system temporary storage, not /data.
# /data uses the existing mergerFS placement policy; this adds no storage mover.
# Do not modify files in /data/nextcloud directly; use Nextcloud/WebDAV instead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  hostName = "next.nicholasbehr.ch";
  maintenancePage = pkgs.writeText "nextcloud-unavailable.html" ''
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nextcloud maintenance</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 1rem system-ui, sans-serif; background: #f5f7fa; color: #1f2937; }
          main { max-width: 34rem; margin: 2rem; padding: 2.5rem; border-radius: 1rem; background: white; box-shadow: 0 1rem 3rem rgb(15 23 42 / 12%); }
          h1 { margin-top: 0; color: #00679e; }
        </style>
      </head>
      <body>
        <main>
          <h1>Nextcloud is under maintenance</h1>
          <p>The server is completing its backup and storage checks. Please try again shortly.</p>
        </main>
      </body>
    </html>
  '';
  # Follow the NixOS module's paths; only their backing storage is customized.
  stateDirectory = config.services.nextcloud.home;
  dataDirectory = "${config.services.nextcloud.datadir}/data";
  maintenance = config.homelab.maintenance;
  maintenanceRunner = "${maintenance.package}/bin/maintenance-runner";
  occ = "${pkgs.util-linux}/bin/runuser -u nextcloud -- ${lib.getExe config.services.nextcloud.occ}";
  writerUnits =
    [
      "nextcloud-setup.service"
      "phpfpm-nextcloud.service"
      "nextcloud-cron.service"
      "nextcloud-update-db.service"
    ]
    ++ lib.optional config.services.nextcloud.autoUpdateApps.enable "nextcloud-update-plugins.service";
  activatorUnits =
    ["nextcloud-cron.timer"]
    ++ lib.optional config.services.nextcloud.autoUpdateApps.enable "nextcloud-update-plugins.timer";
in {
  config = lib.mkMerge [
    {services.nextcloud.enable = lib.mkDefault true;}
    (lib.mkIf config.services.nextcloud.enable {
      services = {
        nextcloud = {
          inherit hostName;
          https = true;

          # Pin the major version: flake updates supply patch releases, while major
          # upgrades require an explicit change here. Upgrade one major at a time.
          package = pkgs.nextcloud35;

          # NixOS's datadir defaults to home and contains BOTH config/ and data/.
          # Bind only data/ to the bulk pool, so instance secrets remain on the NVMe
          # persistence dataset. PHP-FPM, nginx routes and the five-minute cron timer
          # are supplied by the upstream NixOS module, not duplicated here.
          database.createLocally = true;
          config = {
            dbtype = "pgsql";
            adminuser = "admin";
            adminpassFile = config.sops.secrets.nextcloud-admin-password.path;
          };

          # Local Redis socket for caching and transactional file locking. Neither
          # Redis nor PostgreSQL needs a public port or a database password secret.
          configureRedis = true;

          # Keep executable application code declarative. Add optional apps through
          # extraApps using pkgs.nextcloud35Packages.apps, then rebuild to update them.
          appstoreEnable = false;

          settings = {
            default_phone_region = "CH";
            # Bound deleted-file retention instead of excluding trash paths from
            # backups behind Nextcloud's back. Expiration updates both storage and
            # database metadata, preserving a consistent restore set.
            trashbin_retention_obligation = "auto, 30";
            # Use the existing persistent, size-bounded journal instead of a bulk log.
            log_type = "systemd";
          };
        };

        # The shared nginx module owns TLS defaults, ACME email and ports 80/443.
        # Wildcard DNS is sufficient, but this requests a certificate for this exact
        # hostname via HTTP-01, not a wildcard certificate. NixOS supplies Nextcloud's
        # own security headers and restricted locations; do not replace its routes.
        nginx.virtualHosts.${hostName} = {
          enableACME = true;
          forceSSL = true;
          # PHP-FPM is intentionally stopped while Borg reads the consistent live
          # data tree. Serve a static page from the Nix store instead of exposing
          # nginx's upstream 502 response. This also covers unexpected PHP outages.
          extraConfig = ''
            error_page 502 503 504 =503 /_nextcloud_unavailable.html;
          '';
          locations."= /_nextcloud_unavailable.html" = {
            alias = maintenancePage;
            extraConfig = ''
              internal;
              default_type text/html;
              add_header Retry-After "300" always;
              add_header Cache-Control "no-store" always;
              add_header X-Content-Type-Options "nosniff" always;
              add_header X-Robots-Tag "noindex, nofollow" always;
              add_header X-Permitted-Cross-Domain-Policies "none" always;
              add_header X-Frame-Options "sameorigin" always;
              add_header Referrer-Policy "no-referrer" always;
              add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
            '';
          };
        };
      };

      # Add this key via SOPS before the first deployment (README: Editing secrets).
      # It must contain a strong actual password, NOT a Linux password hash.
      # Root-only by default; nextcloud-setup receives it through LoadCredential.
      # This only bootstraps the admin account: changing the secret later does not
      # reset its password. Use the UI or `sudo nextcloud-occ user:resetpassword admin`.
      sops.secrets.nextcloud-admin-password = {};

      # Storage backend
      environment.persistence = {
        "/persist128".directories = [
          {
            directory = stateDirectory;
            user = "nextcloud";
            group = "nextcloud";
            mode = "0750";
          }
        ];
      };
      homelab.bulkStorage.nextcloud = {
        source = "/data/nextcloud";
        target = dataDirectory;
        user = "nextcloud";
        group = "nextcloud";
        services = map (lib.removeSuffix ".service") writerUnits;
      };

      # This application owns capture consistency. The shared runner owns the
      # fixed phase sequence, restart bookkeeping and the storage suspension gate.
      homelab.maintenance = lib.mkIf maintenance.enable {
        supportUnits = ["postgresql.service"];
        participants.nextcloud = {
          inherit writerUnits activatorUnits;
          resumeUnits = ["phpfpm-nextcloud.service"];
          backupSources =
            [stateDirectory dataDirectory (toString config.services.nextcloud.package)]
            ++ map toString (lib.attrValues config.services.nextcloud.extraApps);
          prepare = ''
            # Record before changing mode. Cleanup also runs after partial failure.
            status="$(${occ} status --output=json)"
            previous="$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -er '.maintenance | tostring')"
            ${maintenanceRunner} remember maintenance "$previous"
            # Stop web/background writers while app-provided OCC commands are still
            # available. Maintenance mode loads only core/AppAPI commands, so trash
            # expiration must happen before enabling it.
            ${pkgs.systemd}/bin/systemctl stop ${lib.escapeShellArgs (activatorUnits ++ writerUnits)}
            # This hook is now the only application writer. Raw Borg exclusions
            # could leave matching database metadata without files after a restore.
            ${occ} trashbin:expire --quiet
            ${occ} maintenance:mode --on
          '';
          capture = ''
            ${pkgs.util-linux}/bin/runuser -u postgres -- \
              ${config.services.postgresql.package}/bin/pg_dump \
              --format=custom --dbname=${lib.escapeShellArg config.services.nextcloud.config.dbname} \
              > "$MAINTENANCE_EXPORT_DIR/database.dump.tmp"
            ${config.services.postgresql.package}/bin/pg_restore \
              --list "$MAINTENANCE_EXPORT_DIR/database.dump.tmp" > /dev/null
            ${maintenanceRunner} publish database.dump.tmp database.dump
            # Dereference generated configuration links so the export contains
            # their contents even if an old Nix store generation is collected.
            ${pkgs.coreutils}/bin/cp --archive --dereference \
              ${lib.escapeShellArg "${config.services.nextcloud.datadir}/config"} \
              "$MAINTENANCE_EXPORT_DIR/config.tmp"
            ${maintenanceRunner} publish config.tmp config
            # Declarative code must be installed before restoring this instance.
            printf '%s\n' ${lib.escapeShellArg (toString config.services.nextcloud.package)} \
              > "$MAINTENANCE_EXPORT_DIR/nextcloud-package.txt.tmp"
            ${maintenanceRunner} publish nextcloud-package.txt.tmp nextcloud-package.txt
          '';
          resume = ''
            saved="$MAINTENANCE_PARTICIPANT_DIR/application-state.json"
            # Preparation may have failed before recording anything.
            if [ -f "$saved" ]; then
              previous="$(${pkgs.jq}/bin/jq -er '.maintenance | tostring' "$saved")"
              if [ "$previous" = true ]; then
                ${occ} maintenance:mode --on
              else
                ${occ} maintenance:mode --off
              fi
            fi
          '';
        };
      };

      # Upstream cron uses KillMode=process; storage suspension must also stop any
      # descendants that could still write files after its main process exits.
      systemd.services.nextcloud-cron.serviceConfig.KillMode = lib.mkForce "control-group";

      # NixOS orders setup before PHP-FPM; also prevent startup if setup fails.
      systemd.services.phpfpm-nextcloud.requires = ["nextcloud-setup.service"];

      # Operations: `sudo nextcloud-occ status` and `journalctl -u nextcloud-setup`
      # are the first checks after deployment. Configure SMTP before relying on
      # password-reset emails; enable admin 2FA in Nextcloud after the first login.
      #
      # Persistence/RAID is NOT a backup. Before upgrades, take a consistent backup
      # of config + data + a PostgreSQL dump with Nextcloud in maintenance mode and
      # its cron job stopped. Back up the /data source separately: the data visible
      # beneath /var/lib/nextcloud is a nested mount, not part of persist128's ZFS
      # snapshot. A NixOS rollback cannot undo Nextcloud database migrations.
      # https://docs.nextcloud.com/server/35/admin_manual/maintenance/backup.html
    })
  ];
}
