#!/usr/bin/env bash
# Fetch the plugins listed in a lock file into DEST/<name>, each at its pinned
# commit and without git metadata.
#
# Used by the Dockerfile (as root, at build time) and runnable locally:
#   scripts/build/fetch-plugins.sh plugins.lock /tmp/plugins
#
# Usage: fetch-plugins.sh LOCK DEST
# Lock format: see plugins.lock. Needs git and jq.
set -euo pipefail

lock="${1:?usage: fetch-plugins.sh LOCK DEST}"
dest="${2:?usage: fetch-plugins.sh LOCK DEST}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

while read -r name repo sha path; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    [[ -n "${repo:-}" && -n "${sha:-}" && -n "${path:-}" ]] \
        || { echo "bad lock line for '$name': need NAME REPO SHA PATH" >&2; exit 1; }
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "$name: SHA must be a full 40-character commit, got '$sha'" >&2; exit 1; }
    [[ ! -e "$dest/$name" ]] || { echo "$name: listed twice" >&2; exit 1; }

    # One shallow fetch per repo+commit, shared by plugins that live in the same repo.
    clone="$work/$(printf '%s' "$repo@$sha" | sha256sum | cut -c1-16)"
    if [[ ! -d "$clone" ]]; then
        git init -q "$clone"
        git -C "$clone" fetch -q --depth 1 "$repo" "$sha"
        git -C "$clone" checkout -q FETCH_HEAD
    fi

    src="$clone/$path"
    manifest="$src/.claude-plugin/plugin.json"
    [[ -f "$manifest" ]] || { echo "$name: no .claude-plugin/plugin.json at $repo $path" >&2; exit 1; }
    manifest_name="$(jq -r '.name' "$manifest")"
    [[ "$manifest_name" == "$name" ]] \
        || { echo "$name: plugin.json says its name is '$manifest_name'" >&2; exit 1; }

    mkdir -p "$dest/$name"
    cp -a "$src/." "$dest/$name/"
    rm -rf "$dest/$name/.git"
    echo "fetched $name @ ${sha:0:12}"
done < "$lock"
