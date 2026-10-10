# Nix configuration

This repository contains a NixOS configuration flake.

## Ephemeral root at boot

The systemd initrd imports `zpool`, then `rollback-root.service` rolls
`zpool/root` back to `zpool/root@blank` before `sysroot.mount` mounts it.
The root mount requires a successful rollback; a missing snapshot or failed
rollback stops normal boot instead of retaining the previous root state.
The sibling datasets for `/nix`, persistence, and NVMe data are unaffected.
The complete `/var/log` hierarchy is persisted on `persist128`; journald keeps
at most 1 GiB and 30 days of entries.

Disko creates the blank snapshot during initial installation. A rebuild does
not perform the rollback; changes to this initrd service take effect on reboot.
After deploying and rebooting, inspect the boot with:

```bash
sudo journalctl -b -u zfs-import-zpool.service -u rollback-root.service -u sysroot.mount
```

## Service bulk storage

`modules/nixos/bulk-storage.nix` keeps an application's usual paths while storing
its bulk files elsewhere. Services declare their needs; the module handles
**backing mount → directory ownership → bind mount → consuming services**.
This supports `/data` mounting later than the early-boot `/persist*` datasets.

Declare storage in the service's file, for example:

```nix
homelab.bulkStorage.nextcloud = {
  source = "/data/nextcloud";
  target = "/var/lib/nextcloud/data";
  user = "nextcloud";
  group = "nextcloud";
  services = ["nextcloud-setup" "phpfpm-nextcloud" "nextcloud-cron" "nextcloud-update-db"];
};
```

The backing filesystem and user/group must already be declared. Paths should
be absolute and normalized (no trailing slash or `..`). Permissions default to
`0750`; `services` lists systemd names without `.service`. A service can depend
on multiple entries. Directory creation is not recursive ownership repair, and
mounting over an existing target does **not** migrate its contents.

Keep config/database persistence and application settings in the service file.
This module neither creates disks nor moves files or makes backups. Back up bulk
sources separately: a `/persist*` snapshot does not include a nested bulk mount.

## Pre-commit checks

Install the hooks once:

```bash
pre-commit install
```

The hooks run three read-only checks:

- Alejandra checks Nix formatting.
- Statix checks Nix lint issues.
- `nix flake check --no-build` evaluates the flake.

The hooks report problems but do not modify files. To fix issues locally, run:

```bash
nix fmt
nix run nixpkgs#statix -- fix
pre-commit run --all-files
```

The first two commands may modify files. The final command verifies that the
configuration passes all checks.

The formatting and flake checks use tools declared by the flake. The Statix
hook may download Statix the first time it runs.

Run the checks manually at any time with:

```bash
pre-commit run --all-files
```

## Cold-file tier mover

The mover's design, safety model, configuration reference, and operating guide
are documented in [`pkgs/tier-mover/README.md`](pkgs/tier-mover/README.md).

The host configuration uses `/nvme_data1` as the source and the entries in
`hddDataMountpoints` as independent destinations. Applications continue to use
`/data`; there is no separate HDD mergerFS mount. The mover is now a task in the
shared maintenance window and has no independent hourly schedule. It requires
the coordinator's verified writer suspension and session lock.

## Nightly maintenance

The lifecycle is **prepare → capture → suspend writers → archive → maintain
storage → resume**. Applications register consistent capture and restoration
hooks beside their service configuration. The Rust runner handles sequencing,
timeouts, persistent recovery and declared storage writers; the mover has no
application-specific suspension list.

Read [docs/maintenance.md](docs/maintenance.md) for the contract, application
registration example, Borg configuration, operation and recovery procedures.
Nextcloud, Immich and storage are integrated. The Borg destination, SOPS
credentials and 02:00 timer are declared. Confirm that the BorgBase repository
has been initialized and a full run succeeds before relying on nightly backups.
Independent mover/SnapRAID schedules have been disabled.

Immich uses the native NixOS service with CPU machine learning and a separately
pinned current Immich package. Intel Quick Sync accelerates video encoding and
decoding; the shared Intel drivers live in `nixos/configuration.nix`, while
Immich grants access only to its render device. Its public address is
`https://immich.nicholasbehr.ch`. PostgreSQL's major version and persistent
cluster storage are host settings in `nixos/postgresql.nix`, so disabling
Nextcloud does not remove Immich's database. The applications have separate
databases, Redis instances and bulk-data directories. See
[docs/immich.md](docs/immich.md) for Immich operation and verification, and
[docs/maintenance.md](docs/maintenance.md) for the shared backup lifecycle.

## Editing secrets on the Mac

