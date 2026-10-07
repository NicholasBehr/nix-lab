# This is your system's configuration file.
# Use this to configure your system environment (it replaces /etc/nixos/configuration.nix)
{
  inputs,
  config,
  pkgs,
  ...
}: {
  # You can import other shared NixOS modules here. Host-specific modules,
  # including hardware configuration, are imported by each host entrypoint.
  imports = [
    # Shared mount lifecycle for services with bulk data on /data.
    inputs.self.nixosModules.bulk-storage

    # Or modules from other flakes (such as nixos-hardware):
    # inputs.hardware.nixosModules.common-cpu-amd
    # inputs.hardware.nixosModules.common-ssd

    # You can also split up your configuration and import pieces of it here:
    # ./users.nix

    # Declarative disk partitioning/ZFS layout (disko); disk IDs live in ./disks.nix
    ./disko.nix
    # GRUB installed to mirrored EFI partitions
    ./bootloader.nix

    # Apply a standby timeout to the bulk HDDs declared in disks.nix
    ./spindown.nix

    # SnapRAID and mergerFS pools
    ./storage.nix

    # Persistent, size-bounded system and service logs
    ./logging.nix

    # User-facing applications and shared reverse-proxy configuration
    ../services

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
  users.mutableUsers = false;
  users.users = {
    behrn = {
      isNormalUser = true;
      hashedPasswordFile = config.sops.secrets.behrn-password-hash.path;
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
      # Require public keys; password and keyboard-interactive authentication
      # must both remain disabled to prevent password-based login.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";

      # This host only needs SSH for administration and deployment.
      DisableForwarding = true;
      X11Forwarding = false;
      PermitUserEnvironment = false;

      # Limit the account and time available for authentication attempts.
      AllowUsers = ["behrn"];
      LoginGraceTime = 30;
      MaxAuthTries = 3;
    };
  };

  # Required for booting a ZFS root pool.
  networking.hostId = "1bfa673a";
  time.timeZone = "Europe/Zurich";

  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    # Read the key before impermanence restores its /etc/ssh path.
    age.sshKeyPaths = ["/persist128/etc/ssh/ssh_host_ed25519_key"];
    secrets.behrn-password-hash.neededForUsers = true;
  };

  # Persistence
  boot.initrd.systemd = {
    enable = true;
    services.rollback-root = {
      description = "Roll back the ephemeral root dataset";
      requires = ["zfs-import-zpool.service"];
      after = ["zfs-import-zpool.service"];
      requiredBy = ["sysroot.mount"];
      before = ["sysroot.mount"];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Failure must prevent mounting root with state left from the last boot.
        ExecStart = "${config.boot.zfs.package}/sbin/zfs rollback -r zpool/root@blank";
      };
    };
  };

  environment.persistence = {
    "/persist16" = {
      hideMounts = true;
    };

    "/persist128" = {
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

    "/persist1024" = {
      hideMounts = true;
    };
  };

  fileSystems = {
    "/nix".neededForBoot = true;
    "/persist16".neededForBoot = true;
    "/persist128".neededForBoot = true;
    "/persist1024".neededForBoot = true;
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "26.05";
}
