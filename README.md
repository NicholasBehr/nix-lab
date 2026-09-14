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
`https://github.com/NicholasBehr/nix-lab.git`; it must include the encrypted
`secrets/secrets.yaml` file.

The server SSH host private key is also its SOPS Age identity. Before booting,
put the backed-up `ssh_host_ed25519_key` alone on a small FAT-formatted USB
drive labelled `HOSTKEY`, or attach an equivalent KVM virtual-media image.
Keep that removable media private and detach it after installation. Do not put
the key in Git.

On the NixOS installer, connect networking, become root, and type:

```bash
sudo -i
export NIX_CONFIG='experimental-features = nix-command flakes'
nix run nixpkgs#git -- clone https://github.com/NicholasBehr/nix-lab.git /tmp/n
cd /tmp/n
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
nixos-install --root /mnt --flake /tmp/n#viktoria --no-root-passwd
reboot
```

Remove both USB devices. Log in from the Mac using the private key matching the
public `behrn` key configured in `nixos/configuration.nix`.

For a brand-new host key, generate it on the Mac first, add the derived Age
recipient to `.sops.yaml`, run `sops updatekeys secrets/secrets.yaml`, commit
and push those public-repository changes, then put the generated private host
key on the temporary `HOSTKEY` media before following these steps.

## SOPS bootstrap and recovery

This host uses `sops-nix` and derives its Age identity from the persistent
`/etc/ssh/ssh_host_ed25519_key`. It does not have a separate server Age private
key. The host SSH private key is stored in `/persist128`, so it survives the
root rollback.

Before the first installation, generate a host SSH key on the Mac and retain a
copy of the private key in the password manager. Do not commit either key to
this repository:

```bash
mkdir -p ~/.local/share/nix-lab/viktoria
ssh-keygen -t ed25519 -N '' \
	-f ~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key \
	-C viktoria
nix run nixpkgs#ssh-to-age -- < \
	~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key.pub
```

The final command prints the host's public Age recipient. Add it and the public
Age recipient of the Mac recovery key to `.sops.yaml`:

```yaml
keys:
	- &viktoria age1replace-with-host-recipient
	- &mac-recovery age1replace-with-mac-recipient
creation_rules:
	- path_regex: secrets/.*\\.yaml$
		key_groups:
			- age:
					- *viktoria
					- *mac-recovery
```

Create and encrypt the password hash using the Mac Age identity:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
nix shell nixpkgs#mkpasswd --command mkpasswd -m yescrypt
nix shell nixpkgs#sops --command sops secrets/secrets.yaml
```

Set `behrn-password` to the hash produced by `mkpasswd`. The configuration
uses it as `hashedPasswordFile`, and it is available early enough to create the
user during activation.

During installation, after the persistent filesystems are mounted at `/mnt`,
copy the generated host key into the persistent dataset before running
`nixos-install`:

```bash
install -d -m 700 /mnt/persist128/etc/ssh
install -m 600 ~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key \
	/mnt/persist128/etc/ssh/ssh_host_ed25519_key
install -m 644 ~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key.pub \
	/mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
nixos-install --flake .#viktoria --no-root-passwd
```

For disk-loss recovery, restore those same two SSH host-key files into
`/persist128/etc/ssh` before rebuilding. The host can then derive the same Age
identity and decrypt its SOPS secrets. The Mac recovery Age key remains a
second independent way to decrypt and edit the secrets.
