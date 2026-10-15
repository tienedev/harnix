{ pkgs }:
let
  # Pins live in registry.json so scripts/update-registry.sh can bump them;
  # entries sharing a repo and rev evaluate to the same fetchFromGitHub.
  pins = builtins.fromJSON (builtins.readFile ./registry.json);
in
{
  claude-code = builtins.mapAttrs (_id: p: {
    inherit (p) marketplace plugin version subpath hasSkills marketplaceSource;
    src = pkgs.fetchFromGitHub { inherit (p) owner repo rev hash; };
  }) pins;
}
