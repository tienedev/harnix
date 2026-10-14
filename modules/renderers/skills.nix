{ config, lib, pkgs, ... }:
let
  pluginsCfg = config.ai.plugins.claude-code;
  harnixLib  = import ../../lib.nix { inherit lib pkgs; };
  registry   = import ../../registry.nix { inherit pkgs; };

  resolveEntry = harnixLib.resolvePluginEntry { inherit pluginsCfg registry; };

  skillPlugins = builtins.filter (e: e.hasSkills or false)
    (map resolveEntry (harnixLib.allPluginIds pluginsCfg));

  # Skills land in ~/.agents/skills/<plugin>/, so two marketplaces shipping a
  # plugin with the same name would silently shadow each other.
  duplicateNames = lib.attrNames (lib.filterAttrs (_: n: n > 1)
    (lib.foldl' (acc: e: acc // { ${e.plugin} = (acc.${e.plugin} or 0) + 1; }) {} skillPlugins));

  skillDirEntries = lib.listToAttrs (map (e: {
    name  = ".agents/skills/${e.plugin}";
    value = {
      source = harnixLib.mkSkillsDrv {
        inherit (e) src subpath;
        name = "${e.marketplace}-${e.plugin}";
      };
    };
  }) skillPlugins);
in
lib.mkIf (skillPlugins != []) {
  warnings = lib.optional (duplicateNames != [])
    "harnix: several enabled plugins with skills are named ${lib.concatStringsSep ", " duplicateNames}; they share ~/.agents/skills/<plugin> and only one of each is installed.";

  home.file = skillDirEntries;
}
