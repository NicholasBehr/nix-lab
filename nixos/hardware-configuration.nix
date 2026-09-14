# This is just an example. Generate the real file on the target machine with
# nixos-generate-config and replace this file.
{
  boot.loader.systemd-boot.enable = true;

  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };

  # Set your system kind (needed for flakes).
  nixpkgs.hostPlatform = "x86_64-linux";
}
