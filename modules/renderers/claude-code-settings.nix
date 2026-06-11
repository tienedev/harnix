{ config, lib, pkgs, ... }:
let
  cfg = config.ai.claudeCode.settings;

  # Plugins from ai.plugins.claude-code.user are enabled by default. Per-key
  # override in cfg.enabledPlugins wins (set to false to disable an installed
  # plugin without removing the cache entry).
  derivedEnabledPlugins =
    lib.genAttrs config.ai.plugins.claude-code.user (_id: true) // cfg.enabledPlugins;

  base = {
    "$schema"   = "https://json.schemastore.org/claude-code-settings.json";
    permissions = cfg.permissions;
    hooks       = cfg.hooks;
    inherit (cfg.mcpJsonScope) enableAllProjectMcpServers enabledMcpjsonServers disabledMcpjsonServers;
  } // lib.optionalAttrs (derivedEnabledPlugins != {}) {
    enabledPlugins = derivedEnabledPlugins;
  };

  rendered = base // cfg.extra;
in
lib.mkIf cfg.enable {
  home.file.".claude/settings.json" = {
    text = builtins.toJSON rendered;
    enable = !cfg.mutable;
  };

  # Mutable mode: same rendered content, installed as a regular writable file
  # after linkGeneration (so the cleanup of the previous generation's symlink
  # cannot race with the install). Claude Code can then write the file at
  # runtime; the declared content is reapplied on every activation.
  home.activation.claudeCodeSettings = lib.mkIf cfg.mutable (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run install -m600 ${config.home.file.".claude/settings.json".source} "$HOME/.claude/settings.json"
    ''
  );

  warnings = lib.optional cfg.mcpJsonScope.enableAllProjectMcpServers ''
    ai.claudeCode.settings.mcpJsonScope.enableAllProjectMcpServers is true.
    Any .mcp.json file in any project directory is now auto-trusted (CVE-2026-21852
    class supply-chain risk). Prefer enabledMcpjsonServers as a per-name allowlist.
  '';
}
