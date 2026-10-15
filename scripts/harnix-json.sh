# harnix-json — install JSON documents described by a spec file, at
# home-manager activation time. Wrapped by lib.nix (jsonTool), which puts
# coreutils, grep and jq on PATH; shellchecked by the flake checks.
#
#   harnix-json install SPEC
#   harnix-json gc SCOPE SPECS
#
# Values (paths, names, secret locations) are only ever read from the spec as
# data, never interpolated into shell code.
#
# SPEC is a JSON object:
#   name            unique id; names the temp file and the prune state
#   target          path, absolute or relative to $HOME
#   content         the part of the document harnix owns
#   merge           "replace" | "top" (shallow) | "deep" (recursive)
#   secrets         [ { path: [...], file: "/abs" } ]: file content (trailing
#                   newline stripped) is set at `path`; a file that is not a
#                   readable regular file is skipped with a warning
#   ifDirExists     null, or a directory that must exist (else no-op)
#   ifTargetExists  when true, a missing target is not created
#   skipStoreLink   when true, a target linked into the Nix store is owned
#                   by another module: warn and leave it alone (instead of
#                   replacing it as a stale home-manager link)
#   gitExclude      null, or { repo, path }: when the target is created and
#                   repo/.git is a directory, /path is added to its
#                   info/exclude (as Claude Code does for local settings)
#   prune           null, or a path to an object whose keys harnix manages:
#                   keys written by a previous run and no longer in `content`
#                   are deleted (state kept under $XDG_STATE_HOME/harnix)
#
# gc runs `install` with empty content for every spec recorded under SCOPE by
# a previous run but absent from SPECS (a JSON array of specs), so entries of
# a target that left the configuration are pruned too, then records SPECS.

set -euo pipefail

stateDir="${XDG_STATE_HOME:-$HOME/.local/state}/harnix"

warn() {
  printf 'harnix: warning: %s\n' "$*" >&2
}

# Run jq with the remaining arguments and atomically replace $1 with its
# output, mode 600. On jq failure the destination is left untouched.
jq_atomic() {
  local dest="$1" tmp
  shift
  tmp="$(mktemp "$(dirname "$dest")/.harnix.XXXXXX")"
  if ! jq "$@" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

# Add the spec's gitExclude path to the repository's local exclude file.
git_exclude() {
  local repo path exclude
  repo="$(jq -r '.gitExclude.repo // empty' "$1")"
  path="$(jq -r '.gitExclude.path // empty' "$1")"
  if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
    return 0
  fi
  exclude="$repo/.git/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF "/$path" "$exclude" 2> /dev/null; then
    printf '/%s\n' "$path" >> "$exclude"
  fi
}

install_spec() {
  local spec="$1" name target merge ifDir real n i file
  name="$(jq -r '.name' "$spec")"
  merge="$(jq -r '.merge' "$spec")"
  ifDir="$(jq -r '.ifDirExists // empty' "$spec")"

  if [ -n "$ifDir" ] && [ ! -d "$ifDir" ]; then
    return 0
  fi

  target="$(jq -r '.target' "$spec")"
  case "$target" in
    /*) ;;
    *) target="$HOME/$target" ;;
  esac
  # A link into the store is a stale home-manager link: replace it. Any other
  # link (dotfile manager) is followed so the real file gets updated.
  if [ -L "$target" ]; then
    real="$(readlink -f "$target" || true)"
    case "$real" in
      /nix/store/*)
        if [ "$(jq -r '.skipStoreLink // false' "$spec")" = true ]; then
          warn "$target is managed by another Nix module; not updating it"
          return 0
        fi
        ;;
      "") ;;
      *) target="$real" ;;
    esac
  fi

  local created=false
  if [ ! -e "$target" ]; then
    if [ "$(jq -r '.ifTargetExists // false' "$spec")" = true ]; then
      return 0
    fi
    created=true
  fi
  mkdir -p "$(dirname "$target")"

  local -a jqArgs=(--slurpfile spec "$spec") input=(-n)
  local filter=''

  if [ "$merge" != replace ] && [ -s "$target" ]; then
    # Exactly one JSON value, and an object: anything else (corrupted file,
    # concatenated values) is left alone rather than risk losing user state.
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$target" > /dev/null 2>&1; then
      warn "$target is not a single JSON object; leaving it untouched"
      return 0
    fi
    input=("$target")
  fi

  local keysFile="$stateDir/keys/$name.json" prune
  prune="$(jq -c '.prune' "$spec")"
  if [ "$prune" != null ] && [ -f "$keysFile" ]; then
    jqArgs+=(--slurpfile old "$keysFile")
    # Drop every key written last time; the merge below writes back the ones
    # still declared, so only the undeclared ones disappear.
    filter+='(. // {}) | delpaths([$old[0][] as $k | $spec[0].prune + [$k]]) | '
  fi

  case "$merge" in
    replace) filter+='$spec[0].content' ;;
    top) filter+='(. // {}) + $spec[0].content' ;;
    deep) filter+='(. // {}) * $spec[0].content' ;;
    *)
      warn "$name: unknown merge mode $merge"
      return 1
      ;;
  esac

  n="$(jq '.secrets | length' "$spec")"
  for ((i = 0; i < n; i++)); do
    file="$(jq -r ".secrets[$i].file" "$spec")"
    if [ -f "$file" ] && [ -r "$file" ]; then
      jqArgs+=(--rawfile "secret$i" "$file")
      filter+=" | setpath(\$spec[0].secrets[$i].path; \$secret$i | rtrimstr(\"\\n\"))"
    else
      warn "secret file $file is not a readable file; $(jq -r ".secrets[$i].path | join(\".\")" "$spec") left unset"
    fi
  done

  jq_atomic "$target" "${jqArgs[@]}" "$filter" "${input[@]}"

  if [ "$created" = true ]; then
    git_exclude "$spec"
  fi

  if [ "$prune" != null ]; then
    mkdir -p "$stateDir/keys"
    jq_atomic "$keysFile" -c '.prune as $p | .content | getpath($p) // {} | keys' "$spec"
  fi
}

gc_scope() {
  local specs="$2" stateFile="$stateDir/scopes/$1.json" work old
  mkdir -p "$stateDir/scopes"
  if [ -f "$stateFile" ]; then
    work="$(mktemp -d)"
    # Specs that left the configuration, turned into prune-only runs: empty
    # content, deep merge, never create the target.
    jq -c --slurpfile cur "$specs" '
      ($cur[0] | map(.name)) as $names
      | .[] | select(.name as $n | $names | index($n) | not)
      | select(.prune != null)
      | .content = {} | .merge = "deep" | .ifTargetExists = true | .secrets = []
    ' "$stateFile" > "$work/stale"
    while IFS= read -r old; do
      printf '%s\n' "$old" > "$work/spec.json"
      install_spec "$work/spec.json"
      rm -f "$stateDir/keys/$(jq -r '.name' "$work/spec.json").json"
    done < "$work/stale"
    rm -rf "$work"
  fi
  jq_atomic "$stateFile" -c '.' "$specs"
}

case "${1:-}" in
  install) install_spec "$2" ;;
  gc) gc_scope "$2" "$3" ;;
  *)
    echo "usage: harnix-json install SPEC | gc SCOPE SPECS" >&2
    exit 2
    ;;
esac
