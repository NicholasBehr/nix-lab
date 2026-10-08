{
  description = "Your new nix config";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Declarative disk partitioning/formatting
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Persistence declarations for impermanent root filesystems
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";

    # Encrypted secrets managed declaratively by NixOS.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    impermanence,
    sops-nix,
    ...
  } @ inputs: let
    # Supported systems for the formatter.
    systems = [
      "aarch64-linux"
      "i686-linux"
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    # This is a function that generates an attribute by calling a function you
    # pass to it, with each system as an argument
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    # Formatter for your nix files, available through 'nix fmt'
    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # The mover is compiled for the selected output platform. During deployment
    # the x86_64-linux host builds this output natively.
    packages = nixpkgs.lib.genAttrs ["aarch64-linux" "x86_64-linux"] (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      tier-mover = pkgs.callPackage ./pkgs/tier-mover {};
      maintenance-runner = pkgs.callPackage ./pkgs/maintenance-runner {};
    in {
      inherit tier-mover maintenance-runner;
      default = tier-mover;
    });

    checks.x86_64-linux.maintenance-vm = import ./tests/nixos/maintenance.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      maintenanceModule = self.nixosModules.maintenance;
    };

    # Reusable nixos modules you might want to export
    nixosModules = import ./modules/nixos;

    # NixOS configuration entrypoint
    # Available through 'nixos-rebuild --flake .#viktoria'
    nixosConfigurations = {
      viktoria = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          disko.nixosModules.disko
          impermanence.nixosModules.impermanence
          sops-nix.nixosModules.sops

          # > Our main NixOS configuration file <
          ./nixos/configuration.nix
        ];
      };
    };
  };
}
