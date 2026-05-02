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
}
