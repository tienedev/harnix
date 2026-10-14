{ pkgs }:
let
  # trailofbits/skills is a monorepo: one pinned checkout, one plugin per subdir.
  trailofbitsSrc = pkgs.fetchFromGitHub {
    owner  = "trailofbits";
    repo   = "skills";
    rev    = "d7f76b532d1e4c6e7757e04d25c99ab60dd5e32c";
    hash   = "sha256-eNMo3T1pX0mEVOjxQQwO65NRpSYmcSlUS2sLqo5h1Bo=";
  };
  trailofbits = plugin: version: {
    marketplace = "trailofbits";
    inherit plugin version;
    src       = trailofbitsSrc;
    subpath   = plugin;
    hasSkills = false;
  };
in
{
  claude-code = {
    # upstream: github.com/obra/superpowers — "claude-plugins-official" is the marketplace vendor name
    "superpowers@claude-plugins-official" = {
      marketplace = "claude-plugins-official";
      plugin      = "superpowers";
      version     = "6.0.3";
      src = pkgs.fetchFromGitHub {
        owner  = "obra";
        repo   = "superpowers";
        rev    = "896224c4b1879920ab573417e68fd51d2ccc9072"; # v6.0.3
        hash   = "sha256-+lT2a/qq0SF4k0PgnEDKiuidVlZX2p0vEso4d/5T1os=";
      };
      subpath   = "";
      hasSkills = true;
    };

    "obsidian@obsidian-skills" = {
      marketplace = "obsidian-skills";
      plugin      = "obsidian";
      version     = "1.0.1";
      src = pkgs.fetchFromGitHub {
        owner  = "kepano";
        repo   = "obsidian-skills";
        rev    = "bb9ec95e1b59c3471bd6fd77a78a4042430bfac3";
        hash   = "sha256-nLsv1cJl/4wnb1TBkz6OA/9tC9TM15Yx7Tquk0NbjHk=";
      };
      subpath   = "";
      hasSkills = true;
    };

    "burpsuite-project-parser@trailofbits" = trailofbits "burpsuite-project-parser" "1.0.0";
    "insecure-defaults@trailofbits"        = trailofbits "insecure-defaults"        "1.0.0";
    "firebase-apk-scanner@trailofbits"     = trailofbits "firebase-apk-scanner"     "2.1.0";
    "audit-context-building@trailofbits"   = trailofbits "audit-context-building"   "1.0.0";
  };
}
