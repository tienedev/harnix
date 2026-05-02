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
  };
}
