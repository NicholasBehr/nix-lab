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

