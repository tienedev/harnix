{ pkgs }:
{
  claude-code = {
    # upstream: github.com/obra/superpowers — "claude-plugins-official" is the marketplace vendor name
    "superpowers@claude-plugins-official" = {
      marketplace = "claude-plugins-official";
      plugin      = "superpowers";
      version     = "5.0.7";
      src = pkgs.fetchFromGitHub {
        owner  = "obra";
        repo   = "superpowers";
        rev    = "e4a2375cb705ca5800f0833528ce36a3faf9017a";
        hash   = "sha256-AeICtdAfWRp0oCgQqd8LdrEWWtKNqUNWdvn0CGL18fA=";
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
        hash   = "sha256-eYxbQ5OuOu0xltfM1Att/wOOPpPBVG8njP9lwtUvu5w=";
      };
      subpath   = "obsidian";
      hasSkills = true;
    };

    "burpsuite-project-parser@trailofbits" = {
      marketplace = "trailofbits";
      plugin      = "burpsuite-project-parser";
      version     = "1.0.0";
      src = pkgs.fetchFromGitHub {
        owner  = "trailofbits";
        repo   = "skills";
        rev    = "d7f76b532d1e4c6e7757e04d25c99ab60dd5e32c";
        hash   = "sha256-eNMo3T1pX0mEVOjxQQwO65NRpSYmcSlUS2sLqo5h1Bo=";
      };
      subpath   = "burpsuite-project-parser";
      hasSkills = false;
    };

    "insecure-defaults@trailofbits" = {
      marketplace = "trailofbits";
      plugin      = "insecure-defaults";
      version     = "1.0.0";
      src = pkgs.fetchFromGitHub {
        owner  = "trailofbits";
        repo   = "skills";
        rev    = "d7f76b532d1e4c6e7757e04d25c99ab60dd5e32c";
        hash   = "sha256-eNMo3T1pX0mEVOjxQQwO65NRpSYmcSlUS2sLqo5h1Bo=";
      };
      subpath   = "insecure-defaults";
      hasSkills = false;
    };

    "firebase-apk-scanner@trailofbits" = {
      marketplace = "trailofbits";
      plugin      = "firebase-apk-scanner";
      version     = "2.1.0";
      src = pkgs.fetchFromGitHub {
        owner  = "trailofbits";
        repo   = "skills";
        rev    = "d7f76b532d1e4c6e7757e04d25c99ab60dd5e32c";
        hash   = "sha256-eNMo3T1pX0mEVOjxQQwO65NRpSYmcSlUS2sLqo5h1Bo=";
      };
      subpath   = "firebase-apk-scanner";
      hasSkills = false;
    };

    "audit-context-building@trailofbits" = {
      marketplace = "trailofbits";
      plugin      = "audit-context-building";
      version     = "1.0.0";
      src = pkgs.fetchFromGitHub {
        owner  = "trailofbits";
        repo   = "skills";
        rev    = "d7f76b532d1e4c6e7757e04d25c99ab60dd5e32c";
        hash   = "sha256-eNMo3T1pX0mEVOjxQQwO65NRpSYmcSlUS2sLqo5h1Bo=";
      };
      subpath   = "audit-context-building";
      hasSkills = false;
    };
  };
}
