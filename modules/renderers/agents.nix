{ config, lib, pkgs, ... }:
let
  cfg       = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };

  agents = cfg.agents;

  # Per-agent file entries for Pi (~/.pi/agent/agents/<name>.md).
  piAgents = lib.filterAttrs (_n: a: a.pi.enable) agents;
  piEntries = lib.mapAttrs' (name: agent:
    lib.nameValuePair ".pi/agent/agents/${name}.md" {
      source = harnixLib.mkAgentFile {
        inherit name;
        frontmatter = harnixLib.mkPiAgentFrontmatter name agent;
        bodyPath    = harnixLib.resolveAgentBody agent agent.pi;
      };
    }
  ) piAgents;

  # Per-agent file entries for Claude Code (~/.claude/agents/<name>.md).
  ccAgents = lib.filterAttrs (_n: a: a.claudeCode.enable) agents;
  ccEntries = lib.mapAttrs' (name: agent:
    lib.nameValuePair ".claude/agents/${name}.md" {
      source = harnixLib.mkAgentFile {
        inherit name;
        frontmatter = harnixLib.mkClaudeCodeAgentFrontmatter name agent;
        bodyPath    = harnixLib.resolveAgentBody agent agent.claudeCode;
      };
    }
  ) ccAgents;
in
lib.mkIf (agents != {}) {
  home.file = piEntries // ccEntries;
}
