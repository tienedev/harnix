{ pkgs, homeManagerConfiguration, harnixModule }:
let
  lib = pkgs.lib;
  harnixLib = import ../lib.nix { inherit lib pkgs; };
  basicConfig = homeManagerConfiguration {
    inherit pkgs;
    modules = [
      harnixModule
      {
        home = { username = "test"; homeDirectory = "/home/test"; stateVersion = "24.05"; };
        ai.mcpServers.titi-browser = { type = "sse"; url = "http://titi-browser:9223/sse"; };
        ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ];
      }
    ];
  };

  piMcp             = builtins.fromJSON basicConfig.config.home.file.".pi/agent/mcp.json".text;
  claudeMcpRendered = lib.mapAttrs harnixLib.mkClaudeCodeMcpEntry basicConfig.config.ai.mcpServers;
  pluginsJ          = builtins.fromJSON basicConfig.config.home.file.".claude/plugins/installed_plugins.json".text;
in
{
  pi-mcp-generates-correctly = pkgs.runCommand "pi-mcp-test" {} ''
    ${pkgs.jq}/bin/jq -e '
      .mcpServers["titi-browser"].url == "http://titi-browser:9223/sse" and
      .mcpServers["titi-browser"].lifecycle == "lazy"
    ' ${pkgs.writeText "pi-mcp.json" (builtins.toJSON piMcp)} > /dev/null
    touch $out
  '';

  claude-json-generates-correctly = pkgs.runCommand "claude-json-test" {} ''
    ${pkgs.jq}/bin/jq -e '
      .["titi-browser"].type == "sse" and
      .["titi-browser"].url == "http://titi-browser:9223/sse"
    ' ${pkgs.writeText "claude-mcp.json" (builtins.toJSON claudeMcpRendered)} > /dev/null
    touch $out
  '';

  installed-plugins-json-generates-correctly = pkgs.runCommand "installed-plugins-test" {} ''
    ${pkgs.jq}/bin/jq -e '
      .version == 2 and
      (.plugins["superpowers@claude-plugins-official"] | length) == 1 and
      .plugins["superpowers@claude-plugins-official"][0].scope == "user"
    ' ${pkgs.writeText "installed_plugins.json" (builtins.toJSON pluginsJ)} > /dev/null
    touch $out
  '';

  plugin-dir-exists-in-home-file = pkgs.runCommand "plugin-dir-test" {} ''
    ls ${basicConfig.config.home.file.".claude/plugins/cache/claude-plugins-official/superpowers/5.0.7".source}
    touch $out
  '';

  skills-dir-created-for-plugin-with-skills = pkgs.runCommand "skills-dir-test" {} ''
    ls ${basicConfig.config.home.file.".agents/skills/superpowers".source}
    touch $out
  '';
}
