{
  pkgs,
  maintenanceModule,
}:
pkgs.testers.runNixOSTest {
  name = "maintenance-lifecycle";
  nodes.machine = {config, ...}: {
    imports = [maintenanceModule];
    systemd = {
      tmpfiles.rules = ["d /var/lib/test-data 0700 root root -"];
      services.test-writer = {
        wantedBy = ["multi-user.target"];
        script = ''
          while true; do
            echo data >> /var/lib/test-data/content
            sleep 1
          done
        '';
      };
      services.maintenance-run.unitConfig.StartLimitIntervalSec = 0;
    };
    homelab.maintenance = {
      enable = true;
      stopTimeoutSeconds = 10;
      participants.test = {
        writerUnits = ["test-writer.service"];
        resumeUnits = ["test-writer.service"];
        backupSources = ["/var/lib/test-data"];
        prepare = ''
          ${config.homelab.maintenance.package}/bin/maintenance-runner remember prepared true
          systemctl stop test-writer.service
        '';
        capture = ''
          test ! -f /var/lib/fail-capture
          cp /var/lib/test-data/content "$MAINTENANCE_EXPORT_DIR/content"
        '';
        resume = ''
          echo resumed >> /var/lib/resume-events
        '';
      };
      archive = [
        ''
          test -f "$MAINTENANCE_SOURCES_FILE"
          test -f "$MAINTENANCE_RUN_DIR/test/export/content"
          if [ -f /var/lib/slow-archive ]; then
            touch /var/lib/archive-started
            exec sleep 300
          fi
          test ! -f /var/lib/fail-archive
          touch /var/lib/archived
        ''
      ];
      storageTasks = [
        {
          name = "storage";
          script = ''
            ${config.homelab.maintenance.package}/bin/maintenance-runner check-storage "$MAINTENANCE_STATE_DIR"
            test "$(systemctl show --property=ActiveState --value test-writer.service)" = inactive
            touch /var/lib/storage-ran
          '';
          recovery = ''
            test ! -f /var/lib/deny-recovery
          '';
        }
      ];
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("test-writer.service")
    machine.succeed("systemctl start maintenance-run.service")
    machine.wait_for_unit("test-writer.service")
    machine.succeed("test -f /var/lib/archived; test -f /var/lib/storage-ran")
    machine.succeed("systemctl start maintenance-run.service")
    machine.succeed("test $(find /var/lib/maintenance/runs -name result.json | wc -l) -eq 2")

    # Failed capture cannot reuse a previous successful export.
    machine.succeed("rm /var/lib/archived /var/lib/storage-ran; touch /var/lib/fail-capture")
    machine.fail("systemctl start maintenance-run.service")
    machine.wait_for_unit("test-writer.service")
    machine.succeed("test ! -e /var/lib/archived; test ! -e /var/lib/storage-ran; rm /var/lib/fail-capture")

    # Archive failure skips storage, resumes service, and remains a failure.
    machine.succeed("touch /var/lib/fail-archive")
    machine.fail("systemctl start maintenance-run.service")
    machine.wait_for_unit("test-writer.service")
    machine.succeed("test ! -e /var/lib/storage-ran; rm /var/lib/fail-archive")

    # Cancellation stops archive readers before releasing the writer guard.
    machine.succeed("touch /var/lib/slow-archive; systemctl start --no-block maintenance-run.service")
    machine.wait_until_succeeds("test -f /var/lib/archive-started")
    machine.succeed("systemctl stop maintenance-run.service")
    machine.wait_for_unit("test-writer.service")
    machine.succeed("test ! -e /var/lib/maintenance/pending.json; rm /var/lib/slow-archive")

    # Failed recovery remains blocked across reboot, then explicit retry works.
    machine.succeed("touch /var/lib/deny-recovery")
    machine.fail("systemctl start maintenance-run.service")
    machine.succeed("test -f /var/lib/maintenance/pending.json")
    machine.fail("systemctl is-active test-writer.service")
    machine.shutdown()
    machine.start()
    machine.wait_until_succeeds("systemctl is-failed maintenance-recover.service")
    machine.fail("systemctl is-active test-writer.service")
    machine.succeed("rm /var/lib/deny-recovery; systemctl start maintenance-recover.service")
    machine.wait_for_unit("test-writer.service")
    machine.succeed("test ! -e /var/lib/maintenance/pending.json")
  '';
}
