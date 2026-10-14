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
      local args=() a
      for a in "$@"; do
        if [[ $a == *.json ]]; then
          sed "s|/harnix-test-project|$proj|g" "$a" > "$TMPDIR/spec-$RANDOM.json"
          a="$(ls -t "$TMPDIR"/spec-*.json | head -1)"
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
    ( ${activation basicConfig [ "harnixClaudeCode" ]} ) 3<auth 4<token 2>stderr

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
    ( ${activation basicConfig [ "harnixClaudeCode" ]} ) 3</dev/null 4</dev/null 2>/dev/null
    jq -e '.mcpServers["titi-browser"].url == "http://titi-browser:9223/sse"' "$HOME/.claude.json" > /dev/null
  '';

  claude-json-malformed-left-untouched = runTest "claude-json-malformed" ''
    for bad in 'not json{' '1 {}' '[]'; do
      printf '%s' "$bad" > "$HOME/.claude.json"
      ( ${activation basicConfig [ "harnixClaudeCode" ]} ) 3</dev/null 4</dev/null 2>stderr
      [ "$(cat "$HOME/.claude.json")" = "$bad" ]
      grep -q 'is not a single JSON object; leaving it untouched' stderr
    done
  '';

  claude-json-follows-dotfile-symlink = runTest "claude-json-symlink" ''
    mkdir dotfiles
    echo '{"keep":true}' > dotfiles/claude.json
    ln -s "$PWD/dotfiles/claude.json" "$HOME/.claude.json"
    ( ${activation basicConfig [ "harnixClaudeCode" ]} ) 3</dev/null 4</dev/null 2>/dev/null
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
      ( ${activation hm [ "harnixClaudeCode" ]} ) 2>stderr
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
      ${activation hm [ "harnixClaudeCode" ]}
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
      ${activation two [ "harnixClaudeCode" ]}
      # A plugin installed by hand with /plugin install between two switches.
      jq '.plugins["manual@x"] = [{scope: "user"}]' "$f" > tmp && mv tmp "$f"
      ${activation one [ "harnixClaudeCode" ]}
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

      ( ${activationRelocated both [ "harnixClaudeCode" ]} )
      jq -e '
        .permissions.allow == ["Bash"]
        and .enabledPlugins == {"mine@x": true, "insecure-defaults@trailofbits": true, "audit-context-building@trailofbits": true}
      ' "$f" > /dev/null

      ( ${activationRelocated one [ "harnixClaudeCode" ]} )
      jq -e '.enabledPlugins == {"mine@x": true, "insecure-defaults@trailofbits": true}' "$f" > /dev/null

      ( ${activationRelocated none [ "harnixClaudeCode" ]} )
      jq -e '.permissions.allow == ["Bash"] and .enabledPlugins == {"mine@x": true}' "$f" > /dev/null
    '';

  project-plugins-skip-absent-project = runTest "project-absent" ''
    ( ${activation basicConfig [ "harnixClaudeCode" ]} ) 3</dev/null 4</dev/null 2>/dev/null
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

  skills-duplicate-plugin-names-rejected =
    let
      fork = {
        ai.plugins.claude-code.registry."superpowers@fork" = {
          marketplace = "fork";
          plugin      = "superpowers";
          version     = "0";
          src         = pkgs.emptyDirectory;
          hasSkills   = true;
        };
      };
    in
    assert rejects
      (lib.recursiveUpdate fork { ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" ]; })
      { ai.plugins.claude-code.user = [ "superpowers@claude-plugins-official" "superpowers@fork" ]; };
    pkgs.runCommand "skills-duplicate-test" {} "touch $out";

  # ------------------------------------------------------------------- agents

  pi-agent-generates-correctly = pkgs.runCommand "pi-agent-test" {} ''
    AGENT=${basicConfig.config.home.file.".pi/agent/agents/test-agent.md".source}
    ${grep} -qx 'description: "Fixture agent for harnix checks."' "$AGENT"
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
    ${grep} -qx 'name: "test-agent"' "$AGENT"
    ${grep} -qx 'description: "Fixture agent for harnix checks."' "$AGENT"
    ${grep} -qx 'tools: Bash, Read' "$AGENT"
    ${grep} -qx 'model: "sonnet"'   "$AGENT"
    ${grep} -q  'You are the test agent.' "$AGENT"
    touch $out
  '';

  agent-frontmatter-is-valid-yaml = pkgs.runCommand "agent-yaml-test" {
    nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
  } ''
    for f in ${basicConfig.config.home.file.".pi/agent/agents/tricky.md".source} \
             ${basicConfig.config.home.file.".claude/agents/tricky.md".source}; do
      python3 - "$f" <<'EOF'
    import sys, yaml
    text = open(sys.argv[1]).read()
    fm = yaml.safe_load(text.split("---")[1])
    want = 'Use when: the user asks # for "quotes"\nsecond line'
    assert fm["description"] == want, fm
    EOF
    done
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
    assert !(hm.config.home.activation ? harnixClaudeCode);
    assert !(lib.any (lib.hasPrefix ".claude/") files);
    assert lib.elem ".pi/agent/agents/a.md" files;
    pkgs.runCommand "claude-code-disable-test" {} "touch $out";

  # --------------------------------------------------------------- validation

  mcp-server-options-are-validated =
    let
      http  = { ai.mcpServers.s = { type = "http"; url = "u"; }; };
      stdio = { ai.mcpServers.s = { type = "stdio"; command = "c"; }; };
    in
    assert rejects http  { ai.mcpServers.s.url = null; };
    assert rejects stdio { ai.mcpServers.s.command = null; };
    assert rejects http  { ai.mcpServers.s.env.A = "1"; };
    assert rejects http  { ai.mcpServers.s.secretEnv.A = "/s"; };
    assert rejects stdio { ai.mcpServers.s.headers.A = "1"; };
    assert rejects stdio { ai.mcpServers.s.url = "u"; };
    assert rejects http  { ai.mcpServers.s = { headers.A = "1"; secretHeaders.A = "/s"; }; };
    assert rejects { ai.plugins.claude-code.project."/abs" = [ "insecure-defaults@trailofbits" ]; }
                   { ai.plugins.claude-code.project."relative" = [ "insecure-defaults@trailofbits" ]; };
    pkgs.runCommand "mcp-validation-test" {} "touch $out";
}
