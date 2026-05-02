# harnix — Design Spec

**Date:** 2026-05-02
**Status:** Approved

## Summary

`harnix` is a standalone Nix flake exposing a home-manager module for declarative AI agent configuration. One declaration drives all tools (Claude Code, Pi, and future harnesses). Rebuild always overrides runtime state — the Nix config is the single source of truth.

## Goals

- Declare MCP servers once → generated for every supported tool
- Declare skills once → deployed to `~/.agents/skills/` (Agent Skills standard, read natively by Pi and Claude Code)
- Declare Claude Code plugins → pinned via community registry, overridable per-machine
- 100% declarative ownership of all generated files (`home.file` / Nix store symlinks)
- Community-shareable: others add it as a flake input and get the registry for free

## Non-Goals (v1)

- Pi package management (conflicts with existing `settings.json` model config — v2)
- Hermes / Fluid / other harnesses (v2)
- Inline custom skills (all skills come from external pinned sources)

---

## Architecture

### Flake structure

```
harnix/
  flake.nix               # outputs: homeManagerModules.default
  modules/
    default.nix           # entry point, imports all sub-modules
    options.nix           # all ai.* option definitions
    renderers/
      claude-code.nix     # generates Claude Code files
      pi.nix              # generates Pi files
      skills.nix          # deploys ~/.agents/skills/
  registry.nix            # community-maintained pinned sources
  lib.nix                 # helpers (mkPlugin, mkSkillEntry…)
  README.md
  LICENSE
```

### Consumer usage

```nix
# flake.nix (consumer)
inputs.harnix.url = "github:tienedev/harnix";

# hosts/titi-gaming/home.nix
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
}
```

---

## Options API

```nix
ai = {
  # ── Transverse (all tools) ──────────────────────────────
  mcpServers.<name> = {
    type    = "sse";     # "sse" | "http" | "stdio"
    url     = "...";     # sse / http
    command = "...";     # stdio only
    args    = [ ... ];   # stdio only
    headers = { };       # http only (e.g. Authorization)
  };

  # ── Claude Code ─────────────────────────────────────────
  plugins.claude-code = {
    # User-scope: installed globally on the machine
    user = [ "name@marketplace" ... ];

    # Project-scope: installed for a specific project path
    project."<abs-path>" = [ "name@marketplace" ... ];

    # Override a registry pin (fork, custom commit, etc.)
    sources."name@marketplace" = pkgs.fetchFromGitHub { ... };
  };
};
```

---

## Generated files & ownership

| File | Tool | Mechanism | Owner |
|------|------|-----------|-------|
| `~/.claude.json` | Claude Code | `home.file` | **harnix** — runtime state reset on rebuild |
| `~/.claude/plugins/installed_plugins.json` | Claude Code | `home.file` | **harnix** |
| `~/.claude/plugins/cache/<mp>/<plugin>/<v>/` | Claude Code | Nix store symlinks | **harnix** |
| `~/.agents/skills/<name>/` | Pi + Claude Code | Nix store symlinks | **harnix** |
| `~/.pi/agent/mcp.json` | Pi | `home.file` | **harnix** |

All files are fully owned. CLI additions (e.g. `claude mcp add`) are overwritten on the next `nixos-rebuild switch` or `darwin-rebuild switch`. To persist a change, it must be declared in the Nix config.

---

## Registry

`registry.nix` maps `"name@marketplace"` → `{ src, subpath, version, hasSkills }`.

```nix
# registry.nix (excerpt)
{
  claude-code = {
    "superpowers@claude-plugins-official" = {
      marketplace = "claude-plugins-official";
      plugin      = "superpowers";
      version     = "5.0.7";
      src = pkgs.fetchFromGitHub {
        owner  = "anthropics";
        repo   = "claude-plugins-official";
        rev    = "e4a2375cb705ca5800f0833528ce36a3faf9017a";
        sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
      subpath   = "superpowers";
      hasSkills = true; # skills/ extracted to ~/.agents/skills/
    };

    "obsidian@obsidian-skills" = {
      marketplace = "obsidian-skills";
      plugin      = "obsidian";
      version     = "1.0.1";
      src = pkgs.fetchFromGitHub {
        owner  = "kepano";
        repo   = "obsidian-skills";
        rev    = "bb9ec95e1b59c3471bd6fd77a78a4042430bfac3";
        sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
      subpath   = "obsidian";
      hasSkills = true;
    };
  };
}
```

- Community maintains pins via PRs
- Consumer can override any entry via `ai.plugins.claude-code.sources.<id>`
- `nix flake update` bumps all non-overridden pins

---

## Renderers

### claude-code.nix

Generates:

1. **`~/.claude.json`** — `home.file`, fully owned:
   ```json
   { "mcpServers": { ... } }
   ```

2. **`~/.claude/plugins/installed_plugins.json`** — `home.file`, fully owned, lists all user-scope plugins with their Nix store `installPath`.

3. **Plugin dirs** — `home.file."claude/plugins/cache/<mp>/<plugin>/<v>".source = <derivation>` where the derivation is `pkgs.runCommand` extracting the `subpath` from `src`.

### pi.nix

Generates:

1. **`~/.pi/agent/mcp.json`** — `home.file`, fully owned:
   ```json
   { "mcpServers": { "<name>": { "url": "...", "lifecycle": "lazy" } } }
   ```

### skills.nix

For each installed plugin with `hasSkills = true`:
- Extracts `<src>/<subpath>/skills/` from the Nix store
- Symlinks each skill dir to `~/.agents/skills/<skill-name>/` via `home.file.<path>.source`

---

## Scope notes for v2

- Pi package management (`ai.packages.pi.*`) — requires decoupling model config from `settings.json`
- Additional harnesses: Hermes, Fluid, OpenCode, Codex
- Skills registry (community-curated standalone skill repos, not bundled in plugins)
- MCP server authentication secrets via SOPS integration
