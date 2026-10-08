# Nightly maintenance

The shared lifecycle is:

```text
prepare → capture → suspend writers → archive → maintain_storage → resume
```

`suspend writers` is a fixed coordinator action, not a configurable phase.
Applications own consistent capture. The coordinator owns ordering, stopping
declared writers, process deadlines, persistent recovery state, and restoration
of eligible services. Storage tools own their transactions and recovery.

The reusable module is `modules/nixos/maintenance.nix`; its Rust coordinator is
`pkgs/maintenance-runner`. Host scheduling/persistence policy lives in
`nixos/maintenance.nix`. Nextcloud hooks live in `services/nextcloud.nix`, and
storage tasks live in `nixos/storage.nix`. The coordinator has no knowledge of
those applications or tools.

## Contracts

| Phase | Successful completion means |
| --- | --- |
| `prepare` | Application-specific preparation is complete; previous state was recorded before changing it. |
| `capture` | Every participant provides a complete, consistent restore set. Its sources remain stable until archive finishes. |
| Suspend writers | All declared writers and their activation sources are stopped, and new starts are guarded. |
| `archive` | Every archive command succeeded and its processes have exited. |
| `maintain_storage` | Ordered storage work completed with writers still suspended. Verified relocation can change backing paths after archive. |
| `resume` | Storage recovery succeeded, application preparation was undone, and eligible previously active services/activators were restored. |

An application can capture an independent export while running. It must still
declare any writers to the storage being moved; these stop after capture. An
application archiving live files must establish consistency **before capture**
and preserve it through archive. Stopping writers after a dump does not make
that dump consistent with files changed during the dump.

Hooks are foreground root shell scripts with `set -euo pipefail`. They may
switch user for application/database commands. They must not daemonize, submit
detached work, or leave background children. Each hook has its own deadline;
cancellation/timeout terminates and waits for the process group before cleanup.
Storage does not start while an archive reader remains alive.

`resume` must be idempotent and handle preparation that failed halfway through.
It restores changes made by this run, preserving pre-existing maintenance mode.
It must not start writer services itself: the coordinator releases their guard
and restores the declared eligible services after all resume hooks succeed.

## Current host

Nextcloud records its original maintenance mode, enables maintenance mode, and
stops PHP, cron and setup/update writers before the PostgreSQL dump. A custom
format dump is checked with `pg_restore --list` and published durably. Generated
configuration links are also copied with their contents into the export. Archive
sources include Nextcloud state/configuration, its explicit bulk-data mount,
the application package and configured extra apps, plus this run's export.
Database roles and the declarative application environment must be recreated
from the NixOS configuration when restoring. Test restoration into a separate
instance; listing a dump is a structural check, not a complete restore test.

The application stays suspended while Borg reads its live files. Its data on
NVMe is included even though SnapRAID protects only the HDD data branches.
The mover runs next, followed by SnapRAID sync and Sunday scrub (8%, older than
10 days). Mover exit 2 means safe but incomplete movement and is logged as a
warning. SnapRAID's automatic commands never use force flags.

The old hourly mover and independent SnapRAID schedules are disabled. Their
ordinary service/CLI entry points require an inherited coordinator session for
storage work. A stale marker alone cannot authorize a move. `--dry-run` remains
available independently; even `--assume-quiescent` cannot bypass the configured
external maintenance guard.

**Borg destination and credentials are not configured in this repository yet.**
The nightly timer is consequently inactive. A manual run rejects missing
archive configuration before preparing applications. Once an archive command
is configured, host policy enables the timer at 02:00 Europe/Zurich. The timer
is not persistent: missed nights do not become daytime downtime after boot.
Recovery of an interrupted run is separate and runs at boot.

## Registering an application

Declare a participant beside the service implementation, conditional on that
application and maintenance being enabled. For example, a hypothetical service:

```nix
homelab.maintenance.participants.documents = {
  writerUnits = ["documents-web.service" "documents-worker.service"];
  activatorUnits = ["documents-import.timer"];
  resumeUnits = ["documents-web.service" "documents-worker.service"];

  # If this application requires downtime for capture, prepare must first
  # quiesce its writers. Otherwise a self-contained live export is permitted.
  prepare = ''
    # Record application state, then establish capture consistency.
  '';
  capture = ''
    # Application export into "$MAINTENANCE_EXPORT_DIR".
    # Return success only after a complete, consistent restore set exists.
  '';
  resume = ''
    # Undo this run's preparation, including after partial failure.
  '';
};
```

This is the registration shape, not a ready-to-run Paperless backup recipe.
Choose the actual service's supported export procedure and restoration test.

`writerUnits` includes all processes managed by systemd that can write the
moved storage, including setup/migration units. `resumeUnits` is the subset of
persistent daemons eligible for restart; completed setup/migration jobs should
not be explicitly restarted. Activators are restored only if previously active.
All declared units must exist. Transitioning units cause preflight to abort.

When the bulk-storage module is present, evaluation rejects a bulk consumer
missing from the maintenance writer declarations. Adding a service through
`homelab.bulkStorage` therefore requires registering its writers; the mover's
application list never needs editing. Out-of-band writers, containers or shares
must also be registered. These are cooperative systemd guards, not filesystem
access revocation for arbitrary shell commands.

Hooks receive:

| Variable | Meaning |
| --- | --- |
| `MAINTENANCE_STATE_DIR` | Persistent coordinator state directory. |
| `MAINTENANCE_RUN_DIR` | Unique directory for this run. |
| `MAINTENANCE_PARTICIPANT_DIR` | Private participant directory, available in application hooks. |
| `MAINTENANCE_EXPORT_DIR` | Fresh export directory for this participant/run. |
| `MAINTENANCE_SOURCES_FILE` | JSON array of the exact archive source paths; exists after capture succeeds. |

