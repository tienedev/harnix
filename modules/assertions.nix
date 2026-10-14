{ config, lib, ... }:
let
  servers = config.ai.mcpServers;

  # Inconsistent transport fields are warnings, not assertions: configurations
  # that evaluated before these checks existed must keep evaluating.
  serverWarnings = name: s:
    let
      where  = "ai.mcpServers.${name}";
      remote = s.type == "sse" || s.type == "http";
    in
    lib.optional (remote && s.url == null)
      "${where}: type \"${s.type}\" requires `url`; the server is rendered without one."
    ++ lib.optional (s.type == "stdio" && s.command == null)
      "${where}: type \"stdio\" requires `command`; the server is rendered without one."
    ++ lib.optional (remote && (s.command != null || s.args != [] || s.env != {} || s.secretEnv != {}))
      "${where}: command/args/env/secretEnv only apply to type \"stdio\" and are ignored (is `type` missing? it defaults to \"sse\")."
    ++ lib.optional (s.type == "stdio" && (s.url != null || s.headers != {} || s.secretHeaders != {}))
      "${where}: url/headers/secretHeaders only apply to types \"sse\" and \"http\" and are ignored.";

  # secretHeaders / secretEnv are new options, so rejecting ambiguous use of
  # them cannot break an existing configuration.
  serverAssertions = name: s:
    let
      overlap = lib.intersectLists (lib.attrNames s.headers) (lib.attrNames s.secretHeaders)
             ++ lib.intersectLists (lib.attrNames s.env) (lib.attrNames s.secretEnv);
    in {
      assertion = overlap == [];
      message   = "ai.mcpServers.${name}: ${lib.concatStringsSep ", " overlap} declared both as plain and secret value.";
    };
in
{
  warnings   = lib.concatLists (lib.mapAttrsToList serverWarnings servers);
  assertions = lib.mapAttrsToList serverAssertions servers;
}
