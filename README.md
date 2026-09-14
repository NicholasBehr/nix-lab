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
commands erase every disk listed in `nixos/disks.nix`. Verify those disk IDs
before continuing. The repository is public at
`https://github.com/NicholasBehr/nix-lab.git`. The configured `behrn` password
is a yescrypt hash in Nix, so this first installation does not need SOPS to
decrypt a user password.

The server SSH host private key from 1Password is also its SOPS Age identity.
Before booting, export that existing private key as `ssh_host_ed25519_key` to a
small FAT-formatted USB drive labelled `HOSTKEY`, or attach an equivalent KVM
virtual-media image. Keep that removable media private and detach it after
installation. Do not put either host key in Git.

On the NixOS installer, connect networking, become root, and type:

```bash
sudo -i
export NIX_CONFIG='experimental-features = nix-command flakes'
nix run nixpkgs#git -- clone https://github.com/NicholasBehr/nix-lab.git
cd nix-lab
nix run github:nix-community/disko -- -m disko -f .#viktoria
```

There must be a space between `--` and `clone`; `--clone` is interpreted as a
Nix option.

Disko mounts the new system at `/mnt`. Mount the `HOSTKEY` media and copy its
private key to the persistent dataset:

```bash
mkdir /key
mount /dev/disk/by-label/HOSTKEY /key
install -D -m600 /key/ssh_host_ed25519_key /mnt/persist128/etc/ssh/ssh_host_ed25519_key
ssh-keygen -y -f /mnt/persist128/etc/ssh/ssh_host_ed25519_key >/mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
umount /key
```

Generate the hardware-specific file and install:

```bash
nixos-generate-config --no-filesystems --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix nixos/
nixos-install --root /mnt --flake /root/nix-lab#viktoria --no-root-passwd
reboot
```

Remove both USB devices. Log in from the Mac using the private key matching the
public `behrn` key configured in `nixos/configuration.nix`. Copy the generated
`nixos/hardware-configuration.nix` back to the public repository after boot so
future rebuilds use the host's actual hardware configuration.

After the first SSH login, configure SOPS application secrets. The host key is
already present and persistent, so derive its Age recipient on the Mac from
the public key exported from 1Password, replace the `&viktoria` value in
`.sops.yaml`, run `sops updatekeys secrets/secrets.yaml`, and push. Pull the
change on the host and run `sudo nixos-rebuild switch --flake .#viktoria`.

## SOPS bootstrap and recovery

This host uses `sops-nix` and derives its Age identity from the persistent
`/etc/ssh/ssh_host_ed25519_key`. It does not have a separate server Age private
key. The host SSH private key is stored in `/persist128`, so it survives the
root rollback. `secrets/secrets.yaml` is encrypted to both this host-derived
Age recipient and the Mac recovery Age recipient in `.sops.yaml`.

Before the first installation, export the existing host public key from
1Password to a temporary local file and derive its Age recipient. Do not commit
either key to this repository:

```bash
nix run nixpkgs#ssh-to-age -- < \
	/path/to/ssh_host_ed25519_key.pub
```

Replace the value after `&viktoria` in `.sops.yaml` with the printed `age1...`
recipient. Then update the encrypted file using the Mac recovery identity:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
nix shell nixpkgs#sops --command sops updatekeys secrets/secrets.yaml
```

For application secrets, create or edit `secrets/secrets.yaml` using the Mac
Age identity, then commit and push the encrypted file. It is intended to be
public. Add each secret to the `sops.secrets` attribute set in
`nixos/configuration.nix` only when a NixOS service needs it.

For disk-loss recovery, restore those same two SSH host-key files into
`/persist128/etc/ssh` before rebuilding with the USB flow above. The host can
then derive the same Age identity and decrypt its SOPS secrets. The Mac
recovery Age key remains a second independent way to decrypt and edit secrets.
