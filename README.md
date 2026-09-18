# Nix configuration

This repository contains a NixOS configuration flake.

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

## First installation from a USB stick

Use the standard x86_64 NixOS installer USB in UEFI mode. These target-side
commands erase every disk listed in `nixos/disks.nix`; verify those IDs first. The public
repository is `https://github.com/NicholasBehr/nix-lab.git`. The `behrn`
password is a yescrypt hash in Nix, so the first installation needs no SOPS
decryption.

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
