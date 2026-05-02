{ config, lib, pkgs, ... }:
let
  cfg       = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };
  registry  = import ../../registry.nix { inherit pkgs; };

  resolveEntry = id:
    let
      override = cfg.plugins.claude-code.sources.${id} or null;
      entry    = registry.claude-code.${id}
        or (throw "harnix: unknown plugin '${id}'");
    in
    if override != null then entry // { src = override; } else entry;

  allPluginIds = lib.unique (
    cfg.plugins.claude-code.user
    ++ lib.concatLists (lib.attrValues cfg.plugins.claude-code.project)
  );

  skillPlugins = builtins.filter (id: (resolveEntry id).hasSkills or false) allPluginIds;

  skillDirEntries = lib.listToAttrs (map (id:
    let e = resolveEntry id;
    in {
      name  = ".agents/skills/${e.plugin}";
      value = {
        source = harnixLib.mkSkillsDrv {
          inherit (e) src subpath;
          name = "${e.marketplace}-${e.plugin}";
        };
      };
    }
  ) skillPlugins);
in
lib.mkIf (skillPlugins != []) {
  home.file = skillDirEntries;
}
