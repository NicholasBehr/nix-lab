# This is just an example. Generate the real file on the target machine with
# `nixos-generate-config --no-filesystems --root /mnt` (filesystems and the
# bootloader are already managed by disko.nix/bootloader.nix) and replace this
# file, keeping only hardware-specific bits (kernel modules, cpu microcode, etc).
{
  # Set your system kind (needed for flakes).
  nixpkgs.hostPlatform = "x86_64-linux";
}
