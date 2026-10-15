{
  description = "Declarative AI agent configuration for NixOS / home-manager";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager     = {
      url             = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      systems      = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      homeModules.default = import ./modules/default.nix;
      # Legacy output name, kept for existing consumers.
      homeManagerModules.default = self.homeModules.default;

      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./checks { inherit pkgs; inherit (home-manager.lib) homeManagerConfiguration; harnixModule = self.homeModules.default; }
      );
    };
}
