# tier-mover

`tier-mover` is a one-way cold-file mover. It keeps a fast source filesystem
below an absolute usage limit by moving the least recently accessed files to
one or more slower destination filesystems. Files never move back.

The program operates on the backing filesystems directly. A union filesystem
such as mergerFS may still expose the source and destinations as one path to
applications, but it is not involved in a move. Direct access gives the mover
stable filesystem identities, explicit free-space accounting, durable writes,
and atomic publication of each destination file.

## Decision model

A run reads the source's authoritative used-space value. Generic filesystems
use `statvfs`; a ZFS source uses the dataset's `used` property. If usage is at
or below `startAboveUsed`, the run exits before stopping any consumers.

When movement is required, the mover:

1. Scans regular files without following symlinks or crossing filesystem
   boundaries.
2. Excludes configured paths, hard-linked files, files changed too recently,
   and files with future timestamps.
3. Sorts candidates by access time, oldest first, with path as a deterministic
   tie-breaker.
4. Starts with files whose logical size is at least `initialMinFileSize`.
5. Stops configured consumers and prevents them from restarting while a move
   or recovery is in progress.
6. Dispatches work to at most one worker per destination. The central
   scheduler shares a single predicted source usage value and reserves source
   and destination space before dispatching each file.
7. Reconciles the prediction with authoritative source usage after in-flight
   moves finish.
8. Reduces the size threshold by `sizeThresholdPercent` when no candidates at
   the current threshold remain, down to `minimumFileSize`.
9. Finishes when usage reaches `stopAtUsed`, no eligible file or destination
   capacity remains, measured usage stops decreasing, or the run deadline is
   reached.

The gap between `startAboveUsed` and `stopAtUsed` is hysteresis. It prevents an
hourly job from repeatedly moving a small file as usage fluctuates around one
boundary.

Source prediction uses each file's allocated blocks, which estimates the space
that removing it can reclaim. Destination reservation uses logical file size
plus a small metadata allowance because a sparse or compressed source may
expand when copied to another filesystem. `destinationFreeReserve` remains
unallocated on every destination.

## Move and recovery guarantees

Each worker performs one journaled transaction at a time:

1. Record and `fsync` the intended source and destination identities.
2. Copy into a private `.tier-mover/payload` file on the destination while
   preserving sparse zero regions.
3. Compare the complete source and destination contents.
4. Preserve and verify ownership, mode, access and modification timestamps,
   and Linux extended attributes.
5. `fsync` the prepared file and its containing directory.
6. Publish it at the final relative path with `linkat`, which is atomic and
   cannot replace an existing name.
7. Revalidate the source inode and metadata, then unlink and durably sync the
   source directory.
8. Remove the persistent transaction journal.

A destination conflict on any configured destination causes that candidate to
be skipped. The mover never overwrites a destination file.

The source root, destination roots, and state directory are opened as pinned
directory descriptors. Linux `openat2` resolution rejects symlinks, path
escapes, and nested mount crossings. A component-by-component `openat`
fallback provides the same essential checks on kernels where `openat2` is
unavailable. Declared mount identities are checked before any transaction, and
pinned root identities are rechecked while moving.

After a crash or power loss, the next run examines the durable journal and
either discards an unpublished staging file or verifies a published copy before
removing a surviving source. Ambiguous states preserve both copies and keep
consumers blocked for inspection. The state directory must therefore reside on
persistent storage and must not be deleted to clear an error.

## NixOS configuration

The NixOS module is
[`modules/nixos/tier-mover.nix`](../../modules/nixos/tier-mover.nix). The source
and every destination must also be declared in NixOS `fileSystems`.

```nix
{
  imports = [./modules/nixos/tier-mover.nix];

  homelab.tierMover = {
    enable = true;
    source = "/fast";
    destinations = ["/archive-a" "/archive-b"];
    stateDirectory = "/persist/var/lib/tier-mover";

    startAboveUsed = "2T";
    stopAtUsed = "1800G";
    initialMinFileSize = "40G";
    minimumFileSize = "1M";
    sizeThresholdPercent = 90;
    destinationFreeReserve = "100G";

    quiesceServices = ["media-server"];
    requireInactiveServices = ["snapraid-sync" "snapraid-scrub"];

    timer = {
      enable = true;
      interval = "hourly";
    };
  };
}
```

The module derives these implementation details from `config.fileSystems`:

- Expected device and filesystem type for every storage root
- ZFS accounting and the source dataset when the source is ZFS
- Generic filesystem accounting for other source filesystem types
- One independent worker per destination
- Runtime tools needed by the selected accounting method

