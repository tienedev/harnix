{ config, lib, pkgs, ... }:
let
  cfg = config.ai;
  harnixLib = import ../../lib.nix { inherit lib pkgs; };

  # Installed by activation rather than home.file: secretHeaders / secretEnv
  # are injected at activation time and must not land in the Nix store.
  # harnix owns only the servers it declares: servers added with
  # `pi mcp add` (or by an extension) and other keys are kept.
  mcpJsonInstaller = harnixLib.mkJsonInstaller {
    name    = "pi-mcp";
    target  = ".pi/agent/mcp.json";
    merge   = "deep";
    prune   = [ "mcpServers" ];
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
