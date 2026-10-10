# Immich's database shares the persistent PostgreSQL cluster with Nextcloud.
# Media is a separate, explicitly archived bind mount on the mergerFS pool.
# The machine-learning model cache is persistent but can be regenerated.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  hostName = "immich.nicholasbehr.ch";
  stateDirectory = "/var/lib/immich";
  mediaDirectory = "${stateDirectory}/media";
  modelCacheDirectory = "/var/cache/immich";
  cfg = config.services.immich;
  immichPkgs = inputs.nixpkgs-immich.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  maintenance = config.homelab.maintenance;
  runner = "${maintenance.package}/bin/maintenance-runner";
  writerUnits = ["immich-server.service"];
  maintenancePage = pkgs.writeText "immich-unavailable.html" ''
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Immich maintenance</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 1rem system-ui, sans-serif; background: #f5f7fa; color: #1f2937; }
          main { max-width: 34rem; margin: 2rem; padding: 2.5rem; border-radius: 1rem; background: white; box-shadow: 0 1rem 3rem rgb(15 23 42 / 12%); }
          h1 { margin-top: 0; color: #222e34; }
        </style>
      </head>
      <body>
        <main>
          <h1>Immich is under maintenance</h1>
          <p>The server is completing its backup and storage checks. Please try again shortly.</p>
        </main>
      </body>
    </html>
  '';
in {
  config = lib.mkMerge [
    {services.immich.enable = lib.mkDefault true;}
    (lib.mkIf cfg.enable {
      services.immich = {
        package = immichPkgs.immich;
        host = "127.0.0.1";
        port = 2283;
        openFirewall = false;
        mediaLocation = mediaDirectory;
        machine-learning.enable = true; # Facial recognition remains on the CPU.
        accelerationDevices = ["/dev/dri/renderD128"];
        environment.LIBVA_DRIVER_NAME = "iHD";

        # The nightly coordinator captures a PostgreSQL dump with the server
        # stopped. Immich's own default 02:00 dump would compete with that window.
        settings = {
          server.externalDomain = "https://${hostName}";
          backup.database.enabled = false;
          ffmpeg = {
            accel = "qsv";
            accelDecode = true;
          };
        };
      };

      systemd.services = {
        immich-server.serviceConfig.SupplementaryGroups = ["render"];
        # The upstream module shares device settings between both units. Only
        # the video transcoder needs GPU access while inference remains CPU-only.
        immich-machine-learning.serviceConfig = lib.mkIf cfg.machine-learning.enable {
          PrivateDevices = lib.mkForce true;
          DeviceAllow = lib.mkForce [];
        };
      };

      services.nginx.virtualHosts.${hostName} = {
        enableACME = true;
        forceSSL = true;
        extraConfig = ''
          error_page 502 503 504 =503 /_immich_unavailable.html;
        '';
        locations."/" = {
          proxyPass = "http://${cfg.host}:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = ''
            client_max_body_size 50000M;
            proxy_request_buffering off;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            send_timeout 600s;
          '';
        };
        locations."= /_immich_unavailable.html" = {
          alias = maintenancePage;
          extraConfig = ''
            internal;
            default_type text/html;
            add_header Retry-After "300" always;
            add_header Cache-Control "no-store" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Robots-Tag "noindex, nofollow" always;
            add_header X-Frame-Options "sameorigin" always;
            add_header Referrer-Policy "no-referrer" always;
            add_header Strict-Transport-Security "max-age=31536000" always;
          '';
        };
      };

      # Ephemeral root must not discard instance state or downloaded ML models.
      # Keep the cache out of Borg: models can be downloaded again after a restore.
      environment.persistence."/persist128".directories = [
        {
          directory = stateDirectory;
          user = "immich";
          group = "immich";
          mode = "0750";
        }
        {
          directory = modelCacheDirectory;
          user = "immich";
          group = "immich";
          mode = "0750";
        }
      ];

      homelab.bulkStorage.immich = {
        source = "/data/immich";
        target = mediaDirectory;
        user = "immich";
        group = "immich";
        mode = "0700";
        services = ["immich-server"];
      };

      homelab.maintenance = lib.mkIf maintenance.enable {
        requiredMounts = [mediaDirectory];
        supportUnits = ["postgresql.service"];
        participants.immich = {
          inherit writerUnits;
          resumeUnits = writerUnits;
          backupSources = [stateDirectory mediaDirectory (toString cfg.package)];
          prepare = ''
            # Stopping the sole media/database writer before the dump also keeps
            # the live media tree unchanged until Borg finishes reading it.
            ${pkgs.systemd}/bin/systemctl stop immich-server.service
            ! ${pkgs.systemd}/bin/systemctl is-active --quiet immich-server.service
          '';
          capture = ''
            ${pkgs.util-linux}/bin/runuser -u postgres -- \
              ${config.services.postgresql.package}/bin/pg_dump \
              --format=custom --dbname=${lib.escapeShellArg cfg.database.name} \
              > "$MAINTENANCE_EXPORT_DIR/database.dump.tmp"
            ${config.services.postgresql.package}/bin/pg_restore \
              --list "$MAINTENANCE_EXPORT_DIR/database.dump.tmp" > /dev/null
            ${runner} publish database.dump.tmp database.dump
            printf '%s\n' ${lib.escapeShellArg (toString cfg.package)} \
              > "$MAINTENANCE_EXPORT_DIR/immich-package.txt.tmp"
            ${runner} publish immich-package.txt.tmp immich-package.txt
          '';
        };
      };
    })
  ];
}
