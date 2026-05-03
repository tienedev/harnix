{ ... }:
{
  imports = [
    ./options.nix
    ./renderers/pi.nix
    ./renderers/claude-code.nix
    ./renderers/skills.nix
    ./renderers/agents.nix
  ];
}
