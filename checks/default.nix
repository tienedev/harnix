{ pkgs, homeManagerConfiguration, harnixModule }:
let
  lib = pkgs.lib;
  jq  = "${pkgs.jq}/bin/jq";
  grep = "${pkgs.gnugrep}/bin/grep";

  mkHome = cfg: homeManagerConfiguration {
    inherit pkgs;
    modules = [
      harnixModule
      { home = { username = "test"; homeDirectory = "/home/test"; stateVersion = "24.05"; }; }
      cfg
    ];
  };

  # Secrets are read through inherited file descriptors: the path must be known
  # at eval time, and /dev/fd/N is the one path that exists both in the Linux
  # and Darwin sandboxes. fd 9 is never opened, to exercise a missing secret.
  basicConfig = mkHome {
    ai.mcpServers = {
      titi-browser = { type = "sse"; url = "http://titi-browser:9223/sse"; };
      local = {
        type      = "stdio";
        command   = "my-server";
        args      = [ "--flag" ];
        env       = { PLAIN = "1"; };
        secretEnv = { TOKEN = "/dev/fd/4"; };
      };
      api = {
        type          = "http";
        url           = "https://mcp.example.com";
        headers       = { X-Static = "s"; };
        secretHeaders = { Authorization = "/dev/fd/3"; X-Missing = "/dev/fd/9"; };
      };
    };
    ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ];
    ai.plugins.claude-code.project = {
      "/harnix-test/absent-project" = [ "insecure-defaults@trailofbits" ];
    };
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
    # YAML-hostile description: `: `, ` #`, quotes and a newline.
    ai.agents.tricky = {
      description = "Use when: the user asks # for \"quotes\"\nsecond line";
      body        = ./test-agent-body.md;
    };
    # Would parse as a boolean / start a YAML sequence if left unquoted.
    ai.agents.boolish = { description = "Yes"; body = ./test-agent-body.md; };
    ai.agents.dashed  = { description = "- starts like a list"; body = ./test-agent-body.md; };
  };

  settingsConfig = mkHome {
    ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ];
    ai.claudeCode.settings.enable = true;
    ai.claudeCode.settings.extra = {
      theme = "dark";
      env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = "80000";
    };
  };

  mutableSettingsConfig = mkHome {
    ai.claudeCode.settings.enable = true;
    ai.claudeCode.settings.mutable = true;
  };

  # Bash that runs the given activation entries of a configuration the way
  # home-manager does (its `run` helper just executes outside dry-run).
  activation = hm: names: ''
    run() { "$@"; }
    ${lib.concatMapStrings (n: hm.config.home.activation.${n}.data + "\n") names}
  '';

  # home-manager throws "Failed assertions" on any config access once an
  # assertion fails, so invalid fixtures are checked one failure at a time
  # against a valid twin (to tell the assertion apart from an unrelated error).
  evaluates = cfg: (builtins.tryEval (builtins.deepSeq (mkHome cfg).config.assertions true)).success;
  rejects = valid: invalid: evaluates valid && !(evaluates (lib.recursiveUpdate valid invalid));

  # Same, but project paths are fixed at eval time: every JSON spec passed to
  # the installer gets /harnix-test-project rewritten to $proj first.
  activationRelocated = hm: names: ''
    run() {
      local args=() a out
      for a in "$@"; do
        if [[ $a == *.json ]]; then
          out="$(mktemp "$TMPDIR/spec-XXXXXX.json")"
          sed "s|/harnix-test-project|$proj|g" "$a" > "$out"
          a="$out"
        fi
        args+=("$a")
      done
      "''${args[@]}"
    }
    ${lib.concatMapStrings (n: hm.config.home.activation.${n}.data + "\n") names}
  '';

  # Run a shell test with a fresh $HOME. Uses GNU coreutils for portable stat.
  runTest = name: script: pkgs.runCommand "harnix-${name}" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.gnugrep ];
  } ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${script}
    touch $out
  '';

  # A store path to point "stale home-manager links" at.
  storeTarget = pkgs.writeText "stale.json" "{}";
