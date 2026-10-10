# Immich operations

Immich is available at `https://immich.nicholasbehr.ch`. On a new installation,
register the first administrator through the web interface. No Nextcloud
credentials are used. PostgreSQL authenticates the local `immich` Linux user
through its Unix socket; Redis has a separate local instance and socket.

## Configuration and updates

`services/immich.nix` owns the application, reverse proxy, media mount and
maintenance hooks. PostgreSQL's major version and persistent cluster are
declared in `nixos/postgresql.nix`. Setting `services.immich.enable = false`
also removes its proxy, mounts and maintenance registration. Disabling
Nextcloud leaves PostgreSQL and Immich enabled.

The `nixpkgs-immich` flake input supplies Immich and its matching machine
learning package. The initial pin supplies 3.3.1; the host remains on NixOS
26.05 because that release's Immich 2.x package is marked insecure. Review
Immich release notes and take a successful coordinated backup before updating
this input. Test the new configuration before switching the boot generation.
A NixOS rollback does not reverse database migrations; restoration requires
a matching application version, database dump and media tree.

## Acceleration

The shared Intel drivers (`intel-media-driver` and `vpl-gpu-rt`) are declared
under `hardware.graphics` in `nixos/configuration.nix`. Immich selects Quick
Sync for video encoding and decoding and grants its server access to
`/dev/dri/renderD128`. This node was verified to use the Intel `i915` driver.
Future Jellyfin configuration can use the same drivers with its own device
permissions and transcoding settings.

Facial recognition and smart search use the native CPU machine learning
service. Its device sandbox remains enabled. Downloaded models are persisted
at `/var/cache/immich`; they can be downloaded again and are not backed up.

After a test video upload, check for both the QSV encoding/decoding message and
successful completion, with no software fallback or FFmpeg error. Verify video
playback in the browser. For facial recognition, upload several clear photos
of one person, check the face-detection and person-group messages, and verify
the group in the People view.

```sh
systemctl --failed
systemctl status immich-server immich-machine-learning redis-immich
journalctl -u immich-server -u immich-machine-learning --since '10 minutes ago'
curl http://127.0.0.1:2283/api/server/ping
curl http://localhost:3003/ping
findmnt /var/lib/immich/media
findmnt /var/lib/postgresql
```

## Backup and restoration

The nightly maintenance run stops Immich before capturing its PostgreSQL dump
and keeps its media stable until Borg finishes. Both applications remain
stopped through the shared storage work. See [maintenance.md](maintenance.md)
for timing, recovery and the initial large-library import considerations.

Restore from one successful archive:

- `/var/lib/immich`, including its explicitly archived `media` bind mount;
- that run's `immich/export/database.dump` beneath
  `/persist128/var/lib/maintenance/runs/`;
- the matching application version recorded in `immich-package.txt` and the
  Nix configuration needed to recreate database roles and extensions.

Keep the application stopped during restoration. Restore original media paths
and ownership before starting it. A useful commissioning check is to extract
the small test library from Borg, restore the dump into a temporary database,
verify that every original referenced by the restored database exists, and
compare the extracted files with the live originals. A full disaster recovery
exercise should also start an isolated instance with the restored data.

Include the six media-directory `.immich` mount markers in a restore. Immich
rewrites their timestamp contents during startup, so validate their presence
separately when comparing an archive with a running instance. Photo, video and
other restored files should still match byte-for-byte when uploads and
background changes are paused.

On 2026-10-10, test activation passed service and persistent-mount checks,
Quick Sync encoding and decoding completed successfully, and CPU face
processing created a person group. Browser playback and grouping were
confirmed by the administrator.

The offsite archive `maintenance-1791626147917896776-113401` was also verified:
its Immich dump restored successfully into a temporary PostgreSQL database,
all 9 referenced originals were present, and 29 restored files matched the
live test library byte-for-byte. All 6 storage markers were validated
separately. The temporary database and extracted data were then removed.
This verifies database restoration and file recovery; it was not a complete
isolated application recovery exercise.
