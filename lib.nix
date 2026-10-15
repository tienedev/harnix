{ lib, pkgs }:
let
  # Render a string as a YAML scalar. Plain text stays unquoted (so simple
  # values render as before); anything else — `: `, ` #`, quotes, newlines,
  # leading indicators, YAML 1.1 booleans/null — becomes a JSON string
  # literal, which is a valid YAML double-quoted scalar.
  yamlStr = s:
    let
      plain    = builtins.match "[A-Za-z_][A-Za-z0-9 _.,/()+'-]*" s != null
              && !(lib.hasSuffix " " s);
      reserved = lib.elem (lib.toLower s) [ "true" "false" "yes" "no" "on" "off" "y" "n" "null" ];
    in
    if plain && !reserved then s else builtins.toJSON s;

  # Secret file → JSON path specs for one MCP server. `prefix` is the path of
  # the server object inside the rendered document.
  mcpServerSecrets = prefix: name: server:
    lib.mapAttrsToList (key: file: { path = prefix ++ [ name "headers" key ]; inherit file; }) server.secretHeaders
    ++ lib.mapAttrsToList (key: file: { path = prefix ++ [ name "env" key ]; inherit file; }) server.secretEnv;

  # Shellchecked by the flake checks rather than at build time, so consumers
  # do not pull shellcheck into their closure.
  jsonTool = pkgs.writeShellScript "harnix-json" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.jq ]}:$PATH
    ${builtins.readFile ./scripts/harnix-json.sh}
  '';

  mkJsonSpecValue = { name, target, content, merge ? "replace", secrets ? [], prune ? null
                    , ifDirExists ? null, ifTargetExists ? false, gitExclude ? null, skipStoreLink ? false }:
    assert lib.elem merge [ "replace" "top" "deep" ];
    { inherit name target content merge secrets prune ifDirExists ifTargetExists gitExclude skipStoreLink; };

  mkJsonSpec = args:
    pkgs.writeText "harnix-${args.name}.json" (builtins.toJSON (mkJsonSpecValue args));

  self = {
    inherit yamlStr;

    mkPluginDrv = { src, subpath, name }:
      pkgs.runCommand "harnix-plugin-${name}" {} (
        if subpath == "" || subpath == "."
        then "cp -r ${src} $out"
        else "cp -r ${src}/${subpath} $out"
      );

    mkSkillsDrv = { src, subpath, name }:
      pkgs.runCommand "harnix-skills-${name}" {} (
        let
          skillsPath = if subpath == "" || subpath == "." then "${src}/skills" else "${src}/${subpath}/skills";
        in ''
          if [ -d "${skillsPath}" ]; then
            cp -r "${skillsPath}" $out
          else
            mkdir $out
          fi
        ''
      );

    # User-level settings every declared plugin needs to load: user-scope
    # plugins enabled (overrides win), and the marketplace of every declared
    # plugin registered. Claude Code skips plugins missing either.
    pluginSettings = { pluginsCfg, registry, enabledOverrides }:
      let
        entries = map (self.resolvePluginEntry { inherit pluginsCfg registry; }) (self.allPluginIds pluginsCfg);
        withSource = builtins.filter (e: (e.marketplaceSource or null) != null) entries;
      in {
        enabledPlugins = lib.genAttrs pluginsCfg.user (_: true) // enabledOverrides;
        extraKnownMarketplaces = lib.listToAttrs (map (e:
          lib.nameValuePair e.marketplace { source = e.marketplaceSource; }
        ) withSource);
      };

    # Every plugin id enabled in any scope, deduplicated.
    allPluginIds = pluginsCfg: lib.unique (
      pluginsCfg.user ++ lib.concatLists (lib.attrValues pluginsCfg.project)
    );

    # Resolve a 'name@marketplace' id: consumer registry entries win over the
    # built-in registry, and `sources` overrides only the src of either.
    resolvePluginEntry = { pluginsCfg, registry }: id:
      let
        override = pluginsCfg.sources.${id} or null;
        entry    = pluginsCfg.registry.${id}
          or (registry.claude-code.${id}
          or (throw "harnix: unknown plugin '${id}' — add it to registry.nix or ai.plugins.claude-code.registry.\"${id}\""));
      in
      if override != null then entry // { src = override; } else entry;

    mkClaudeCodeMcpEntry = _name: server:
      if server.type == "stdio" then
        { inherit (server) type command args; }
        // lib.optionalAttrs (server.env != {}) { inherit (server) env; }
      else
        { inherit (server) type url; }
        // lib.optionalAttrs (server.headers != {}) { inherit (server) headers; };

    # pi-mcp-adapter has no `type` field: a `command` means stdio, a `url` means
    # StreamableHTTP with SSE fallback.
    mkPiMcpEntry = _name: server:
      { lifecycle = "lazy"; }
      // (if server.type == "stdio" then
        { inherit (server) command args; }
        // lib.optionalAttrs (server.env != {}) { inherit (server) env; }
      else
        { inherit (server) url; }
        // lib.optionalAttrs (server.headers != {}) { inherit (server) headers; });

    # Secret specs for every server, for mkJsonInstaller. `prefix` is the path of
    # the servers attrset inside the document (e.g. [ "mcpServers" ]).
    mcpSecrets = prefix: servers:
      lib.concatLists (lib.mapAttrsToList (mcpServerSecrets prefix) servers);

    # The activation-time JSON installer; see scripts/harnix-json.sh for the
    # spec format and semantics.
    inherit jsonTool;

    # Command installing one JSON document as a regular, writable, mode-600
    # file, atomically. Run it from an activation entry via `run`.
    #
    #   target   — path relative to $HOME, or absolute.
    #   content  — Nix value rendered as the owned part of the document.
    #   merge    — "replace": the file is exactly `content`;
    #              "top":     existing top-level keys are kept, keys of `content`
    #                         replace theirs wholesale (e.g. ~/.claude.json);
    #              "deep":    recursive merge of `content` into the existing file.
    #   secrets  — [ { path = [ ... ]; file = "/abs/path"; } ]: each file is read
    #              at activation time and set at `path`, so secret values never
    #              enter the Nix store.
    #   prune    — path of an object whose keys harnix manages: keys it wrote
    #              before and no longer declares are removed.
    #   ifDirExists — absolute directory; when set and missing, do nothing.
    #   ifTargetExists — when true, a missing target is not created.
    #   gitExclude  — { repo; path; }: when the file is created inside a git
    #                 repository, add it to .git/info/exclude.
    #   skipStoreLink — when the target is a symlink into the Nix store (a
    #                 file another module renders), warn and leave it alone.
    mkJsonInstaller = args: "${jsonTool} install ${mkJsonSpec args}";

    # Command pruning, under `scope`, the targets of a previous activation that
    # are absent from `installers` (a list of mkJsonInstaller arguments).
    mkJsonGc = scope: installers:
      "${jsonTool} gc ${lib.escapeShellArg scope} ${
        pkgs.writeText "harnix-gc-${scope}.json" (builtins.toJSON (map mkJsonSpecValue installers))
      }";

    # Resolve which body path to use: per-tool override, else the shared body.
    resolveAgentBody = agent: toolCfg:
      if toolCfg.body != null then toolCfg.body else agent.body;

    # Render Pi frontmatter (YAML between --- fences).
    # Omits keys whose values are nulls / "all" / true (defaults that mean "no
    # restriction"), so generated files stay close to hand-written ones.
    mkPiAgentFrontmatter = name: agent:
      let
        pi = agent.pi;

        # Pi uses comma-separated values for tools/extensions, not YAML lists.
        renderList = xs: lib.concatStringsSep ", " xs;

        lines = lib.flatten [
          "description: ${yamlStr agent.description}"
          (lib.optional (pi.promptMode != "replace") "prompt_mode: ${pi.promptMode}")
          (lib.optional (pi.model != null)           "model: ${yamlStr pi.model}")
          (lib.optional (pi.thinking != null)        "thinking: ${pi.thinking}")
          (lib.optional (pi.maxTurns != null)        "max_turns: ${toString pi.maxTurns}")
          (
            if pi.tools == "all" then []
            else if pi.tools == "none" then [ "tools: none" ]
            else [ "tools: ${renderList pi.tools}" ]
          )
          (
            if pi.extensions == true then []
            else if pi.extensions == false then [ "extensions: false" ]
            else [ "extensions: ${renderList pi.extensions}" ]
          )
        ];
      in
      "---\n" + lib.concatStringsSep "\n" lines + "\n---\n";

    # Render Claude Code frontmatter. `name` is required by Claude Code; tools
    # is omitted when empty (= all tools allowed); model defaults to "inherit".
    mkClaudeCodeAgentFrontmatter = name: agent:
      let
        cc = agent.claudeCode;
        renderList = xs: lib.concatStringsSep ", " xs;
        lines = lib.flatten [
          "name: ${yamlStr name}"
          "description: ${yamlStr agent.description}"
          (lib.optional (cc.tools != []) "tools: ${renderList cc.tools}")
          "model: ${yamlStr cc.model}"
        ];
      in
      "---\n" + lib.concatStringsSep "\n" lines + "\n---\n";

    # Build a derivation producing a single agent markdown file (frontmatter +
    # body). Returns a path suitable for `home.file.<dest>.source = ...`.
    mkAgentFile = { name, frontmatter, bodyPath }:
      pkgs.runCommand "harnix-agent-${name}.md" {
        inherit frontmatter;
        passAsFile = [ "frontmatter" ];
      } ''
        cat "$frontmatterPath" > $out
        echo "" >> $out
        cat ${bodyPath} >> $out
      '';
  };
in
self
