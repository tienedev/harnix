{ pkgs, homeManagerConfiguration, harnixModule }:
let
  lib = pkgs.lib;
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

  piMcp = builtins.fromJSON basicConfig.config.home.file.".pi/agent/mcp.json".text;
in
{
  pi-mcp-generates-correctly = pkgs.runCommand "pi-mcp-test" {} ''
    ${pkgs.jq}/bin/jq -e '
      .mcpServers["titi-browser"].url == "http://titi-browser:9223/sse" and
      .mcpServers["titi-browser"].lifecycle == "lazy"
    ' ${pkgs.writeText "pi-mcp.json" (builtins.toJSON piMcp)} > /dev/null
    touch $out
  '';
}
