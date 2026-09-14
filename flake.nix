{
  description = "Your new nix config";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    # Declarative disk partitioning/formatting
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
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

    # Reusable nixos modules you might want to export
    nixosModules = import ./modules/nixos;

    # NixOS configuration entrypoint
    # Available through 'nixos-rebuild --flake .#viktoria'
    nixosConfigurations = {
      viktoria = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          disko.nixosModules.disko

          # > Our main NixOS configuration file <
          ./nixos/configuration.nix
        ];
      };
    };
  };
}
