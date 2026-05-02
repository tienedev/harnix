{ config, lib, pkgs, ... }:
let
  cfg = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };
  piMcpServers = lib.mapAttrs harnixLib.mkPiMcpEntry cfg.mcpServers;
in
{
  home.file.".pi/agent/mcp.json".text = builtins.toJSON {
    mcpServers = piMcpServers;
  };
}
