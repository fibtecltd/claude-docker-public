#!/bin/bash
# ============================================================
# sync-requirements.sh
# Location: ~/claude-docker/sync-requirements.sh
#
# Copies requirements-heavy.txt and requirements.txt from the
# pyvar project into claude-docker/ so the Dockerfile can use
# them without a cross-directory build context.
#
# Run this whenever pyvar/requirements*.txt changes and you
# want to rebuild the claude-dev Docker image with updated deps.
#
# Usage:
#   ./sync-requirements.sh              — sync and show diff
#   ./sync-requirements.sh --check      — diff only, no copy
#   ./sync-requirements.sh --rebuild    — sync then docker compose build
#   ./sync-requirements.sh --rebuild --no-cache  — sync then full rebuild
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYVAR_DIR="${PYVAR_DIR:-$HOME/projects/pyvar}"

CHECK_ONLY=0
REBUILD=0
NO_CACHE=""

for arg in "$@"; do
    case "$arg" in
        --check)      CHECK_ONLY=1 ;;
        --rebuild)    REBUILD=1 ;;
        --no-cache)   NO_CACHE="--no-cache" ;;
    esac
done

# ── Verify source exists ──────────────────────────────────────────
if [ ! -d "$PYVAR_DIR" ]; then
    echo "ERROR: pyvar directory not found: $PYVAR_DIR"
    echo "       Set PYVAR_DIR env var to the correct path."
    exit 1
fi

for f in requirements-heavy.txt requirements.txt; do
    if [ ! -f "$PYVAR_DIR/$f" ]; then
        echo "ERROR: $PYVAR_DIR/$f not found."
        exit 1
    fi
done

# ── Diff check ────────────────────────────────────────────────────
echo "Comparing requirements files ..."
CHANGED=0
for f in requirements-heavy.txt requirements.txt; do
    src="$PYVAR_DIR/$f"
    dst="$SCRIPT_DIR/$f"

    if [ ! -f "$dst" ]; then
        echo "  NEW      $f  (not yet in claude-docker/)"
        CHANGED=1
    elif ! diff -q "$src" "$dst" > /dev/null 2>&1; then
        echo "  CHANGED  $f"
        diff --unified=3 "$dst" "$src" | head -30 | sed 's/^/    /'
        CHANGED=1
    else
        echo "  OK       $f  (in sync)"
    fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    if [ "$CHANGED" -eq 1 ]; then
        echo "Files are out of sync. Run: ./sync-requirements.sh"
        exit 1
    else
        echo "Files are in sync."
        exit 0
    fi
fi

# ── Copy ──────────────────────────────────────────────────────────
if [ "$CHANGED" -eq 1 ]; then
    echo ""
    echo "Syncing ..."
    for f in requirements-heavy.txt requirements.txt; do
        cp "$PYVAR_DIR/$f" "$SCRIPT_DIR/$f"
        echo "  copied: $PYVAR_DIR/$f  →  $SCRIPT_DIR/$f"
    done
    echo ""
    echo "NOTE: requirements files are now in sync."
    echo "      They are intentional copies, not symlinks."
    echo "      Commit them to claude-docker/ so the repo is self-contained:"
    echo "      git add requirements*.txt && git commit -m 'sync: requirements from pyvar'"
else
    echo "Already in sync — nothing to copy."
fi

# ── Optional rebuild ──────────────────────────────────────────────
if [ "$REBUILD" -eq 1 ]; then
    echo ""
    if [ "$CHANGED" -eq 1 ] || [ -n "$NO_CACHE" ]; then
        echo "Rebuilding claude image ..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" build $NO_CACHE claude
    else
        echo "No requirements changes — skipping rebuild."
        echo "Force rebuild: ./sync-requirements.sh --rebuild --no-cache"
    fi
fi
