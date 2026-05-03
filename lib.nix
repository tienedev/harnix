{ lib, pkgs }:
{
  mkPluginDrv = { src, subpath, name }:
    pkgs.runCommand "harnix-plugin-${name}" {} (
      if subpath == "" || subpath == "."
      then "cp -r ${src} $out"
      else "cp -r ${src}/${subpath} $out"
    );

  mkSkillsDrv = { src, subpath, name }:
    pkgs.runCommand "harnix-skills-${name}" {} (
      let
        skillsPath = if subpath == "" || subpath == "." then "${src}/skills" else "${src}/${subpath}/skills";
      in ''
        if [ -d "${skillsPath}" ]; then
          cp -r "${skillsPath}" $out
        else
          mkdir $out
        fi
      ''
    );

  mkClaudeCodeMcpEntry = _name: server:
    if server.type == "stdio" then
      { inherit (server) type command args; }
    else if server.type == "http" then
      { inherit (server) type url; }
      // lib.optionalAttrs (server.headers != {}) { inherit (server) headers; }
    else  # sse
      { inherit (server) type url; };

  mkPiMcpEntry = _name: server: {
    url       = server.url;
    lifecycle = "lazy";
  };

  # Resolve which body path to use: per-tool override, else the shared body.
  resolveAgentBody = agent: toolCfg:
    if toolCfg.body != null then toolCfg.body else agent.body;

  # Render Pi frontmatter (YAML between --- fences).
  # Omits keys whose values are nulls / "all" / true (defaults that mean "no
  # restriction"), so generated files stay close to hand-written ones.
  mkPiAgentFrontmatter = name: agent:
    let
      pi = agent.pi;

      # Pi uses comma-separated values for tools/extensions, not YAML lists.
      renderList = xs: lib.concatStringsSep ", " xs;

      lines = lib.flatten [
        "description: ${agent.description}"
        (lib.optional (pi.promptMode != "replace") "prompt_mode: ${pi.promptMode}")
        (lib.optional (pi.model != null)           "model: ${pi.model}")
        (lib.optional (pi.thinking != null)        "thinking: ${pi.thinking}")
        (lib.optional (pi.maxTurns != null)        "max_turns: ${toString pi.maxTurns}")
        (
          if pi.tools == "all" then []
          else if pi.tools == "none" then [ "tools: none" ]
          else [ "tools: ${renderList pi.tools}" ]
        )
        (
          if pi.extensions == true then []
          else if pi.extensions == false then [ "extensions: false" ]
          else [ "extensions: ${renderList pi.extensions}" ]
        )
      ];
    in
    "---\n" + lib.concatStringsSep "\n" lines + "\n---\n";

  # Render Claude Code frontmatter. `name` is required by Claude Code; tools
  # is omitted when empty (= all tools allowed); model defaults to "inherit".
  mkClaudeCodeAgentFrontmatter = name: agent:
    let
      cc = agent.claudeCode;
      renderList = xs: lib.concatStringsSep ", " xs;
      lines = lib.flatten [
        "name: ${name}"
        "description: ${agent.description}"
        (lib.optional (cc.tools != []) "tools: ${renderList cc.tools}")
        "model: ${cc.model}"
      ];
    in
    "---\n" + lib.concatStringsSep "\n" lines + "\n---\n";

  # Build a derivation producing a single agent markdown file (frontmatter +
  # body). Returns a path suitable for `home.file.<dest>.source = ...`.
  mkAgentFile = { name, frontmatter, bodyPath }:
    pkgs.runCommand "harnix-agent-${name}.md" {
      inherit frontmatter;
      passAsFile = [ "frontmatter" ];
    } ''
      cat "$frontmatterPath" > $out
      echo "" >> $out
      cat ${bodyPath} >> $out
    '';
}
