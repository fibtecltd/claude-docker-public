#!/usr/bin/env bash
# Move one plugin's pin in plugins.lock to the current head of its repo's
# default branch (the same commit for every plugin that shares that repo+SHA).
#
# Usage: scripts/build/bump-plugin.sh NAME [LOCK]
# Review the diff, then open a PR: CI validates the new pin.
set -euo pipefail

name="${1:?usage: bump-plugin.sh NAME [LOCK]}"
lock="${2:-$(dirname "$0")/../../plugins.lock}"

line="$(awk -v n="$name" '$1 == n' "$lock")"
[[ -n "$line" ]] || { echo "no plugin named '$name' in $lock" >&2; exit 1; }
read -r _ repo old _ <<< "$line"

new="$(git ls-remote "$repo" HEAD | cut -f1)"
[[ "$new" =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve HEAD of $repo" >&2; exit 1; }
[[ "$new" != "$old" ]] || { echo "$name is already at the head of $repo (${old:0:12})"; exit 0; }

# Move every entry that shares this repo and commit, so one repo never has two pins.
tmp="$(mktemp)"
awk -v repo="$repo" -v old="$old" -v new="$new" \
    '$2 == repo && $3 == old { sub(old, new) } { print }' "$lock" > "$tmp"
cat "$tmp" > "$lock"
rm -f "$tmp"
echo "$repo: ${old:0:12} -> ${new:0:12}"
