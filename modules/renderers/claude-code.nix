{ config, lib, pkgs, ... }:
let
  cfg        = config.ai;
  pluginsCfg = cfg.plugins.claude-code;
  harnixLib  = import ../../lib.nix { inherit lib pkgs; };
  registry   = import ../../registry.nix { inherit pkgs; };

  resolveEntry = harnixLib.resolvePluginEntry { inherit pluginsCfg registry; };

  resolvedPlugins = lib.genAttrs (harnixLib.allPluginIds pluginsCfg) (id:
    let e = resolveEntry id;
    in e // { drv = harnixLib.mkPluginDrv { inherit (e) src subpath; name = "${e.marketplace}-${e.plugin}"; }; }
  );

  mkEntry = scope: id: extraAttrs:
    let p = resolvedPlugins.${id};
    in {
      inherit scope;
      installPath = "${config.home.homeDirectory}/.claude/plugins/cache/${p.marketplace}/${p.plugin}/${p.version}";
      version     = p.version;
      installedAt = "1970-01-01T00:00:00.000Z";
      lastUpdated = "1970-01-01T00:00:00.000Z";
      gitCommitSha = p.src.rev or "unknown";
    } // extraAttrs;

  # One installation record per (plugin, scope[, project]). A plugin enabled
  # both user-wide and in projects gets one record for each.
  installRecords =
    map (id: { inherit id; entry = mkEntry "user" id {}; }) pluginsCfg.user
    ++ lib.concatLists (lib.mapAttrsToList (projectPath: ids:
      map (id: { inherit id; entry = mkEntry "local" id { inherit projectPath; }; }) ids
    ) pluginsCfg.project);

  installedPlugins = {
    version = 2;
    plugins = lib.foldl' (acc: r:
      acc // { ${r.id} = (acc.${r.id} or []) ++ [ r.entry ]; }
    ) {} installRecords;
  };

  pluginDirEntries = lib.mapAttrs' (_id: p:
    lib.nameValuePair ".claude/plugins/cache/${p.marketplace}/${p.plugin}/${p.version}" { source = p.drv; }
  ) resolvedPlugins;

  hasPlugins = resolvedPlugins != {};

  # Claude Code rewrites installed_plugins.json itself (/plugin install,
  # updates), so it is a writable file: harnix owns the records of the plugins
  # it declares, removes those it stopped declaring, and keeps the others.
  installedPluginsInstaller = harnixLib.mkJsonInstaller {
    name    = "claude-installed-plugins";
    target  = ".claude/plugins/installed_plugins.json";
    merge   = "deep";
    prune   = [ "plugins" ];
    content = installedPlugins;
  };

  # Claude Code manages ~/.claude.json itself (auth, project state); harnix
  # owns only the mcpServers key and keeps every other key.
  claudeJsonInstaller = harnixLib.mkJsonInstaller {
    name    = "claude-json";
    target  = ".claude.json";
    merge   = "top";
    content.mcpServers = lib.mapAttrs harnixLib.mkClaudeCodeMcpEntry cfg.mcpServers;
    secrets = harnixLib.mcpSecrets [ "mcpServers" ] cfg.mcpServers;
  };

  # Local-scope plugins are only loaded when enabled in the project's
  # .claude/settings.local.json. Deep-merged so other keys and plugins the
  # user enabled by hand are kept; projects absent on this host are skipped.
  # Entries harnix stops declaring are pruned, including for projects removed
  # from the configuration altogether (gc).
  # Without harnix rendering settings.json, the user-level keys plugins need
  # are merged into the existing file instead: enabledPlugins and
  # extraKnownMarketplaces entries harnix declares (pruned when undeclared),
  # everything else kept. A settings.json linked from the store belongs to
  # another module and is left alone (warning).
  pluginSettings = harnixLib.pluginSettings {
    inherit pluginsCfg registry;
    enabledOverrides = cfg.claudeCode.settings.enabledPlugins;
  };
  userSettingsInstallers = lib.mapAttrsToList (key: value: harnixLib.mkJsonInstaller {
    name          = "claude-user-settings-${key}";
    target        = ".claude/settings.json";
    merge         = "deep";
    prune         = [ key ];
    content.${key} = value;
    # Only create the file when there is something to put in it.
    ifTargetExists = value == {};
    skipStoreLink  = true;
  }) { inherit (pluginSettings) enabledPlugins extraKnownMarketplaces; };

  projectSpecs = lib.mapAttrsToList (projectPath: ids: {
    name        = "claude-project-${builtins.hashString "sha256" projectPath}";
    target      = "${projectPath}/.claude/settings.local.json";
    merge       = "deep";
    prune       = [ "enabledPlugins" ];
    content.enabledPlugins = lib.genAttrs ids (_: true);
    ifDirExists = projectPath;
    # Claude Code gitignores this file when it creates it; do the same.
    gitExclude  = { repo = projectPath; path = ".claude/settings.local.json"; };
  }) (lib.filterAttrs (path: ids: ids != [] && lib.hasPrefix "/" path) pluginsCfg.project);

  relativeProjects = lib.filter (path: !lib.hasPrefix "/" path) (lib.attrNames pluginsCfg.project);
in
lib.mkIf cfg.claudeCode.enable {
  warnings = map (path:
    "ai.plugins.claude-code.project: \"${path}\" is not an absolute path; its plugins are not enabled in the project settings."
  ) relativeProjects;

  home.file = lib.mkIf hasPlugins pluginDirEntries;

  # Entry name kept from earlier releases so configurations ordering their
  # own activation scripts against it keep working.
  home.activation.claudeJsonMcpServers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${claudeJsonInstaller}
  '';

  # After linkGeneration: a previous generation may have installed
  # installed_plugins.json as a store symlink that must be cleaned up first.
  home.activation.harnixClaudePlugins = lib.hm.dag.entryAfter [ "linkGeneration" ] (''
    run ${installedPluginsInstaller}
    run ${harnixLib.mkJsonGc "claude-projects" projectSpecs}
  '' + lib.concatMapStrings (spec: ''
    run ${harnixLib.mkJsonInstaller spec}
  '') projectSpecs
  + lib.optionalString (!cfg.claudeCode.settings.enable) (lib.concatMapStrings (i: ''
    run ${i}
  '') userSettingsInstallers));
}