Capture export directories are automatically added to archive sources. Add live
files/directories through `backupSources`; do not substitute old exports after
failure. Hook order is participant-name order, with resume in reverse order.
Participants should not depend on each other's hooks. Shared infrastructure
needed by hooks/recovery goes into `supportUnits`; it cannot also be a guarded
writer.

Use the Rust helpers for application state and completed export publication:

```sh
maintenance-runner remember maintenance true
# Writes/fsyncs application-state.json in this participant directory.

maintenance-runner publish database.dump.tmp database.dump
# Fsyncs the temporary file/tree, renames it, and fsyncs its parent directory.
```

The export/state directories contain sensitive data and are private to root.
The state directory must be outside storage moved by the mover, on persistent
storage. Size `minimumFreeBytes` for the expected exports; the default preflight
reserve is 1 GiB, which does not promise an arbitrarily large export will fit.

## Connecting Borg

Add archive configuration in a backup/application module, alongside its SOPS
secrets and SSH known-host/key configuration. Initialize the repository and test
authentication first. An illustrative Borg 1.x archive command is:

```nix
homelab.maintenance.archive = [''
  export BORG_REPO="ssh://backup@example/./repository"
  export BORG_PASSCOMMAND="${pkgs.coreutils}/bin/cat ${config.sops.secrets.borg-passphrase.path}"
  export BORG_RSH="${pkgs.openssh}/bin/ssh -i ${config.sops.secrets.borg-ssh-key.path} -o BatchMode=yes"

  mapfile -d "" -t sources < <(
    ${pkgs.jq}/bin/jq -j '.[] + "\u0000"' "$MAINTENANCE_SOURCES_FILE"
  )
  test "''${#sources[@]}" -gt 0
  exec ${pkgs.borgbackup}/bin/borg create --stats \
    "::maintenance-$(basename "$MAINTENANCE_RUN_DIR")" "''${sources[@]}"
''];
```

Replace the example destination; declare the referenced secrets and known host.
Never put passwords/key contents in Nix scripts or the store. Borg nonzero
status, including warnings, conservatively fails the archive phase and skips
storage work. Configure remote retention/prune policy separately; local export
retention is not Borg archive retention. Any archive command must consume the
whole declared source list and report failure if it cannot do so.

Explicitly include bulk mounts when using filesystem-boundary restrictions.
Nextcloud's files below its home are on a nested bind mount; a snapshot of
`persist128` alone is not a complete Nextcloud backup.

## Failure, cancellation, and recovery

Only one coordinator/recovery process holds the exclusive lock. Preparation is
recorded before invoking each hook, so partial preparation is eligible for
cleanup. The full hook configuration and original restart list are recorded in
`pending.json` before preparation. Startup guards remain engaged while it exists.

A required failure stops forward progress, then attempts storage recovery and
resume. Archive failure normally resumes applications but remains a failed run.
Unresolved storage recovery or failed resume keeps the guard and journal for
inspection. Resume hooks are all attempted when safe; a surviving timed-out
process blocks further cleanup. A separate durable `restarting.json` covers a
crash between releasing guards and starting previously active services.

`maintenance-recover.service` runs at boot; `ExecStopPost` also retries recovery
after abnormal coordinator termination. Recovery uses the saved hook plan, so
a configuration change cannot silently forget an interrupted application. Keep
the corresponding system generation/store paths while recovery is pending;
garbage-collecting required scripts makes recovery fail closed. Writer services
are guarded by the journal rather than ordered after recovery, because recovery
itself must be able to start them without an ordering deadlock.

Do not delete `pending.json`, mover journals, or the lock to clear an error.
Inspect the failure, repair the underlying problem, then retry recovery.

When migrating an already-running host from standalone mover ownership, first
finish any old mover recovery using its previous configuration. Do not switch
ownership while its `maintenance.json` or transaction journals are outstanding.
New maintenance runs record the coordinator journal before invoking the mover,
so subsequent interruptions are handled by the shared recovery service.

```sh
sudo systemctl start maintenance-run.service
sudo systemctl stop maintenance-run.service     # cancel with cleanup
sudo systemctl start maintenance-recover.service
sudo journalctl -u maintenance-run -u maintenance-recover
sudo systemctl list-timers maintenance-run.timer
```

Starting `tier-mover.service` manually is deliberately rejected in the host's
externally managed mode. Start the maintenance run instead. With no archive
configured, configure Borg before attempting actual storage maintenance.

Run directories contain participant state/exports, `sources.json`, a capture
completion record, and `result.json`. Successful capture never reuses a previous
run's directory. By default the newest seven successful run directories are
retained. Failed directories are kept for inspection; remove them manually only
after confirming they are not referenced by pending recovery. Live-file restore
sets from a failed archive cannot be retried consistently after applications
resume: start a fresh capture. A self-contained export may be independently
retried if its complete source set was retained.

## Validation

```sh
cargo test --manifest-path pkgs/maintenance-runner/Cargo.toml
cargo clippy --manifest-path pkgs/maintenance-runner/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path pkgs/tier-mover/Cargo.toml
nix build .#checks.x86_64-linux.maintenance-vm
```

Rust tests cover ordering, partial preparation, stale exports, archive failure,
timeout, repeat runs, restart selection, saved-plan recovery and storage admission.
The Linux VM test covers actual systemd guards, cancellation and blocked recovery
across reboot. The VM check requires an x86_64 Linux builder with virtualization.
