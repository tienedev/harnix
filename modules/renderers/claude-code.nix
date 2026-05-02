{ config, lib, pkgs, ... }:
let
  cfg      = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };
  registry  = import ../../registry.nix { inherit pkgs; };

  resolveEntry = id:
    let
      override = cfg.plugins.claude-code.sources.${id} or null;
      entry    = registry.claude-code.${id}
        or (throw "harnix: unknown plugin '${id}' — add it to registry.nix or set ai.plugins.claude-code.sources.\"${id}\"");
    in
    if override != null then entry // { src = override; } else entry;

  resolvedPlugins = lib.genAttrs
    (lib.unique (cfg.plugins.claude-code.user
      ++ lib.concatLists (lib.attrValues cfg.plugins.claude-code.project)))
    (id:
      let e = resolveEntry id;
      in e // { drv = harnixLib.mkPluginDrv { inherit (e) src subpath; name = "${e.marketplace}-${e.plugin}"; }; }
    );

  claudeJson = builtins.toJSON {
    mcpServers = lib.mapAttrs harnixLib.mkClaudeCodeMcpEntry cfg.mcpServers;
  };

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

  installedPluginsJson = builtins.toJSON {
    version = 2;
    plugins =
      lib.listToAttrs (map (id: {
        name  = id;
        value = [ (mkEntry "user" id {}) ];
      }) cfg.plugins.claude-code.user)
      // lib.foldl (acc: pair:
        let
          projectPath = pair.name;
          ids         = pair.value;
        in
        acc // lib.listToAttrs (map (id: {
          name  = id;
          value = [ (mkEntry "local" id { inherit projectPath; }) ];
        }) ids)
      ) {} (lib.mapAttrsToList (k: v: { name = k; value = v; }) cfg.plugins.claude-code.project);
  };

  pluginDirEntries = lib.listToAttrs (map (id:
    let p = resolvedPlugins.${id};
    in {
      name  = ".claude/plugins/cache/${p.marketplace}/${p.plugin}/${p.version}";
      value = { source = p.drv; };
    }
  ) (lib.attrNames resolvedPlugins));

  hasPlugins = cfg.plugins.claude-code.user != []
            || cfg.plugins.claude-code.project != {};
in
{
  home.file = lib.mkMerge [
    { ".claude.json".text = claudeJson; }

    (lib.mkIf hasPlugins (
      { ".claude/plugins/installed_plugins.json".text = installedPluginsJson; }
      // pluginDirEntries
    ))
  ];
}