Run from the repository root. The Mac's existing age identity is stored at
`~/.config/sops/age/keys.txt`; `.sops.yaml` defines the encryption recipients.
SOPS can run from the pinned nixpkgs input without a permanent installation.

Open the decrypted file in VS Code through SOPS:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  SOPS_EDITOR="code --wait" \
  nix run --inputs-from . nixpkgs#sops -- secrets/secrets.yaml
```

The `code` command must be on PATH. If it is missing, use VS Code's Command
Palette action **Shell Command: Install 'code' command in PATH**.


## First installation from a USB stick

Use the standard x86_64 NixOS installer USB in UEFI mode. These target-side
commands erase every disk listed in `nixos/disks.nix`; verify those IDs first. The public
repository is `https://github.com/NicholasBehr/nix-lab.git`. The `behrn`
password hash is stored in SOPS as `behrn-password-hash`. Restore the host key
as described below before installing; it is required to decrypt the hash
before user creation.

On the installer console, connect networking, enable temporary SSH, and note
the installer IP address:

```bash
sudo -i
passwd
systemctl start sshd
ip addr
```

From the Mac, connect to the temporary installer. Run all remaining commands
in that SSH session:

```bash
ssh root@INSTALLER_IP
export NIX_CONFIG='experimental-features = nix-command flakes'
nix run nixpkgs#git -- clone https://github.com/NicholasBehr/nix-lab.git
cd nix-lab
nix run github:nix-community/disko -- -m disko -f .#viktoria
```

There must be a space between `--` and `clone`; `--clone` is a Nix option.
Disko mounts the new system at `/mnt`. Before installing, use nano to paste the
existing host private key from 1Password. This key is persisted and is the Age
identity already represented by the `&viktoria` recipient in `.sops.yaml`.

```bash
mkdir -p /mnt/persist128/etc/ssh
nano /mnt/persist128/etc/ssh/ssh_host_ed25519_key
chmod 600 /mnt/persist128/etc/ssh/ssh_host_ed25519_key
ssh-keygen -y -f /mnt/persist128/etc/ssh/ssh_host_ed25519_key > /mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
chmod 644 /mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
```

In nano, save with `Ctrl+O`, press `Enter`, then exit with `Ctrl+X`. Generate
the hardware-specific configuration and install:

```bash
nixos-generate-config --no-filesystems --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix nixos/
nixos-install --root /mnt --flake /root/nix-lab#viktoria --no-root-passwd
reboot
```

The installer SSH session disconnects. On the Mac, discard the temporary
installer identity, then log in to the installed host as `behrn`:

```bash
ssh-keygen -R INSTALLER_IP
ssh behrn@HOST
```

The first login already uses the 1Password host key and can decrypt application
secrets with the existing `.sops.yaml` recipient. Copy the generated
`nixos/hardware-configuration.nix` back to the public repository after boot.

## Deploying changes over SSH

Use this workflow from the repository root on the Mac whenever configuration
changes should be deployed to the installed system. The `homelab` SSH alias
logs in as `behrn`. The server is both the build host and target host, so the
x86_64-linux configuration is built on the correct architecture.

Before deploying, run the repository checks and inspect the pending changes:

```bash
pre-commit run --all-files
git status --short
```

Git flakes ignore untracked files. Stage any new file used by the configuration
before deploying; committing or pushing is not required.

Deploy with `test` first. This activates the new configuration but does not make
it the boot default:

```bash
nix run --inputs-from . nixpkgs#nixos-rebuild-ng -- \
  --flake .#viktoria \
  --build-host homelab \
  --target-host homelab \
  --use-substitutes \
  --ask-sudo-password \
  --no-reexec \
  test
```

Enter `behrn`'s sudo password when prompted. Verify that the host is reachable
and has no failed systemd units from another terminal:

```bash
ssh homelab '
  readlink -f /run/current-system
  systemctl --failed --no-pager
'
```

Also verify the services or functionality affected by the change. If the test
is healthy, repeat the deployment with `switch` to make the new generation the
boot default:

```bash
nix run --inputs-from . nixpkgs#nixos-rebuild-ng -- \
  --flake .#viktoria \
  --build-host homelab \
  --target-host homelab \
  --use-substitutes \
  --ask-sudo-password \
  --no-reexec \
  switch
```

The command transfers the local flake closure over SSH; the repository does not
need to be cloned on the server. `--use-substitutes` lets the server download
available build products directly from binary caches. `--ask-sudo-password`
uses `behrn`'s sudo access for activation, and `--no-reexec` prevents the Mac
from trying to execute the target's Linux rebuild binary.

Rebooting after a `test` returns to the last configuration deployed with
`switch`. To explicitly return to the previous switched generation:

```bash
ssh -t homelab 'sudo nixos-rebuild switch --rollback'
```
