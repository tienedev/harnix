{ ... }:
{
  imports = [
    ./options.nix
    ./renderers/pi.nix
    ./renderers/claude-code.nix
    ./renderers/claude-code-settings.nix
    ./renderers/skills.nix
    ./renderers/agents.nix
  ];
}
