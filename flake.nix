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

      # `nix run .#update-registry -- [--major] [ID...]`: bump registry.json
      # pins (see scripts/update-registry.sh). Run from the repository root.
      apps = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          update-registry = {
            type    = "app";
            program = pkgs.lib.getExe (pkgs.writeShellApplication {
              name          = "update-registry";
              runtimeInputs = [ pkgs.coreutils pkgs.gh pkgs.gnused pkgs.jq pkgs.nix ];
              text          = ''exec ${pkgs.bash}/bin/bash ${./scripts/update-registry.sh} "$@"'';
            });
          };
        });

      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./checks { inherit pkgs; inherit (home-manager.lib) homeManagerConfiguration; harnixModule = self.homeModules.default; }
      );
    };
}
