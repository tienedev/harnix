#!/usr/bin/env bash
# Bump registry.json pins to the latest commit of each upstream repository.
#
#   scripts/update-registry.sh [--major] [ID...]
#
# For every entry (or only the given 'name@marketplace' IDs), reads the
# upstream .claude-plugin/marketplace.json at the default branch's HEAD to
# find the plugin: its directory becomes `subpath`, its version `version`
# (falling back to the plugin's own plugin.json), and `hasSkills` tells
# whether that directory ships skills/. The hash is the one
# fetchFromGitHub expects (`nix flake prefetch` of the same tarball).
#
# A new major version is reported and skipped unless --major is given, so
# breaking upstream releases get their own, deliberate pull request.
#
# Requires: gh (authenticated), jq, nix. Prints one line per entry and a
# markdown summary of the changes on stdout's last lines (used as the PR body
# by the update workflow).

set -euo pipefail

registry=registry.json
if [ ! -f "$registry" ] || [ ! -f flake.nix ]; then
  echo "run from the harnix repository root (no ./$registry here)" >&2
  exit 2
fi
allowMajor=false
ids=()
for arg in "$@"; do
  case "$arg" in
    --major) allowMajor=true ;;
    -*)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
    *) ids+=("$arg") ;;
  esac
done
if [ ${#ids[@]} -eq 0 ]; then
  mapfile -t ids < <(jq -r 'keys[]' "$registry")
fi

# GitHub file content at a ref, or empty when the file does not exist.
gh_file() {
  gh api "repos/$1/contents/$2?ref=$3" --jq .content 2> /dev/null | base64 -d 2> /dev/null || true
}

major() {
  printf '%s' "${1#v}" | cut -d. -f1
}

declare -A headOf hashOf
summary=()
work="$(mktemp)"
trap 'rm -f "$work"' EXIT
cp "$registry" "$work"

for id in "${ids[@]}"; do
  entry="$(jq -c --arg id "$id" '.[$id] // empty' "$work")"
  if [ -z "$entry" ]; then
    echo "$id: not in $registry" >&2
    exit 1
  fi
  slug="$(jq -r '.owner + "/" + .repo' <<< "$entry")"
  plugin="$(jq -r .plugin <<< "$entry")"
  oldRev="$(jq -r .rev <<< "$entry")"
  oldVersion="$(jq -r .version <<< "$entry")"

  if [ -z "${headOf[$slug]:-}" ]; then
    headOf[$slug]="$(gh api "repos/$slug/commits/HEAD" --jq .sha)"
  fi
  rev="${headOf[$slug]}"
  if [ "$rev" = "$oldRev" ]; then
    echo "$id: up to date ($oldVersion)"
    continue
  fi

  listing="$(gh_file "$slug" .claude-plugin/marketplace.json "$rev" \
    | jq -c --arg p "$plugin" '.plugins[]? | select(.name == $p)')"
  if [ -z "$listing" ]; then
    echo "$id: plugin '$plugin' not listed in $slug's marketplace.json at ${rev:0:12}; skipped" >&2
    continue
  fi
  source="$(jq -r 'if (.source | type) == "string" then .source else "" end' <<< "$listing")"
  if [ -z "$source" ]; then
    echo "$id: plugin source is not a path in $slug; skipped" >&2
    continue
  fi
  # "./" → "", "./plugins/x/" → "plugins/x"
  subpath="$(sed -e 's|^\./||' -e 's|/*$||' <<< "$source")"

  version="$(jq -r '.version // empty' <<< "$listing")"
  if [ -z "$version" ]; then
    version="$(gh_file "$slug" "${subpath:+$subpath/}.claude-plugin/plugin.json" "$rev" | jq -r '.version // empty')"
  fi
  if [ -z "$version" ]; then
    echo "$id: no version for '$plugin' at ${rev:0:12}; skipped" >&2
    continue
  fi

  if [ "$(major "$version")" != "$(major "$oldVersion")" ] && [ "$allowMajor" != true ]; then
    echo "$id: new major version $oldVersion → $version; skipped (rerun with --major)" >&2
    continue
  fi

  hasSkills=false
  if gh api "repos/$slug/contents/${subpath:+$subpath/}skills?ref=$rev" --silent 2> /dev/null; then
    hasSkills=true
  fi

  if [ -z "${hashOf[$slug@$rev]:-}" ]; then
    hashOf[$slug@$rev]="$(nix flake prefetch --json "github:$slug/$rev" | jq -r .hash)"
  fi

  jq --arg id "$id" --arg rev "$rev" --arg hash "${hashOf[$slug@$rev]}" \
    --arg version "$version" --arg subpath "$subpath" --argjson hasSkills "$hasSkills" \
    '.[$id] += { rev: $rev, hash: $hash, version: $version, subpath: $subpath, hasSkills: $hasSkills }' \
    "$work" > "$work.new"
  mv "$work.new" "$work"

  echo "$id: $oldVersion → $version (${oldRev:0:12} → ${rev:0:12})"
  summary+=("| \`$id\` | $oldVersion | $version | [${rev:0:12}](https://github.com/$slug/compare/$oldRev...$rev) |")
done

cp "$work" "$registry"

if [ ${#summary[@]} -gt 0 ]; then
  printf '\n| plugin | from | to | upstream diff |\n|---|---|---|---|\n'
  printf '%s\n' "${summary[@]}"
fi
