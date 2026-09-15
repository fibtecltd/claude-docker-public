#!/bin/bash
# ============================================================
# update-plugins.sh
# Pulls upstream changes into fibtecltd forks and rebuilds
# the Claude Code image with updated plugins.
#
# Run from ~/claude-docker/ after merging changes into forks.
#
# Usage:
#   ./update-plugins.sh              — rebuild with current forks
#   ./update-plugins.sh --sync       — pull upstream into forks first
#   ./update-plugins.sh --dry-run    — show what would happen
# ============================================================

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-$HOME/claude-docker/docker-compose.yml}"
DRY_RUN=0
SYNC=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --sync)    SYNC=1 ;;
    esac
done

run() {
    if [ $DRY_RUN -eq 1 ]; then
        echo "[dry-run] $*"
    else
        echo "[exec] $*"
        eval "$@"
    fi
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  update-plugins.sh                                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Optional: sync forks with upstream ───────────────────────
if [ $SYNC -eq 1 ]; then
    echo "Syncing fibtecltd forks with upstream ..."

    # claude-workflows ← wshobson/agents
    WORKFLOWS_DIR="${HOME}/forks/claude-workflows"
    if [ -d "$WORKFLOWS_DIR" ]; then
        echo "  Syncing claude-workflows ..."
        run "git -C '$WORKFLOWS_DIR' fetch upstream"
        run "git -C '$WORKFLOWS_DIR' merge upstream/main --no-ff \
            -m 'chore: sync with wshobson/agents'"
        run "git -C '$WORKFLOWS_DIR' push origin main"
    else
        echo "  WARNING: $WORKFLOWS_DIR not found."
        echo "  Clone it: git clone git@github.com:fibtecltd/claude-workflows $WORKFLOWS_DIR"
        echo "  Then add upstream: git -C $WORKFLOWS_DIR remote add upstream \\"
        echo "    https://github.com/wshobson/agents"
    fi

    # python-backend-plugins ← ruslan-korneev
    PYTHON_DIR="${HOME}/forks/python-backend-plugins"
    if [ -d "$PYTHON_DIR" ]; then
        echo "  Syncing python-backend-plugins ..."
        run "git -C '$PYTHON_DIR' fetch upstream"
        run "git -C '$PYTHON_DIR' merge upstream/main --no-ff \
            -m 'chore: sync with ruslan-korneev/python-backend-claude-plugins'"
        run "git -C '$PYTHON_DIR' push origin main"
    else
        echo "  WARNING: $PYTHON_DIR not found."
    fi

    echo ""
fi

# ── Rebuild image with updated plugin forks ───────────────────
echo "Rebuilding image ..."
echo "  --no-cache forces fresh clone of fibtecltd marketplace forks."
echo ""
run "docker compose -f '$COMPOSE_FILE' build --no-cache claude"

echo ""
echo "Build complete. Run /doctor to verify:"
echo "  docker compose -f '$COMPOSE_FILE' run --rm claude"
echo ""
echo "To distribute to team: git push (if Dockerfile or install-plugins.sh changed)"
