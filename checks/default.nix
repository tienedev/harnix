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
        ai.agents.test-agent = {
          description = "Fixture agent for harnix checks.";
          body        = ./test-agent-body.md;
          pi = {
            thinking   = "low";
            maxTurns   = 30;
            tools      = [ "bash" "read" ];
            extensions = false;
          };
          claudeCode = {
            model = "sonnet";
            tools = [ "Bash" "Read" ];
          };
        };
      }
    ];
  };

  settingsConfig = homeManagerConfiguration {
    inherit pkgs;
    modules = [
      harnixModule
      {
        home = { username = "test"; homeDirectory = "/home/test"; stateVersion = "24.05"; };
        ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ];
        ai.claudeCode.settings.enable = true;
        ai.claudeCode.settings.extra = {
          theme = "dark";
          env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = "80000";
        };
      }
    ];
  };

  piMcp             = builtins.fromJSON basicConfig.config.home.file.".pi/agent/mcp.json".text;
  claudeMcpRendered = lib.mapAttrs harnixLib.mkClaudeCodeMcpEntry basicConfig.config.ai.mcpServers;
  pluginsJ          = builtins.fromJSON basicConfig.config.home.file.".claude/plugins/installed_plugins.json".text;
  settingsJson      = builtins.fromJSON settingsConfig.config.home.file.".claude/settings.json".text;
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

  pi-agent-generates-correctly = pkgs.runCommand "pi-agent-test" {} ''
    AGENT=${basicConfig.config.home.file.".pi/agent/agents/test-agent.md".source}
    ${pkgs.gnugrep}/bin/grep -qx 'description: Fixture agent for harnix checks.' "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'thinking: low'       "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'max_turns: 30'       "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'tools: bash, read'   "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'extensions: false'   "$AGENT"
    ${pkgs.gnugrep}/bin/grep -q  'You are the test agent.' "$AGENT"
    # Pi frontmatter must NOT carry a 'name:' field (that's CC-only).
    if ${pkgs.gnugrep}/bin/grep -q '^name:' "$AGENT"; then
      echo "Pi agent should not have a 'name:' frontmatter key" >&2
      exit 1
    fi
    touch $out
  '';

  claude-code-agent-generates-correctly = pkgs.runCommand "cc-agent-test" {} ''
    AGENT=${basicConfig.config.home.file.".claude/agents/test-agent.md".source}
    ${pkgs.gnugrep}/bin/grep -qx 'name: test-agent' "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'description: Fixture agent for harnix checks.' "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'tools: Bash, Read' "$AGENT"
    ${pkgs.gnugrep}/bin/grep -qx 'model: sonnet'     "$AGENT"
    ${pkgs.gnugrep}/bin/grep -q  'You are the test agent.' "$AGENT"
    touch $out
  '';

  settings-json-has-secure-defaults = pkgs.runCommand "settings-secure-defaults" {} ''
    ${pkgs.jq}/bin/jq -e '
      .enableAllProjectMcpServers == false
      and .permissions.defaultMode == "default"
      and (.permissions.allow | index("Bash")  | not)
      and (.permissions.allow | index("Write") | not)
      and (.permissions.allow | index("Edit")  | not)
      and (.permissions.allow | index("mcp__*") | not)
      and (.permissions.deny | any(. == "Read(~/.ssh/**)"))
      and (.permissions.deny | any(. == "Read(/run/secrets/**)"))
      and (.permissions.ask  | any(. == "Bash"))
      and (.permissions.ask  | any(. == "mcp__*"))
    ' ${pkgs.writeText "settings.json" (builtins.toJSON settingsJson)} > /dev/null
    touch $out
  '';

  settings-json-derives-enabled-plugins = pkgs.runCommand "settings-enabled-plugins" {} ''
    ${pkgs.jq}/bin/jq -e '
      .enabledPlugins["superpowers@claude-plugins-official"] == true
    ' ${pkgs.writeText "settings.json" (builtins.toJSON settingsJson)} > /dev/null
    touch $out
  '';

  settings-json-merges-extra = pkgs.runCommand "settings-merges-extra" {} ''
    ${pkgs.jq}/bin/jq -e '
      .theme == "dark"
      and .env.CLAUDE_CODE_MAX_OUTPUT_TOKENS == "80000"
    ' ${pkgs.writeText "settings.json" (builtins.toJSON settingsJson)} > /dev/null
    touch $out
  '';
}