in
{
  # ---------------------------------------------------------------- ~/.claude.json

  claude-json-merges-mcp-servers-and-keeps-other-keys = runTest "claude-json-merge" ''
    echo '{"oauthAccount":{"email":"x"},"mcpServers":{"stale":{"type":"sse","url":"u"}}}' > "$HOME/.claude.json"
    printf 'Bearer s3cret\n' > auth; printf 'tok' > token
    ( ${activation basicConfig [ "claudeJsonMcpServers" ]} ) 3<auth 4<token 2>stderr

    f="$HOME/.claude.json"
    [ ! -L "$f" ]
    [ "$(stat -c %a "$f")" = 600 ]
    jq -e '
      .oauthAccount.email == "x"
      and (.mcpServers | keys) == ["api", "local", "titi-browser"]
      and .mcpServers["titi-browser"] == {type: "sse", url: "http://titi-browser:9223/sse"}
      and .mcpServers.local == {type: "stdio", command: "my-server", args: ["--flag"], env: {PLAIN: "1", TOKEN: "tok"}}
      and .mcpServers.api == {type: "http", url: "https://mcp.example.com", headers: {"X-Static": "s", Authorization: "Bearer s3cret"}}
    ' "$f" > /dev/null
    grep -q 'secret file /dev/fd/9 is not a readable file; mcpServers.api.headers.X-Missing left unset' stderr
  '';

  claude-json-created-when-absent = runTest "claude-json-absent" ''
    ( ${activation basicConfig [ "claudeJsonMcpServers" ]} ) 3</dev/null 4</dev/null 2>/dev/null
    jq -e '.mcpServers["titi-browser"].url == "http://titi-browser:9223/sse"' "$HOME/.claude.json" > /dev/null
  '';

  claude-json-malformed-left-untouched = runTest "claude-json-malformed" ''
    for bad in 'not json{' '1 {}' '[]'; do
      printf '%s' "$bad" > "$HOME/.claude.json"
      ( ${activation basicConfig [ "claudeJsonMcpServers" ]} ) 3</dev/null 4</dev/null 2>stderr
      [ "$(cat "$HOME/.claude.json")" = "$bad" ]
      grep -q 'is not a single JSON object; leaving it untouched' stderr
    done
  '';

  claude-json-follows-dotfile-symlink = runTest "claude-json-symlink" ''
    mkdir dotfiles
    echo '{"keep":true}' > dotfiles/claude.json
    ln -s "$PWD/dotfiles/claude.json" "$HOME/.claude.json"
    ( ${activation basicConfig [ "claudeJsonMcpServers" ]} ) 3</dev/null 4</dev/null 2>/dev/null
    [ -L "$HOME/.claude.json" ]
    jq -e '.keep and .mcpServers.local.command == "my-server"' dotfiles/claude.json > /dev/null
  '';

  # Shell metacharacters in names and secret paths are data, never code; a
  # secret path that is not a regular file is skipped, not fatal.
  claude-json-hostile-values-are-inert =
    let
      hm = mkHome {
        ai.mcpServers."we\"ird '$(name)" = {
          type          = "http";
          url           = "https://x";
          secretHeaders = {
            Injected   = "/nonexistent/$(echo PWNED >&2)`echo PWNED >&2`";
            Directory  = "/dev/fd";
          };
        };
      };
    in
    runTest "claude-json-hostile" ''
      ( ${activation hm [ "claudeJsonMcpServers" ]} ) 2>stderr
      ! grep -qx PWNED stderr
      grep -qF 'secret file /nonexistent/$(echo PWNED >&2)`echo PWNED >&2` is not a readable file' stderr
      grep -qF 'secret file /dev/fd is not a readable file' stderr
      jq -e --arg n ${lib.escapeShellArg "we\"ird '$(name)"} \
        '(.mcpServers | keys) == [$n] and .mcpServers[$n] == {type: "http", url: "https://x"}' \
        "$HOME/.claude.json" > /dev/null
    '';

  # ------------------------------------------------------------ ~/.pi/agent/mcp.json

  pi-mcp-renders-every-transport = runTest "pi-mcp" ''
    printf 'Bearer s3cret' > auth; printf 'tok\n' > token
    ( ${activation basicConfig [ "harnixPiMcpJson" ]} ) 3<auth 4<token 2>/dev/null
    f="$HOME/.pi/agent/mcp.json"
    [ "$(stat -c %a "$f")" = 600 ]
    jq -e '
      .mcpServers["titi-browser"] == {lifecycle: "lazy", url: "http://titi-browser:9223/sse"}
      and .mcpServers.local == {lifecycle: "lazy", command: "my-server", args: ["--flag"], env: {PLAIN: "1", TOKEN: "tok"}}
      and .mcpServers.api == {lifecycle: "lazy", url: "https://mcp.example.com", headers: {"X-Static": "s", Authorization: "Bearer s3cret"}}
      and ([.. | nulls] | length) == 0
    ' "$f" > /dev/null
  '';

  pi-mcp-replaces-stale-store-symlink = runTest "pi-mcp-stale-link" ''
    mkdir -p "$HOME/.pi/agent"
    ln -s ${storeTarget} "$HOME/.pi/agent/mcp.json"
    ( ${activation basicConfig [ "harnixPiMcpJson" ]} ) 3</dev/null 4</dev/null 2>/dev/null
    [ ! -L "$HOME/.pi/agent/mcp.json" ]
    jq -e '.mcpServers.local' "$HOME/.pi/agent/mcp.json" > /dev/null
  '';

  # ------------------------------------------------------------------ plugins

  installed-plugins-json-keeps-every-scope =
    let
      hm = mkHome {
        ai.plugins.claude-code.user = [ "insecure-defaults@trailofbits" ];
        ai.plugins.claude-code.project = {
          "/p/one" = [ "insecure-defaults@trailofbits" ];
          "/p/two" = [ "insecure-defaults@trailofbits" ];
        };
      };
    in
    runTest "installed-plugins" ''
      ${activation hm [ "harnixClaudePlugins" ]}
      f="$HOME/.claude/plugins/installed_plugins.json"
      [ ! -L "$f" ] && [ -w "$f" ]
      jq -e '
        .version == 2
        and (.plugins["insecure-defaults@trailofbits"] | map(.scope + ":" + (.projectPath // "")) | sort)
            == ["local:/p/one", "local:/p/two", "user:"]
      ' "$f" > /dev/null
    '';

  # Three successive switches: two plugins, then one, then the project leaves
  # the configuration. Hand-written keys and plugins must survive throughout.
  installed-plugins-json-prunes-undeclared-only =
    let
      two = mkHome { ai.plugins.claude-code.user = [ "insecure-defaults@trailofbits" "audit-context-building@trailofbits" ]; };
      one = mkHome { ai.plugins.claude-code.user = [ "insecure-defaults@trailofbits" ]; };
    in
    runTest "installed-plugins-prune" ''
      f="$HOME/.claude/plugins/installed_plugins.json"
      ${activation two [ "harnixClaudePlugins" ]}
      # A plugin installed by hand with /plugin install between two switches.
      jq '.plugins["manual@x"] = [{scope: "user"}]' "$f" > tmp && mv tmp "$f"
      ${activation one [ "harnixClaudePlugins" ]}
      jq -e '(.plugins | keys) == ["insecure-defaults@trailofbits", "manual@x"]' "$f" > /dev/null
    '';

  project-plugins-enabled-then-pruned =
    let
      withPlugins = ids: mkHome { ai.plugins.claude-code.project."/harnix-test-project" = ids; };
      both = withPlugins [ "insecure-defaults@trailofbits" "audit-context-building@trailofbits" ];
      one  = withPlugins [ "insecure-defaults@trailofbits" ];
      none = mkHome {};
    in
    runTest "project-enable" ''
      proj="$TMPDIR/project"
      f="$proj/.claude/settings.local.json"
      mkdir -p "$proj/.claude"
      echo '{"permissions":{"allow":["Bash"]},"enabledPlugins":{"mine@x":true}}' > "$f"

      ( ${activationRelocated both [ "harnixClaudePlugins" ]} )
      jq -e '
        .permissions.allow == ["Bash"]
        and .enabledPlugins == {"mine@x": true, "insecure-defaults@trailofbits": true, "audit-context-building@trailofbits": true}
      ' "$f" > /dev/null

      ( ${activationRelocated one [ "harnixClaudePlugins" ]} )
      jq -e '.enabledPlugins == {"mine@x": true, "insecure-defaults@trailofbits": true}' "$f" > /dev/null

      ( ${activationRelocated none [ "harnixClaudePlugins" ]} )
      jq -e '.permissions.allow == ["Bash"] and .enabledPlugins == {"mine@x": true}' "$f" > /dev/null
    '';

  # Created by harnix inside a git repository: excluded from git like Claude
  # Code does; an existing file is not touched in that respect.
  project-settings-local-created-is-git-excluded =
    let
      hm = mkHome { ai.plugins.claude-code.project."/harnix-test-project" = [ "insecure-defaults@trailofbits" ]; };
    in
    runTest "project-git-exclude" ''
      proj="$TMPDIR/project"
      mkdir -p "$proj/.git/info"
      echo '# existing' > "$proj/.git/info/exclude"
      ( ${activationRelocated hm [ "harnixClaudePlugins" ]} )
      ( ${activationRelocated hm [ "harnixClaudePlugins" ]} )
      # Deleted then recreated: the exclude line is not duplicated.
      rm "$proj/.claude/settings.local.json"
      ( ${activationRelocated hm [ "harnixClaudePlugins" ]} )
      jq -e '.enabledPlugins == {"insecure-defaults@trailofbits": true}' "$proj/.claude/settings.local.json" > /dev/null
      [ "$(cat "$proj/.git/info/exclude")" = "$(printf '# existing\n/.claude/settings.local.json')" ]

      other="$TMPDIR/other"
      mkdir -p "$other/.git/info" "$other/.claude"
      echo '{}' > "$other/.claude/settings.local.json"
      proj="$other"
      ( ${activationRelocated hm [ "harnixClaudePlugins" ]} )
      [ ! -e "$other/.git/info/exclude" ]
    '';

  # A relative project path only warns: no settings file is written, neither
  # relative to $HOME nor to the working directory.
  project-plugins-relative-path-not-written =
    let
      hm = mkHome { ai.plugins.claude-code.project."relative" = [ "insecure-defaults@trailofbits" ]; };
    in
    runTest "project-relative" ''
      mkdir -p "$HOME/relative" relative
      cd "$HOME"
      ${activation hm [ "harnixClaudePlugins" ]}
      [ ! -e "$HOME/relative/.claude" ]
      jq -e '.plugins["insecure-defaults@trailofbits"][0].projectPath == "relative"' \
        "$HOME/.claude/plugins/installed_plugins.json" > /dev/null
    '';

  project-plugins-skip-absent-project = runTest "project-absent" ''
    ${activation basicConfig [ "harnixClaudePlugins" ]}
    [ ! -e /harnix-test/absent-project ]
  '';

  plugin-dir-exists-in-home-file = pkgs.runCommand "plugin-dir-test" {} ''
    ls ${basicConfig.config.home.file.".claude/plugins/cache/claude-plugins-official/superpowers/6.0.3".source}
    touch $out
  '';

  skills-dir-created-for-plugin-with-skills = pkgs.runCommand "skills-dir-test" {} ''
    ls ${basicConfig.config.home.file.".agents/skills/superpowers".source}
    touch $out
  '';

  skills-duplicate-plugin-names-warn =
    let
      hm = mkHome {
        ai.plugins.claude-code.registry."superpowers@fork" = {
          marketplace = "fork";
          plugin      = "superpowers";
          version     = "0";
          src         = pkgs.emptyDirectory;
          hasSkills   = true;
        };
        ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" "superpowers@fork" ];
      };
    in
    assert lib.any (lib.hasInfix "named superpowers") hm.config.warnings;
    assert !(lib.any (lib.hasInfix "named superpowers") basicConfig.config.warnings);
    pkgs.runCommand "skills-duplicate-test" {} "touch $out";

  # ------------------------------------------------------------------- agents

  pi-agent-generates-correctly = pkgs.runCommand "pi-agent-test" {} ''
    AGENT=${basicConfig.config.home.file.".pi/agent/agents/test-agent.md".source}
    ${grep} -qx 'description: Fixture agent for harnix checks.' "$AGENT"
    ${grep} -qx 'thinking: low'       "$AGENT"
    ${grep} -qx 'max_turns: 30'       "$AGENT"
    ${grep} -qx 'tools: bash, read'   "$AGENT"
    ${grep} -qx 'extensions: false'   "$AGENT"
    ${grep} -q  'You are the test agent.' "$AGENT"
    # Pi frontmatter must NOT carry a 'name:' field (that's CC-only).
    if ${grep} -q '^name:' "$AGENT"; then
      echo "Pi agent should not have a 'name:' frontmatter key" >&2
      exit 1
    fi
    touch $out
  '';

  claude-code-agent-generates-correctly = pkgs.runCommand "cc-agent-test" {} ''
    AGENT=${basicConfig.config.home.file.".claude/agents/test-agent.md".source}
    ${grep} -qx 'name: test-agent' "$AGENT"
    ${grep} -qx 'description: Fixture agent for harnix checks.' "$AGENT"
    ${grep} -qx 'tools: Bash, Read' "$AGENT"
    ${grep} -qx 'model: sonnet'     "$AGENT"
    ${grep} -q  'You are the test agent.' "$AGENT"
    touch $out
  '';

  agent-frontmatter-is-valid-yaml =
    let
      files = tool: name: basicConfig.config.home.file."${tool}/${name}.md".source;
      cases = {
        tricky  = "Use when: the user asks # for \"quotes\"\nsecond line";
        boolish = "Yes";
        dashed  = "- starts like a list";
        test-agent = "Fixture agent for harnix checks.";
      };
    in
    pkgs.runCommand "agent-yaml-test" {
      nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
    } ''
      ${lib.concatStrings (lib.mapAttrsToList (name: want:
        lib.concatMapStrings (tool: ''
          python3 - ${files tool name} ${lib.escapeShellArg want} <<'EOF'
      import sys, yaml
      text = open(sys.argv[1]).read()
      fm = yaml.safe_load(text.split("---")[1])
      assert fm["description"] == sys.argv[2], (fm, sys.argv[2])
      EOF
        '') [ ".pi/agent/agents" ".claude/agents" ]
      ) cases)}
      touch $out
    '';

  # ----------------------------------------------------------------- settings

  settings-json-has-secure-defaults = pkgs.runCommand "settings-secure-defaults" {} ''
    ${jq} -e '
      .enableAllProjectMcpServers == false
      and .permissions.defaultMode == "default"
      and (.permissions.allow | index("Bash")  | not)
      and (.permissions.allow | index("Write") | not)
      and (.permissions.allow | index("Edit")  | not)
      and (.permissions.allow | index("mcp__*") | not)
      and (.permissions.deny | any(. == "Read(~/.ssh/**)"))
      and (.permissions.deny | any(. == "Read(/run/secrets/**)"))
      and (.permissions.deny | any(. == "Edit(~/.ssh/**)"))
      and (.permissions.deny | all(startswith("Write(") | not))
      and (.permissions.ask  | any(. == "Bash"))
      and (.permissions.ask  | any(. == "mcp__*"))
    ' ${pkgs.writeText "settings.json" settingsConfig.config.home.file.".claude/settings.json".text} > /dev/null
    touch $out
  '';

  settings-json-derives-enabled-plugins = pkgs.runCommand "settings-enabled-plugins" {} ''
    ${jq} -e '
      .enabledPlugins["superpowers@claude-plugins-official"] == true
    ' ${pkgs.writeText "settings.json" settingsConfig.config.home.file.".claude/settings.json".text} > /dev/null
    touch $out
  '';

  settings-json-merges-extra = pkgs.runCommand "settings-merges-extra" {} ''
    ${jq} -e '
      .theme == "dark"
      and .env.CLAUDE_CODE_MAX_OUTPUT_TOKENS == "80000"
    ' ${pkgs.writeText "settings.json" settingsConfig.config.home.file.".claude/settings.json".text} > /dev/null
    touch $out
  '';

  settings-json-warns-when-extra-shadows-options =
    let
      hm = mkHome {
        ai.claudeCode.settings.enable = true;
        ai.claudeCode.settings.extra.permissions = {};
      };
    in
    assert lib.any (lib.hasInfix "extra overrides permissions") hm.config.warnings;
    assert !(lib.any (lib.hasInfix "extra overrides") settingsConfig.config.warnings);
    pkgs.runCommand "settings-shadow-warning-test" {} "touch $out";

  # Fresh machine: ~/.claude does not exist yet.
  settings-json-mutable-installs-writable-copy = runTest "settings-mutable" ''
    ${activation mutableSettingsConfig [ "claudeCodeSettings" ]}
    f="$HOME/.claude/settings.json"
    [ ! -L "$f" ] && [ -w "$f" ]
    [ "$(stat -c %a "$f")" = 600 ]
    jq -e '.permissions.defaultMode == "default"' "$f" > /dev/null
  '';

  settings-json-mutable-disables-home-file =
    assert !mutableSettingsConfig.config.home.file.".claude/settings.json".enable;
    pkgs.runCommand "settings-mutable-home-file-test" {} "touch $out";

  settings-json-immutable-by-default =
    assert settingsConfig.config.home.file.".claude/settings.json".enable;
    assert !(settingsConfig.config.home.activation ? claudeCodeSettings);
    pkgs.runCommand "settings-immutable-default-test" {} "touch $out";

  # ---------------------------------------------------------- per-tool toggles

  pi-disable-skips-pi-outputs =
    let
      hm = mkHome {
        ai.pi.enable = false;
        ai.agents.a = { description = "d"; body = ./test-agent-body.md; };
      };
    in
    assert !(hm.config.home.activation ? harnixPiMcpJson);
    assert !(hm.config.home.file ? ".pi/agent/agents/a.md");
    assert hm.config.home.file ? ".claude/agents/a.md";
    pkgs.runCommand "pi-disable-test" {} "touch $out";

  claude-code-disable-skips-claude-outputs =
    let
      hm = mkHome {
        ai.claudeCode.enable = false;
        ai.claudeCode.settings.enable = true;
        ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ];
        ai.agents.a = { description = "d"; body = ./test-agent-body.md; };
      };
      files = lib.attrNames (lib.filterAttrs (_: f: f.enable) hm.config.home.file);
    in
    assert !(hm.config.home.activation ? claudeJsonMcpServers);
    assert !(hm.config.home.activation ? harnixClaudePlugins);
    assert !(lib.any (lib.hasPrefix ".claude/") files);
    assert lib.elem ".pi/agent/agents/a.md" files;
    pkgs.runCommand "claude-code-disable-test" {} "touch $out";

  # --------------------------------------------------------------- validation

  # Inconsistent fields only warn, so configurations that evaluated before
  # keep evaluating; ambiguous use of the new secret options is rejected.
  mcp-server-options-are-validated =
    let
      http  = { ai.mcpServers.s = { type = "http"; url = "u"; }; };
      stdio = { ai.mcpServers.s = { type = "stdio"; command = "c"; }; };
      warns = cfg: needle: lib.any (lib.hasInfix needle) (mkHome cfg).config.warnings;
      clean = cfg: !(lib.any (lib.hasInfix "ai.mcpServers.s") (mkHome cfg).config.warnings);
      with' = base: extra: lib.recursiveUpdate base extra;
    in
    assert clean http && clean stdio;
    assert warns (with' http  { ai.mcpServers.s.url = null; })        "type \"http\" requires `url`";
    assert warns (with' stdio { ai.mcpServers.s.command = null; })    "type \"stdio\" requires `command`";
    assert warns (with' http  { ai.mcpServers.s.env.A = "1"; })       "only apply to type \"stdio\"";
    assert warns (with' http  { ai.mcpServers.s.secretEnv.A = "/s"; }) "only apply to type \"stdio\"";
    assert warns (with' stdio { ai.mcpServers.s.headers.A = "1"; })   "only apply to types \"sse\" and \"http\"";
    assert warns (with' stdio { ai.mcpServers.s.url = "u"; })         "only apply to types \"sse\" and \"http\"";
    assert rejects http { ai.mcpServers.s = { headers.A = "1"; secretHeaders.A = "/s"; }; };
    assert warns { ai.plugins.claude-code.project."relative" = [ "insecure-defaults@trailofbits" ]; }
                 "\"relative\" is not an absolute path";
    pkgs.runCommand "mcp-validation-test" {} "touch $out";

  # Values accepted before this release must still evaluate and render the same.
  backward-compatible-option-values =
    let
      hm = mkHome {
        ai.agents.a = {
          description = "d";
          body        = ./test-agent-body.md;
          pi = { tools = []; extensions = []; };
        };
      };
    in
    pkgs.runCommand "backward-compat-test" {} ''
      ${grep} -qx 'tools: ' ${hm.config.home.file.".pi/agent/agents/a.md".source}
      ${grep} -qx 'extensions: ' ${hm.config.home.file.".pi/agent/agents/a.md".source}
      touch $out
    '';

  activation-script-passes-shellcheck = pkgs.runCommand "harnix-json-shellcheck" {
    nativeBuildInputs = [ pkgs.shellcheck ];
  } ''
    # SC2016: jq filters are single-quoted on purpose.
    shellcheck --shell=bash --exclude=SC2016 ${../scripts/harnix-json.sh}
    touch $out
  '';
}
