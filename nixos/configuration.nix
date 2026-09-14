# This is your system's configuration file.
# Use this to configure your system environment (it replaces /etc/nixos/configuration.nix)
{
  inputs,
  lib,
  config,
  pkgs,
  ...
}: {
  # You can import other shared NixOS modules here. Host-specific modules,
  # including hardware configuration, are imported by each host entrypoint.
  imports = [
    # If you want to use modules your own flake exports (from modules/nixos):
    # inputs.self.nixosModules.example

    # Or modules from other flakes (such as nixos-hardware):
    # inputs.hardware.nixosModules.common-cpu-amd
    # inputs.hardware.nixosModules.common-ssd

    # You can also split up your configuration and import pieces of it here:
    # ./users.nix

    # Declarative disk partitioning/ZFS layout (disko); disk IDs live in ./disks.nix
    ./disko.nix
    # GRUB installed to mirrored EFI partitions
    ./bootloader.nix

    # Import your generated (nixos-generate-config) hardware configuration
    ./hardware-configuration.nix
  ];

  nixpkgs = {
    # Configure your nixpkgs instance
    config = {
      # Disable if you don't want unfree packages
      allowUnfree = true;
    };
  };

  nix = {
    settings = {
      # Enable flakes and new 'nix' command
      experimental-features = "nix-command flakes";
      # Opinionated: disable global registry
      flake-registry = "";
    };
    # Opinionated: disable channels
    channel.enable = false;
  };

  # FIXME: Add the rest of your current configuration

  # TODO: Configure your system-wide user settings (groups, etc), add more users as needed.
  users.users = {
    behrn = {
      isNormalUser = true;
      hashedPassword = "$y$j9T$87hUCCKozoNq59HPb4Nhp.$3HjAS8sqojmYB03OTFAYprGK6QlfnZDw/lGG.Q7zCu4";
      openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFiZnT6Yr2UhuX9cOgjWHAve+t0hJYIhz6Bby+dJsVf8"];
      extraGroups = ["wheel"];
    };
  };

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      # Opinionated: forbid root login through SSH.
      PermitRootLogin = "no";
      # Opinionated: use keys only.
      # Remove if you want to SSH using passwords
      PasswordAuthentication = false;
    };
  };

  # Required for booting a ZFS root pool.
  networking.hostId = "1bfa673a";

  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # Persistence
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r zpool/root@blank
  '';

  environment.persistence."/persist16" = {
    hideMounts = true;
  };

  environment.persistence."/persist128" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };

  environment.persistence."/persist1024" = {
    hideMounts = true;
  };

  fileSystems."/nix".neededForBoot = true;
  fileSystems."/persist16".neededForBoot = true;
  fileSystems."/persist128".neededForBoot = true;
  fileSystems."/persist1024".neededForBoot = true;

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "26.05";
}
