{ config, lib, pkgs, ... }:
let
  cfg       = config.ai.claudeCode.settings;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };
  registry  = import ../../registry.nix { inherit pkgs; };

  # Plugins from ai.plugins.claude-code.user are enabled by default. Per-key
  # override in cfg.enabledPlugins wins (set to false to disable an installed
  # plugin without removing the cache entry). Marketplaces of every declared
  # plugin are registered; entries in extra.extraKnownMarketplaces win.
  plugins = harnixLib.pluginSettings {
    pluginsCfg       = config.ai.plugins.claude-code;
    enabledOverrides = cfg.enabledPlugins;
    inherit registry;
  };
  marketplaces = plugins.extraKnownMarketplaces // (cfg.extra.extraKnownMarketplaces or {});

  base = {
    "$schema"   = "https://json.schemastore.org/claude-code-settings.json";
    permissions = cfg.permissions;
    hooks       = cfg.hooks;
    inherit (cfg.mcpJsonScope) enableAllProjectMcpServers enabledMcpjsonServers disabledMcpjsonServers;
  } // lib.optionalAttrs (plugins.enabledPlugins != {}) {
    inherit (plugins) enabledPlugins;
  };

  rendered = base // cfg.extra // lib.optionalAttrs (marketplaces != {}) {
    extraKnownMarketplaces = marketplaces;
  };

  # Keys of `extra` that silently replace a value harnix models directly.
  shadowedKeys = lib.intersectLists (lib.attrNames base) (lib.attrNames cfg.extra);

  mutableInstaller = harnixLib.mkJsonInstaller {
    name    = "claude-settings";
    target  = ".claude/settings.json";
    content = rendered;
  };
in
lib.mkIf (cfg.enable && config.ai.claudeCode.enable) {
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
      run ${mutableInstaller}
    ''
  );

  warnings =
    lib.optional cfg.mcpJsonScope.enableAllProjectMcpServers ''
      ai.claudeCode.settings.mcpJsonScope.enableAllProjectMcpServers is true.
      Any .mcp.json file in any project directory is now auto-trusted (CVE-2026-21852
      class supply-chain risk). Prefer enabledMcpjsonServers as a per-name allowlist.
    ''
    ++ lib.optional (shadowedKeys != []) ''
      ai.claudeCode.settings.extra overrides ${lib.concatStringsSep ", " shadowedKeys}, which
      harnix renders from dedicated options. Set those options instead of using extra.
    '';
}
