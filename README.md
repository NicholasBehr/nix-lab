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

These steps install `viktoria` from the standard x86_64 NixOS graphical or
minimal installer USB. They erase every disk listed in `nixos/disks.nix`; check
the disk IDs on the target before running Disko. The Git repository is public,
but the SSH host private key and the Mac Age recovery private key must never be
committed to it.

Before booting the USB stick, ensure that the public repository contains the
encrypted `secrets/secrets.yaml` file. Keep a copy of the server host private
key generated below in the password manager. It is the server's SSH identity
and its SOPS Age decryption identity.

1. Boot the NixOS USB stick in UEFI mode, connect to the network, and become
	 root:

	 ```bash
	 sudo -i
	 nix --extra-experimental-features 'nix-command flakes' run nixpkgs#git -- \
		 clone https://github.com/OWNER/nix-lab.git /tmp/nix-lab
	 cd /tmp/nix-lab
	 ```

	 Replace `OWNER` with the public GitHub account or organisation. For a
	 different remote, use its public HTTPS clone URL.

2. Verify that every entry in `nixos/disks.nix` names the intended target
	 disk. The following command destroys and repartitions all of those disks,
	 creates the ZFS pool, and mounts its filesystems below `/mnt`:

	 ```bash
	 nix --extra-experimental-features 'nix-command flakes' run \
		 github:nix-community/disko -- \
		 --mode disko --root /mnt ./nixos/disko.nix
	 ```

3. Generate hardware-specific configuration, retaining Disko as the owner of
	 filesystem declarations. Copy the generated file into the cloned checkout
	 for this initial installation, then commit its hardware-specific contents to
	 the public repository after the machine boots:

	 ```bash
	 nixos-generate-config --no-filesystems --root /mnt
	 cp /mnt/etc/nixos/hardware-configuration.nix \
		 ./nixos/hardware-configuration.nix
	 ```

4. Retrieve the backed-up host private key from the password manager into a
	 temporary file on the installer. Do not type it into the shell history and
	 do not place it in the Git checkout. Copy it to the mounted persistent
	 dataset, where impermanence preserves it:

	 ```bash
	 install -d -m 700 /mnt/persist128/etc/ssh
	 install -m 600 /path/to/retrieved/ssh_host_ed25519_key \
		 /mnt/persist128/etc/ssh/ssh_host_ed25519_key
	 ssh-keygen -y -f /mnt/persist128/etc/ssh/ssh_host_ed25519_key \
		 > /mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
	 chmod 644 /mnt/persist128/etc/ssh/ssh_host_ed25519_key.pub
	 ```

	 On a new host, create that key on the Mac before the installation:

	 ```bash
	 mkdir -p ~/.local/share/nix-lab/viktoria
	 ssh-keygen -t ed25519 -N '' \
		 -f ~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key \
		 -C viktoria
	 nix run nixpkgs#ssh-to-age -- < \
		 ~/.local/share/nix-lab/viktoria/ssh_host_ed25519_key.pub
	 ```

	Add the printed Age recipient to `.sops.yaml`, then use the Mac recovery
	identity to update the encrypted file:

	```bash
	export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
	nix shell nixpkgs#sops --command sops updatekeys secrets/secrets.yaml
	```

	Commit and push the encrypted file and policy before starting at step 1.

5. Install using the cloned checkout. The persisted host key is available on
	 first boot, letting `sops-nix` decrypt `secrets/secrets.yaml`:

	 ```bash
	 nixos-install --root /mnt --flake /tmp/nix-lab#viktoria --no-root-passwd
	 reboot
	 ```

6. After reboot, remove the installer USB and verify both the host key and
	 secret activation:

	 ```bash
	 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
	 systemctl status sops-nix.service
	 ```

	 Log in from the Mac using the private key corresponding to the public
	 `behrn` key declared in `nixos/configuration.nix`.

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
