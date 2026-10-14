# Paperless 3 needs its matching upstream service module until the stable host
# release includes it. The rest of this host continues to use NixOS 26.05.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  hostName = "paper.nicholasbehr.ch";
  cfg = config.services.paperless;
  stateDirectory = cfg.dataDir;
  mediaDirectory = cfg.mediaDir;
  consumptionDirectory = cfg.consumptionDir;
  paperlessPkgs = inputs.nixpkgs-paperless.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  maintenance = config.homelab.maintenance;
  runner = "${maintenance.package}/bin/maintenance-runner";
  writerUnits = [
    "paperless-scheduler.service"
    "paperless-consumer.service"
    "paperless-web.service"
    "paperless-task-queue.service"
  ];
  maintenancePage = pkgs.writeText "paperless-unavailable.html" ''
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Paperless maintenance</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 1rem system-ui, sans-serif; background: #f5f7fa; color: #1f2937; }
          main { max-width: 34rem; margin: 2rem; padding: 2.5rem; border-radius: 1rem; background: white; box-shadow: 0 1rem 3rem rgb(15 23 42 / 12%); }
          h1 { margin-top: 0; color: #354b38; }
        </style>
      </head>
      <body>
        <main>
          <h1>Paperless is under maintenance</h1>
          <p>The server is completing its backup and storage checks. Please try again shortly.</p>
        </main>
      </body>
    </html>
  '';
in {
  # Replace the 26.05 definition as a pair with the 3.x package. Mixing the
  # stable module with the new package is not a supported upgrade path.
  disabledModules = ["services/misc/paperless.nix"];
  imports = [(inputs.nixpkgs-paperless.outPath + "/nixos/modules/services/misc/paperless.nix")];

  config = lib.mkMerge [
    {services.paperless.enable = lib.mkDefault true;}
    (lib.mkIf cfg.enable {
      services.paperless = {
        package = paperlessPkgs.paperless-ngx;
        dataDir = "/var/lib/paperless";
        mediaDir = "/var/lib/paperless/media";
        consumptionDir = "/var/lib/paperless/consume";
        address = "127.0.0.1";
        database.createLocally = true;
        configureNginx = true;
        domain = hostName;
        configureTika = false; # PDF intake; no Office or email conversion stack.
        settings = {
          PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
          PAPERLESS_OCR_LANGUAGE = "deu+eng";
          PAPERLESS_OCR_MODE = "auto";
          # Retain originals; make a searchable PDF/A for scans while avoiding
          # duplicate archives for digital PDFs that already contain text.
          PAPERLESS_ARCHIVE_FILE_GENERATION = "auto";
          # The consume directory is on mergerFS, where inotify may not reliably
          # report every new file. Web uploads work independently of this watcher.
          PAPERLESS_CONSUMER_POLLING_INTERVAL = 10;
        };
      };

      services.nginx.virtualHosts.${hostName} = {
        enableACME = true;
        forceSSL = true;
        extraConfig = ''
          client_max_body_size 200M;
          error_page 502 503 504 =503 /_paperless_unavailable.html;
        '';
        locations."= /_paperless_unavailable.html" = {
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

      # The database lives in the existing /persist16 PostgreSQL cluster.
      # Keep generated secret key and search index on persistent local storage.
      environment.persistence."/persist128".directories = [
        {
          directory = stateDirectory;
          user = "paperless";
          group = "paperless";
          mode = "0750";
        }
      ];

      # Explicit bind mounts keep both originals and generated archives in
      # /data/paperless/media. The future import queue is separate and private.
      homelab.bulkStorage = {
        paperless-media = {
          source = "/data/paperless/media";
          target = mediaDirectory;
          user = "paperless";
          group = "paperless";
          mode = "0700";
          services = map (lib.removeSuffix ".service") writerUnits;
        };
        paperless-consume = {
          source = "/data/paperless/consume";
          target = consumptionDirectory;
          user = "paperless";
          group = "paperless";
          mode = "0700";
          services = map (lib.removeSuffix ".service") writerUnits;
        };
      };

      # A test activation can start the scheduler before tmpfiles-resetup has
      # made the v3 Tantivy index directory. Ensure it exists before the
      # upstream scheduler preStart runs migrations and reindexing.
      systemd.services.paperless-scheduler.preStart = lib.mkBefore ''
        ${pkgs.coreutils}/bin/install -d -m 0700 -- ${lib.escapeShellArg "${stateDirectory}/index"}
      '';

      # Celery's worker should finish any active OCR task on orderly shutdown.
      systemd.services.paperless-task-queue.serviceConfig.TimeoutStopSec = "15min";

      homelab.maintenance = lib.mkIf maintenance.enable {
        requiredMounts = [mediaDirectory consumptionDirectory];
        supportUnits = ["postgresql.service"];
        participants.paperless = {
          inherit writerUnits;
          resumeUnits = writerUnits;
          backupSources = [stateDirectory mediaDirectory consumptionDirectory (toString cfg.package)];
          prepare = ''
            # Stop intake before the worker, then wait for active OCR work to
            # finish. Keep every writer stopped through the database dump and
            # Borg's read of the matching media tree.
            ${pkgs.systemd}/bin/systemctl stop paperless-scheduler.service
            ${pkgs.systemd}/bin/systemctl stop paperless-task-queue.service
            for unit in ${lib.escapeShellArgs writerUnits}; do
              ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"
            done
          '';
          capture = ''
            ${pkgs.util-linux}/bin/runuser -u postgres -- \
              ${config.services.postgresql.package}/bin/pg_dump \
              --format=custom --dbname=${lib.escapeShellArg cfg.settings.PAPERLESS_DBNAME} \
              > "$MAINTENANCE_EXPORT_DIR/database.dump.tmp"
            ${config.services.postgresql.package}/bin/pg_restore \
              --list "$MAINTENANCE_EXPORT_DIR/database.dump.tmp" > /dev/null
            ${runner} publish database.dump.tmp database.dump
            printf '%s\n' ${lib.escapeShellArg (toString cfg.package)} \
              > "$MAINTENANCE_EXPORT_DIR/paperless-package.txt.tmp"
            ${runner} publish paperless-package.txt.tmp paperless-package.txt
          '';
        };
      };
    })
  ];
}
