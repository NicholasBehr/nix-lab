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
  # Follow the NixOS module's paths; only their backing storage is customized.
  stateDirectory = config.services.nextcloud.home;
  dataDirectory = "${config.services.nextcloud.datadir}/data";
in {
  services = {
    nextcloud = {
      enable = true;
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
    };

    # Keep the cluster on the 16K-recordsize dataset. Preserve the whole parent
    # directory, including versioned clusters, to support deliberate PG upgrades.
    # PostgreSQL major upgrades need a database migration, not just a rebuild.
    postgresql = {
      package = pkgs.postgresql_17;
      settings.listen_addresses = lib.mkForce ""; # Unix sockets only, not even localhost TCP.
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
    "/persist16".directories = [
      {
        directory = "/var/lib/postgresql";
        user = "postgres";
        group = "postgres";
        mode = "0750";
      }
    ];
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
    services = [
      "nextcloud-setup"
      "phpfpm-nextcloud"
      "nextcloud-cron"
      "nextcloud-update-db"
    ];
  };

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
}
