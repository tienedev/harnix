{ lib, ... }:
let
  mcpServerModule = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type    = lib.types.enum [ "sse" "http" "stdio" ];
        default = "sse";
        description = "MCP transport type.";
      };
      url = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Endpoint URL (sse and http only).";
      };
      command = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Executable (stdio only).";
      };
      args = lib.mkOption {
        type    = lib.types.listOf lib.types.str;
        default = [];
        description = "Arguments (stdio only).";
      };
      headers = lib.mkOption {
        type    = lib.types.attrsOf lib.types.str;
        default = {};
        description = "HTTP headers (http only, e.g. Authorization).";
      };
    };
  };

  agentPiModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render this agent for Pi.";
      };
      promptMode = lib.mkOption {
        type = lib.types.enum [ "replace" "append" ];
        default = "replace";
        description = "Pi prompt_mode frontmatter field.";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pi model — \"inherit\", a fuzzy name, or provider/id. null omits the field.";
      };
      thinking = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "off" "minimal" "low" "medium" "high" "xhigh" ]);
        default = null;
        description = "Pi thinking level. null omits the field.";
      };
      maxTurns = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pi max_turns. null omits the field (unlimited).";
      };
      tools = lib.mkOption {
        type = lib.types.either (lib.types.enum [ "all" "none" ]) (lib.types.listOf lib.types.str);
        default = "all";
        description = "Pi tools: \"all\" omits the field, \"none\" disables built-ins, list = explicit allowlist.";
      };
      extensions = lib.mkOption {
        type = lib.types.either lib.types.bool (lib.types.listOf lib.types.str);
        default = true;
        description = "Pi extensions: true omits, false disables, list = explicit MCP server names.";
      };
      body = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional Pi-specific body override. Falls back to ai.agents.<name>.body.";
      };
    };
  };

  agentClaudeCodeModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render this agent for Claude Code.";
      };
      model = lib.mkOption {
        type = lib.types.str;
        default = "inherit";
        description = "Claude Code model — \"haiku\", \"sonnet\", \"opus\", or \"inherit\".";
      };
      tools = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Claude Code tools allowlist. Empty list omits the field (all tools allowed).";
      };
      body = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional Claude Code-specific body override. Falls back to ai.agents.<name>.body.";
      };
    };
  };

  agentModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Agent description (rendered into both Pi and Claude Code frontmatter).";
      };
      body = lib.mkOption {
        type = lib.types.path;
        description = "Path to the markdown body (no frontmatter). Used as default for Pi and Claude Code unless overridden.";
      };
      pi = lib.mkOption {
        type = agentPiModule;
        default = {};
        description = "Pi-specific options.";
      };
      claudeCode = lib.mkOption {
        type = agentClaudeCodeModule;
        default = {};
        description = "Claude Code-specific options.";
      };
    };
  };

  mcpJsonScopeModule = lib.types.submodule {
    options = {
      enableAllProjectMcpServers = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, every .mcp.json file found in a project root is auto-trusted
          and its declared MCP servers spawn without prompt. This is the supply-chain
          vector documented as CVE-2026-21852: cloning a hostile repository into a
          managed workspace yields immediate code execution. Keep false unless you
          fully control every repo you open.
        '';
      };
      enabledMcpjsonServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Allowlist of MCP server names from project .mcp.json that may load.";
      };
      disabledMcpjsonServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Denylist of MCP server names from project .mcp.json that must never load.";
      };
    };
  };

  claudeCodeSettingsModule = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption ''
        Render ~/.claude/settings.json declaratively. The file becomes a symlink
        into the Nix store and any manual edit is overwritten on the next switch.
      '';

      permissions = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {
          defaultMode = "default";
          allow = [
            "Read" "Glob" "Grep"
            "WebFetch" "WebSearch"
            "Task" "Skill" "ExitPlanMode"
            "NotebookRead"
          ];
          ask = [
            "Bash"
            "Write" "Edit" "MultiEdit" "NotebookEdit"
            "mcp__*"
          ];
          deny = [
            "Read(~/.ssh/**)" "Read(~/.aws/**)" "Read(~/.gnupg/**)"
            "Read(~/.config/sops/**)"
            "Read(/run/secrets/**)"
            "Read(./**/.env)" "Read(./**/.env.*)"
            "Write(/etc/**)"  "Edit(/etc/**)"
            "Write(~/.ssh/**)" "Edit(~/.ssh/**)"
            "Write(~/.aws/**)" "Edit(~/.aws/**)"
            "Write(~/.gnupg/**)" "Edit(~/.gnupg/**)"
            "Bash(curl * | sh*)"  "Bash(curl * | bash*)"
            "Bash(wget * | sh*)"  "Bash(wget * | bash*)"
            "Bash(sudo rm -rf:*)" "Bash(rm -rf /:*)" "Bash(rm -rf ~:*)"
            "Bash(dd if=*of=/dev/*)" "Bash(mkfs:*)"
          ];
        };
        description = ''
          Top-level Claude Code permissions object. Defaults are deny-on-credentials,
          ask-on-mutation. Override the whole attrset (no shallow merge): if you
          customise this option you take responsibility for the deny list too.
        '';
      };

      mcpJsonScope = lib.mkOption {
        type = mcpJsonScopeModule;
        default = {};
        description = "Trust scope for .mcp.json files found inside project directories.";
      };

      hooks = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = ''
          Claude Code hooks (PreToolUse, PostToolUse, etc.). Free-form attrset
          rendered verbatim into settings.json. Hooks run with full user privileges;
          point only to derivations from your own Nix store.
        '';
      };

      enabledPlugins = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = {};
        description = ''
          Override which plugins are enabled. By default this is derived from
          ai.plugins.claude-code.user (every user-scope plugin is enabled).
          Set explicitly to disable a plugin without removing its installation.
        '';
      };

      extra = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = ''
          Free-form attributes merged at the top level of settings.json. Use this
          for fields harnix does not model directly (theme, statusLine, env, etc.).
          Unknown to Claude Code's schema = silently ignored, so verify upstream
          documentation.
        '';
      };
    };
  };
in
{
  options.ai = {
    mcpServers = lib.mkOption {
      type        = lib.types.attrsOf mcpServerModule;
      default     = {};
      description = "MCP servers declared once, rendered for every supported tool.";
    };

    plugins.claude-code = {
      user = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "User-scope plugins in 'name@marketplace' format.";
        example     = [ "superpowers@claude-plugins-official" ];
      };

      project = lib.mkOption {
        type        = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default     = {};
        description = "Project-scope plugins keyed by absolute project path.";
        example     = { "/home/titi/Projets/pentest" = [ "burpsuite-project-parser@trailofbits" ]; };
      };

      sources = lib.mkOption {
        type        = lib.types.attrsOf lib.types.package;
        default     = {};
        description = "Override registry pins. Key is 'name@marketplace', value is a derivation.";
      };
    };

    agents = lib.mkOption {
      type        = lib.types.attrsOf agentModule;
      default     = {};
      description = "User-level subagent definitions, rendered into ~/.pi/agent/agents/<name>.md and ~/.claude/agents/<name>.md.";
    };

    claudeCode.settings = lib.mkOption {
      type        = claudeCodeSettingsModule;
      default     = {};
      description = "Declarative ~/.claude/settings.json (permissions, hooks, MCP scope, plugins toggle).";
    };
  };
}
