# Paperless operations

Paperless-ngx is configured for `https://paper.nicholasbehr.ch`. The public
nginx virtual host uses an individual ACME certificate and proxies to the
Paperless web service on `127.0.0.1:28981`. Self-signup is disabled. Local
PostgreSQL and Redis use Unix sockets; neither needs a public port or a SOPS
password. The NixOS module generates a persistent signing key on first start.

## Configuration and version policy

`services/paperless.nix` owns the application, reverse proxy, storage mounts
and maintenance hooks. The `nixpkgs-paperless` flake input supplies both the
Paperless 3 package and its matching NixOS service module. The host remains on
NixOS 26.05. The initial lock resolves to Paperless 3.3.0. Update only this
input when reviewing Paperless releases; review its release notes and take a
successful coordinated backup before a package change. The service's database
migration runs on startup. A NixOS rollback cannot reverse that migration.

For the eventual NixOS 26.11 host upgrade, check the release's Paperless package
and module together. Remove the separate input only after a test activation and
restore review show that the stable pair is suitable. Keep `system.stateVersion`
at `26.05`.

OCR uses German and English. The `auto` OCR mode skips OCR for PDFs with text.
Paperless always retains the original; `auto` archive generation makes a
searchable PDF/A copy for scans and skips a duplicate archive for digital PDFs
that already contain text. Tika and Gotenberg are disabled, keeping the
supported intake focused on PDFs and Paperless's native image handling. The web
upload limit is 200 MiB. The consumer polls its mergerFS-backed intake every
10 seconds. See the [Paperless configuration](https://docs.paperless-ngx.com/configuration/)
and [v3 migration guide](https://docs.paperless-ngx.com/migration-v3/) for
setting semantics.

| Data | Application path | Backing storage |
| --- | --- | --- |
| Originals, PDF/A copies, thumbnails | `/var/lib/paperless/media` | `/data/paperless/media` |
| Incoming files | `/var/lib/paperless/consume` | `/data/paperless/consume` |
| Signing key, search index, application state | `/var/lib/paperless` | `/persist128/var/lib/paperless` |
| Database | PostgreSQL `paperless` | `/persist16/var/lib/postgresql` |

The consume directory is private to the Paperless user. It is an intake queue,
not a place to retain a second copy; Paperless removes successfully consumed
files. Do not point it at `/data/nextcloud` or write into Nextcloud's data
directory. A future Nextcloud drop should use a small WebDAV/API bridge to copy
completed uploads into this intake, with separate credentials and duplicate
handling. Web upload is the only configured intake today.

## Commissioning and checks

Deploy using the repository's [test then switch workflow](../README.md#deploying-changes-over-ssh).
Ensure DNS for `paper.nicholasbehr.ch` reaches this host and port 80 can complete
ACME HTTP-01. On the host, create the sole account interactively after the
service starts:

```sh
sudo paperless-manage createsuperuser
```

Choose a unique strong password. Then sign in, open **My Profile**, enable
two-factor authentication and save the recovery codes outside Paperless. The
public endpoint stays behind Paperless's login; no shared Nextcloud account or
automatic signups are configured. Paperless describes the 2FA steps in its
[usage guide](https://docs.paperless-ngx.com/usage/#two-factor-authentication).

Check the service, mounts and local dependencies:

```sh
systemctl --failed
systemctl status paperless-scheduler paperless-consumer paperless-web paperless-task-queue
systemctl status redis-paperless postgresql nginx
journalctl -u paperless-scheduler -u paperless-consumer -u paperless-web -u paperless-task-queue --since '10 minutes ago'
findmnt /var/lib/paperless/media
findmnt /var/lib/paperless/consume
findmnt /var/lib/paperless
curl -I https://paper.nicholasbehr.ch
```

Upload one scanned German or English PDF and one digital PDF with selectable
text. Confirm the scan has searchable text, its original and PDF/A archive are
present, and the digital PDF has its original without an extra archive. Check
the upload, consumer and worker logs for errors. No Office document conversion
is configured.

On 2026-10-14, the corrected `test` activation started all four Paperless units
without new warnings. The state, media and consumption mounts resolved to their
expected backing filesystems. The public login page returned HTTP 200 with a
valid TLS certificate. The administrator confirmed creation of admin and normal
user accounts. The sample OCR quality and digital-PDF auto-skip checks above
remain to be done. The backup restore check below passed.

## Backup and restoration

The nightly shared maintenance run stops scheduler intake and allows the worker
up to 15 minutes to finish active OCR work before capturing a custom-format
PostgreSQL dump. All four Paperless writers stay stopped while Borg archives the
dump, local state, both explicit bulk bind mounts and the exact package. The
15-minute worker stop grace period fits within the maintenance hook's
30-minute deadline. The maintenance nginx page serves a static 503 response
during the outage. See
[maintenance.md](maintenance.md) for scheduling, recovery and Borg operation.

Restore from **one successful archive** using the recorded Paperless package:

- Restore `paperless/export/database.dump` from that run's export directory.
- Restore `/var/lib/paperless` and its explicitly archived `media` and `consume`
  mount paths with `paperless:paperless` ownership. This includes the signing
  key and search index. The mount targets map to `/data/paperless` on this host.
- Recreate the `paperless` PostgreSQL role and database through the NixOS module,
  restore the dump with `pg_restore`, and start Paperless only after the matching
  state and media are in place.

Redis does not need restoration. Inspect the task list and intake directory
after restart for work interrupted by a failed backup or shutdown. Validate a
test restore into a separate instance: load the dump into a temporary database,
check that restored documents have their original files, and open sampled
originals and archives. `pg_restore --list` during nightly capture verifies
dump structure; it is not a full restoration test. Paperless's own
[backup guidance](https://docs.paperless-ngx.com/administration/#making-backups)
also requires the media, application data and database to form one restore set.

On 2026-10-14, a manual coordinated maintenance run completed in 44 seconds.
Paperless's prepare and capture hooks succeeded, including `pg_restore --list`
on its new database dump. Borg created
`maintenance-1792005137472723939-329280` with 80,184 files across all
participants. Paperless, Immich and Nextcloud returned static HTTP 503 responses
while their writers were stopped. After the run, all checked service units were
active, all three public endpoints returned HTTP 200, Nextcloud had left
maintenance mode, and no maintenance recovery journal remained. Paperless had
no new warnings.

A subsequent `maintenance-borg list --short` check found the dump at
`persist128/var/lib/maintenance/runs/1792005137472723939-329280/paperless/export/database.dump`,
plus the state index, media and consume directories, and the exact
`paperless-ngx-3.3.0` store path. The restore check loaded that archived dump
into a temporary database and found three users and one document. It also
extracted the document's original PDF and PDF/A archive copy from Borg; both
matched the live files by SHA-256. No whole-instance restore was attempted.

To repeat this check from a workstation with this repository checked out:

```sh
scp scripts/verify-paperless-backup.sh homelab:/tmp/verify-paperless-backup.sh
ssh -t homelab 'sudo bash /tmp/verify-paperless-backup.sh maintenance-1792005137472723939-329280'
```

The script extracts the dump into a private temporary file, checks its
structure, loads it into a uniquely named temporary PostgreSQL database, then
checks the restored user and document tables. For the first restored document,
it also extracts its original PDF and any PDF/A copy from Borg and compares
their SHA-256 hashes with the live media files. It removes both the temporary
file and database on exit, leaving the live `paperless` database alone. For an
older archive, a later document rename or replacement can make the live-file
comparison fail even when the archived copy is sound.
