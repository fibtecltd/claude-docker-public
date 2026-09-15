#!/bin/sh
# ============================================================
# entrypoint.sh — pyvar.com (B+D)
# Repo: https://github.com/fibtecltd/claude-docker-public
#
# Plugins are baked into the image at build time by install-plugins.sh.
# This file handles only: permissions, auth restore, startup, auth save.
# No marketplace calls. No plugin installation.
# ============================================================

# ── 1. Permissions ───────────────────────────────────────────
echo "[entrypoint] Fixing permissions ..."
chown -R claude:claude /home/claude/.claude
chmod -R 777 /home/claude/.claude
chown claude:claude /workspace 2>/dev/null || true

# ── 2. Persist and restore .claude.json ──────────────────────
# .claude.json lives at /home/claude/.claude.json — outside the
# .claude/ directory. It is not covered by any named volume.
# claude_persist volume at /home/claude/.claude-persist/ stores
# a copy so auth and settings survive container restarts with --rm.
#
# Priority: persist volume > image-baked defaults.
# The file is always present in the image (COPY in Dockerfile),
# so we must check the persist volume FIRST; otherwise the
# image default would overwrite previously saved auth/settings.
CLAUDE_JSON="/home/claude/.claude.json"
PERSIST_DIR="/home/claude/.claude-persist"
PERSISTED="$PERSIST_DIR/.claude.json"

mkdir -p "$PERSIST_DIR"
chown claude:claude "$PERSIST_DIR"

if [ -f "$PERSISTED" ]; then
    cp "$PERSISTED" "$CLAUDE_JSON"
    chown claude:claude "$CLAUDE_JSON"
    echo "[entrypoint] Restored .claude.json from persist volume."
elif [ -f "$CLAUDE_JSON" ]; then
    cp "$CLAUDE_JSON" "$PERSISTED"
    chown claude:claude "$PERSISTED"
    echo "[entrypoint] Seeded persist volume from image .claude.json."
else
    echo "[entrypoint] NOTE: .claude.json not found — re-auth required."
fi

# ── 3. Clear Windows-originated backups ──────────────────────
if [ -d "/home/claude/.claude/backups" ]; then
    rm -rf /home/claude/.claude/backups
fi

# ── 4. Strip Windows carriage returns (CRLF → LF) ────────────
find /home/claude/.claude -type f \
    \( -name "*.md" -o -name "*.json" -o -name "*.js" \) \
    | xargs sed -i 's/\r//' 2>/dev/null || true

# ── 5. Launch Claude Code and save .claude.json on exit ──────
# NOTE: gosu is called WITHOUT exec so this shell process
# survives after Claude Code exits, allowing the post-exit
# save block below to run. This is intentional.
echo "[entrypoint] Starting Claude Code as claude user ..."
gosu claude claude "$@"
EXIT_CODE=$?

# ── 6. Save .claude.json back to persist volume ──────────────
# Claude Code may have written new auth tokens, answered prompts,
# or updated migration flags during the session. Saving here
# ensures the next container start restores the latest state,
# suppressing any prompts that were already answered.
if [ -f "$CLAUDE_JSON" ]; then
    cp "$CLAUDE_JSON" "$PERSISTED"
    chown claude:claude "$PERSISTED"
    echo "[entrypoint] Saved .claude.json to persist volume."
fi

exit $EXIT_CODE
