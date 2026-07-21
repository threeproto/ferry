#!/usr/bin/env bash
#
# Bump the app version in lockstep across the three places that must agree, so
# the release tag, the release name (tauri-action's __VERSION__), and the
# version the built app reports never drift:
#
#   - src-tauri/tauri.conf.json  ("version")   <- source tauri-action reads
#   - src-tauri/Cargo.toml       (package version)
#   - src-tauri/Cargo.lock       (the "ferry" package entry)
#
# Usage:
#   scripts/bump-version.sh 0.2.0     # set an explicit version
#   scripts/bump-version.sh patch     # 0.1.6 -> 0.1.7
#   scripts/bump-version.sh minor     # 0.1.6 -> 0.2.0
#   scripts/bump-version.sh major     # 0.1.6 -> 1.0.0
#
# It only edits files; it does NOT commit, tag, or push. It prints the exact
# git commands to cut the release afterwards.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tauri_conf="$repo_root/src-tauri/tauri.conf.json"
cargo_toml="$repo_root/src-tauri/Cargo.toml"
cargo_lock="$repo_root/src-tauri/Cargo.lock"

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "expected one argument (a version or patch|minor|major); see header for usage"
[ -f "$tauri_conf" ] || die "not found: $tauri_conf (run this from the ferry repo)"
[ -f "$cargo_toml" ] || die "not found: $cargo_toml"

# Read the current version from tauri.conf.json (the source of truth).
current="$(perl -ne 'if (/"version"\s*:\s*"([^"]+)"/) { print $1; exit }' "$tauri_conf")"
[ -n "$current" ] || die "could not read current version from $tauri_conf"
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "current version '$current' is not X.Y.Z"

# Resolve the requested version.
case "$1" in
  major|minor|patch)
    IFS=. read -r maj min pat <<<"$current"
    case "$1" in
      major) maj=$((maj + 1)); min=0; pat=0 ;;
      minor) min=$((min + 1)); pat=0 ;;
      patch) pat=$((pat + 1)) ;;
    esac
    new="$maj.$min.$pat"
    ;;
  *)
    new="$1"
    [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$new' is not a valid X.Y.Z version"
    ;;
esac

[ "$new" != "$current" ] || die "version is already $new; nothing to do"

# --- edits (first-match-only, anchored so we never touch dependency versions) ---

# tauri.conf.json: the single top-level "version" key.
NEW="$new" perl -i -pe 'if (!$d && s/("version"\s*:\s*")[^"]*(")/$1.$ENV{NEW}.$2/e) { $d = 1 }' "$tauri_conf"

# Cargo.toml: the [package] version line (a line that *starts* with `version =`;
# dependency versions are `foo = { version = ... }`, never at column 0).
NEW="$new" perl -i -pe 'if (!$d && s/^version = "[^"]*"/version = "$ENV{NEW}"/) { $d = 1 }' "$cargo_toml"

# Cargo.lock: the [[package]] block whose name is "ferry". cargo writes the
# `version` line immediately after `name`, so anchor on that pair. Skipped
# gracefully if the lockfile hasn't been generated yet.
if [ -f "$cargo_lock" ]; then
  NEW="$new" perl -0777 -i -pe 's/(name = "ferry"\nversion = ")[^"]*(")/$1.$ENV{NEW}.$2/e' "$cargo_lock"
fi

echo "bumped $current -> $new"
echo "  $tauri_conf"
echo "  $cargo_toml"
[ -f "$cargo_lock" ] && echo "  $cargo_lock"
echo
echo "next: review, commit, then tag to match:"
echo "  git commit -am \"chore: bump version to $new\""
echo "  git tag v$new && git push origin v$new"
