{ lib, ... }:
let
  disks = import ./disks.nix;

  # For pure EFI mirroring, every mirror MUST use "nodev"
  mirroredBoots = map (bootMountpoint: {
    path = bootMountpoint;
    devices = [ "nodev" ];
  }) disks.bootMountpoints;
in
{
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = lib.mkForce "";
    mirroredBoots = mirroredBoots;
  };
}