It writes the derived runtime configuration to
`/etc/tier-mover/config.json`. The JSON is an internal interface between the
module and binary; callers should configure the NixOS options instead.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Install and configure the mover. |
| `source` | required | Fast source filesystem mountpoint. |
| `destinations` | required | Nonempty list of independent destination filesystem mountpoints. |
| `stateDirectory` | `/var/lib/tier-mover` | Persistent private directory for the process lock, maintenance state, and transaction journals. |
| `startAboveUsed` | `2T` | Start moving only when source usage is greater than this value. |
| `stopAtUsed` | `1800G` | Stop after measured source usage is at or below this value; it must be lower than `startAboveUsed`. |
| `initialMinFileSize` | `40G` | Initial minimum logical candidate size. |
| `minimumFileSize` | `1M` | Lowest candidate-size threshold. |
| `sizeThresholdPercent` | `90` | Multiply the current size threshold by this percentage after exhausting a pass. |
| `destinationFreeReserve` | `100G` | Free space retained independently on every destination. |
| `minimumModificationAgeSeconds` | `3600` | Require both modification and inode-change times to be at least this old. |
| `maximumRunSeconds` | `7200` | Abort a run after this duration; normal recovery is attempted before exit. |
| `exclude` | `.snapraid`, `.zfs`, `lost+found` | Relative source paths whose complete subtrees are ignored. |
| `quiesceServices` | `[]` | Services to stop only when moves or recovery are needed and restart afterward; omit `.service`. |
| `requireInactiveServices` | `[]` | Services that must already be inactive during movement; omit `.service`. |
| `timer.enable` | `false` | Enable the systemd timer. |
| `timer.interval` | `hourly` | systemd `OnCalendar` expression. |

Size values are case-sensitive unsigned integers followed by an optional unit.
`K`, `M`, `G`, and `T` use powers of 1024, as do `KiB`, `MiB`, `GiB`, and
`TiB`. `KB`, `MB`, `GB`, and `TB` are decimal. `B` or no suffix means bytes.
Fractional and negative values are rejected.

`quiesceServices` should contain every application that can write through the
union mount while files move. The module adds a persistent systemd condition
to those services so they cannot restart while recovery is pending.
`requireInactiveServices` is appropriate for maintenance tools such as
SnapRAID that must never overlap a move. The same recovery guard prevents them
from starting during an unfinished transaction.

The timer is persistent and has a randomized delay of up to ten minutes. A
missed run is made up after boot; the random delay avoids aligning storage work
with other hourly jobs.

## Operation

Inspect a plan without stopping consumers or changing file data:

```console
sudo tier-mover --config /etc/tier-mover/config.json --dry-run
```

Run the configured systemd service and inspect its log:

```console
sudo systemctl start tier-mover.service
sudo journalctl -u tier-mover.service --no-pager
```

Explicitly process a pending journal without selecting new files:

```console
sudo tier-mover --config /etc/tier-mover/config.json --recover-only
```

The binary exits with status 0 when no movement is needed, the target is
reached, recovery succeeds, or a dry run completes. Status 2 means the run was
safe but could not reach `stopAtUsed`; the NixOS service treats this as success.
Status 1 reports an error.

The low-level `--assume-quiescent` flag permits an actual move without
configured `quiesceUnits`. It is intended for isolated tests where the caller
has already stopped every writer. Normal NixOS deployments should use
`quiesceServices`.

## Filesystem behavior

- Access-time ordering is only as precise as the source mount's atime policy.
  `relatime` is usually a practical balance; `noatime` prevents useful coldness
  updates.
- ZFS snapshots may retain blocks after a source file is removed. The mover
  remeasures `zfs used` and stops after repeated rounds with no reclamation.
- Hard-linked files are skipped because moving one name would change hard-link
  semantics. Symlinks, devices, sockets, and other non-regular files are also
  ignored.
- Empty source directories are retained. Destination parent directories are
  created with source ownership, mode, timestamps, and extended attributes.
  Existing destination directories must have compatible metadata.
- Source and destinations must be separate filesystems, and destinations must
  also be separate from one another.

## Build and test

Build the Linux package through the flake:

```console
nix build .#packages.x86_64-linux.tier-mover
```

For development, run:

```console
cargo test --manifest-path pkgs/tier-mover/Cargo.toml
cargo clippy --manifest-path pkgs/tier-mover/Cargo.toml --all-targets -- -D warnings
```
