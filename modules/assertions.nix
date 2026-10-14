{ config, lib, ... }:
let
  servers = config.ai.mcpServers;

  serverAssertions = name: s:
    let
      where   = "ai.mcpServers.${name}";
      remote  = s.type == "sse" || s.type == "http";
      overlap = lib.intersectLists (lib.attrNames s.headers) (lib.attrNames s.secretHeaders)
             ++ lib.intersectLists (lib.attrNames s.env) (lib.attrNames s.secretEnv);
    in [
      {
        assertion = remote -> s.url != null;
        message   = "${where}: type \"${s.type}\" requires `url`.";
      }
      {
        assertion = s.type == "stdio" -> s.command != null;
        message   = "${where}: type \"stdio\" requires `command`.";
      }
      {
        assertion = remote -> (s.command == null && s.args == [] && s.env == {} && s.secretEnv == {});
        message   = "${where}: command/args/env/secretEnv only apply to type \"stdio\".";
      }
      {
        assertion = s.type == "stdio" -> (s.url == null && s.headers == {} && s.secretHeaders == {});
        message   = "${where}: url/headers/secretHeaders only apply to types \"sse\" and \"http\".";
      }
      {
        assertion = overlap == [];
        message   = "${where}: ${lib.concatStringsSep ", " overlap} declared both as plain and secret value.";
      }
    ];
in
{
  assertions = lib.concatLists (lib.mapAttrsToList serverAssertions servers);
}
