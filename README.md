# harnix

> Declarative AI agent configuration for NixOS / home-manager.

One Nix declaration drives all your AI tools. MCP servers, Claude Code plugins, and agent skills are pinned, reproducible, and reapplied on rebuild. CLI additions to the parts harnix owns don't persist — the config is the truth.

## Supported tools

- **Claude Code** — `~/.claude.json` (mcpServers key only), `~/.claude/plugins/` (plugins + installed_plugins.json), `~/.claude/agents/`, `~/.claude/settings.json` (opt-in)
- **Pi** — `~/.pi/agent/mcp.json`, `~/.pi/agent/agents/`
- **Both** — `~/.agents/skills/` (Agent Skills standard, discovered natively by Pi)

## Usage

```nix
# flake.nix
inputs.harnix.url = "github:tienedev/harnix";

# home.nix
{ inputs, config, ... }: {
  imports = [ inputs.harnix.homeModules.default ];  # homeManagerModules.default still works

  ai.mcpServers.titi-browser = {
    type = "sse";
    url  = "http://titi-browser:9223/sse";
  };

  ai.mcpServers.github = {
    type      = "stdio";
    command   = "github-mcp-server";
    args      = [ "stdio" ];
    secretEnv.GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.secrets.github-token.path;
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

Each tool can be switched off: `ai.pi.enable = false;` or `ai.claudeCode.enable = false;` (both default to `true`).

## MCP servers (`ai.mcpServers`)

| `type` | Required | Optional |
|---|---|---|
| `sse`, `http` | `url` | `headers`, `secretHeaders` |
| `stdio` | `command` | `args`, `env`, `secretEnv` |

Mixing fields across transports is rejected at evaluation time.

### Secrets

`headers` and `env` values are written into the Nix store, which is world-readable. For tokens, use `secretHeaders` / `secretEnv`: each value is the **absolute path, as a string,** of a file read at activation time (sops-nix, agenix, or a plain `chmod 600` file). The file holds the full value (e.g. `Bearer xyz` for an `Authorization` header); a trailing newline is stripped. A path that is not a readable regular file only prints a warning and leaves that header/variable out, so a secret that is not decrypted yet never blocks a switch. It is only picked up at the next activation, though: make sure secrets are decrypted first (system-level sops-nix/agenix secrets are), or switch again.

```nix
ai.mcpServers.my-api = {
  type = "http";
  url  = "https://mcp.example.com";
  secretHeaders.Authorization = "/run/secrets/my-api-auth";
};
```

Files that may carry secrets (`~/.claude.json`, `~/.pi/agent/mcp.json`) are written with mode `600`. If one of them is a symlink managed by a dotfiles tool, harnix writes through the link, so the decrypted values end up in that target: keep it out of version control.

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

`enabledPlugins` is derived from `ai.plugins.claude-code.user`. Project-scope plugins (`ai.plugins.claude-code.project`) are enabled in `<project>/.claude/settings.local.json` instead: harnix merges `enabledPlugins."<id>" = true` into that file and keeps everything else in it; entries it stops declaring, including for a project removed from the configuration, are removed again. Projects whose directory does not exist on the current host are skipped, so one config can list projects of several machines. `mcpJsonScope.enableAllProjectMcpServers` defaults to `false` (CVE-2026-21852 mitigation); use `enabledMcpjsonServers` to allowlist specific server names from project `.mcp.json` files.

The default `permissions` block bans reads of `~/.ssh`, `~/.aws`, `~/.gnupg`, `/run/secrets`, asks for `Bash`/`Write`/`Edit`/`mcp__*`, and allows the read-only tools (`Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Task`, `Skill`). Override the whole `permissions` attrset if you need a different policy — there is no shallow merge. Setting `permissions`, `hooks`, `enabledPlugins` or the MCP scope keys through `extra` prints a warning, since it silently replaces the dedicated option.

> The deny list is a speed bump, not a sandbox. `Read(~/.ssh/**)` does not stop `cat ~/.ssh/id_ed25519` through `Bash`, and `Bash(curl * | sh*)` is bypassed by `curl … | bash -` or `sh <(curl …)`. The real gate is `Bash` being in `ask`; if you move it to `allow`, add a `PreToolUse` hook for the patterns you care about.

By default the file is a read-only symlink into the Nix store, which makes Claude Code commands that write user settings at runtime (`/effort`, `/config`, plugin toggles) fail with `EROFS`. Set `mutable = true` to install the same rendered content as a writable copy instead: runtime commands work between switches, and each activation reinstalls the declared content (runtime edits are reset on rebuild — persist them in Nix).

> First switch tip: if `~/.claude/settings.json` exists as a regular file from a previous manual edit, home-manager will refuse to symlink over it. Move it aside (`mv ~/.claude/settings.json ~/.claude/settings.json.preharnix`) before the first activation, or set `home-manager.backupFileExtension`. With `mutable = true` this does not apply — the activation script overwrites whatever is there.

## ⚠️ Runtime state

What harnix owns, and how it is installed:

| Path | Ownership | Install |
|---|---|---|
| `~/.claude.json` | the `mcpServers` key only; auth and project state are kept | activation, merge |
| `~/.claude/plugins/installed_plugins.json` | records of declared plugins | activation, merge |
| `~/.claude/plugins/cache/<mp>/<plugin>/<version>` | declared versions | store symlink |
| `~/.claude/settings.json` (opt-in) | whole file | store symlink, or writable copy with `mutable` |
| `<project>/.claude/settings.local.json` | `enabledPlugins` entries harnix declares | activation, merge |
| `~/.pi/agent/mcp.json` | whole file | activation, writable copy |
| `~/.claude/agents/`, `~/.pi/agent/agents/`, `~/.agents/skills/` | declared entries | store symlinks |

Files installed by activation are regular, writable files, so Claude Code / Pi can write them at runtime (`/plugin install`, `/mcp`) without hitting a read-only store file. Every activation reapplies what harnix owns: CLI changes to those parts (`claude mcp add`, editing a declared plugin, …) are lost on the next rebuild, while the rest of each file is kept (a plugin installed by hand stays in `installed_plugins.json`). Entries harnix wrote and no longer declares are removed; the record of what it wrote lives in `$XDG_STATE_HOME/harnix` (default `~/.local/state/harnix`). To persist a change, declare it in your Nix config.

All writes are atomic (temp file + rename, mode `600`). A merged file that is not a single JSON object (e.g. a corrupted `~/.claude.json`) is left untouched with a warning rather than overwritten.

> Rolling back to a harnix version older than this layout: `installed_plugins.json` and `~/.pi/agent/mcp.json` used to be store symlinks, and home-manager refuses to replace the regular files that now sit there. Delete them first, or set `home-manager.backupFileExtension`.

## Registry

`registry.nix` maps `"name@marketplace"` identifiers to pinned `fetchFromGitHub` calls. These pins are not flake inputs: `nix flake update` does not touch them. To bump one, update `rev`, `version` and `hash` (e.g. with `nix-prefetch-github <owner> <repo> --rev <tag>`). Submit a PR to add or update entries, or declare your own with `ai.plugins.claude-code.registry` without editing harnix.

## Contributing

Run `nix flake check` before submitting (CI runs it on Linux and macOS). PRs welcome for new registry entries. Each entry needs: `marketplace`, `plugin`, `version`, `src` (fetchFromGitHub with exact `rev` + `hash`), `subpath`, `hasSkills`.
