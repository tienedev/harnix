{ config, lib, pkgs, ... }:
let
  cfg = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };

  # Installed by activation rather than home.file: secretHeaders / secretEnv
  # are injected at activation time and must not land in the Nix store.
  mcpJsonInstaller = harnixLib.mkJsonInstaller {
    name    = "pi-mcp";
    target  = ".pi/agent/mcp.json";
    content.mcpServers = lib.mapAttrs harnixLib.mkPiMcpEntry cfg.mcpServers;
    secrets = harnixLib.mcpSecrets [ "mcpServers" ] cfg.mcpServers;
  };
in
lib.mkIf cfg.pi.enable {
  # After linkGeneration, so the previous generation's store symlink at this
  # path has already been cleaned up.
  home.activation.harnixPiMcpJson = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${mcpJsonInstaller}
  '';
}
