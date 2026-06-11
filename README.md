# harnix

> Declarative AI agent configuration for NixOS / home-manager.

One Nix declaration drives all your AI tools. MCP servers, Claude Code plugins, and agent skills are pinned, reproducible, and overwritten on rebuild. CLI additions don't persist — the config is the truth.

## Supported tools

- **Claude Code** — `~/.claude.json` (mcpServers), `~/.claude/plugins/` (plugins + installed_plugins.json)
- **Pi** — `~/.pi/agent/mcp.json`
- **Both** — `~/.agents/skills/` (Agent Skills standard, discovered natively by Pi)

## Usage

```nix
# flake.nix
inputs.harnix.url = "github:tienedev/harnix";

# home.nix
{ inputs, ... }: {
  imports = [ inputs.harnix.homeManagerModules.default ];

  ai.mcpServers.titi-browser = {
    type = "sse";
    url  = "http://titi-browser:9223/sse";
  };

  ai.plugins.claude-code.user = [
    "superpowers@claude-plugins-official"
    "obsidian@obsidian-skills"
  ];

  # Project-scope plugins
  ai.plugins.claude-code.project."/home/titi/Projets/pentest" = [
    "burpsuite-project-parser@trailofbits"
  ];

  # Override a registry pin (fork or custom commit)
  ai.plugins.claude-code.sources."superpowers@claude-plugins-official" =
    pkgs.fetchFromGitHub {
      owner = "obra"; repo = "superpowers";
      rev = "my-commit"; hash = "sha256-...";
    };
}
```

## Agents (`ai.agents`)

Declare a subagent once, render it for both Pi (`~/.pi/agent/agents/<name>.md`) and Claude Code (`~/.claude/agents/<name>.md`). The body is a plain markdown file (no frontmatter) — harnix prepends the right frontmatter for each tool.

```nix
ai.agents.flake-updater = {
  description = "Update les inputs flake personnels (whitelist).";
  body        = ./agents/flake-updater.md;

  pi = {
    promptMode = "append";
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
```

Per-tool `enable = false` skips rendering for that tool. Per-tool `body = ./other.md` overrides the shared body when one tool needs a different prompt. Default values omit the corresponding frontmatter key (e.g. `pi.tools = "all"` and `pi.extensions = true` mean "no restriction" and emit nothing).

## Claude Code settings (`ai.claudeCode.settings`)

Render `~/.claude/settings.json` declaratively. The defaults are deny-on-credentials and ask-on-mutation — opt in by setting `enable = true`:

```nix
ai.claudeCode.settings = {
  enable = true;
  extra = {
    theme = "dark";
    statusLine = { type = "command"; command = "bash ~/.claude/statusline-command.sh"; };
    env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = "80000";
  };

  # Add a PreToolUse hook (drop a writeShellApplication path here)
  hooks.PreToolUse = [
    { matcher = "Bash"; hooks = [{ type = "command"; command = "${myValidator}/bin/my-validator"; }]; }
  ];
};
```

`enabledPlugins` is derived from `ai.plugins.claude-code.user`. `mcpJsonScope.enableAllProjectMcpServers` defaults to `false` (CVE-2026-21852 mitigation); use `enabledMcpjsonServers` to allowlist specific server names from project `.mcp.json` files.

The default `permissions` block bans reads of `~/.ssh`, `~/.aws`, `~/.gnupg`, `/run/secrets`, asks for `Bash`/`Write`/`Edit`/`mcp__*`, and allows the read-only tools (`Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Task`, `Skill`). Override the whole `permissions` attrset if you need a different policy — there is no shallow merge.

By default the file is a read-only symlink into the Nix store, which makes Claude Code commands that write user settings at runtime (`/effort`, `/config`, plugin toggles) fail with `EROFS`. Set `mutable = true` to install the same rendered content as a writable copy instead: runtime commands work between switches, and each activation reinstalls the declared content (runtime edits are reset on rebuild — persist them in Nix).

> First switch tip: if `~/.claude/settings.json` exists as a regular file from a previous manual edit, home-manager will refuse to symlink over it. Move it aside (`mv ~/.claude/settings.json ~/.claude/settings.json.preharnix`) before the first activation, or set `home-manager.backupFileExtension`. With `mutable = true` this does not apply — the activation script overwrites whatever is there.

## ⚠️ Runtime state

`~/.claude.json`, `~/.pi/agent/mcp.json`, and (when enabled) `~/.claude/settings.json` are **fully owned by harnix**. Any changes made via CLI (`claude mcp add`, etc.) are overwritten on the next rebuild. To persist a change, declare it in your Nix config. With `settings.mutable = true`, runtime writes to `settings.json` survive until the next rebuild instead of failing immediately, but the declarative content still wins at every switch.

## Registry

`registry.nix` maps `"name@marketplace"` identifiers to pinned `fetchFromGitHub` calls. Run `nix flake update` to bump all pins. Submit a PR to add or update entries.

## Contributing

PRs welcome for new registry entries. Each entry needs: `marketplace`, `plugin`, `version`, `src` (fetchFromGitHub with exact `rev` + `hash`), `subpath`, `hasSkills`.
