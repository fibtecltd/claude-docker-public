#!/bin/sh
# ============================================================
# install-plugins.sh
# Runs as the claude user during Docker image build (RUN step).
# Registers fibtecltd marketplace forks and installs all plugins.
# Never runs at container start — that is entrypoint.sh's role.
#
# Called from Dockerfile as:
#   RUN gosu claude /tmp/install-plugins.sh
#
# Network required at build time.
# No ANTHROPIC_API_KEY needed — marketplace/install is local git ops.
# ============================================================

set -e

echo "[install-plugins] Registering marketplaces ..."

# claude-plugins-official — Anthropic GCS-backed, always stable
claude plugin marketplace update claude-plugins-official \
    && echo "[install-plugins] claude-plugins-official OK" \
    || echo "[install-plugins] WARNING: claude-plugins-official failed"

# fibtecltd forks — schema-controlled, version-locked
# Fork of wshobson/agents registered as claude-code-workflows
claude plugin marketplace add fibtecltd/claude-workflows \
    && echo "[install-plugins] claude-code-workflows (fibtecltd fork) OK" \
    || echo "[install-plugins] WARNING: claude-code-workflows failed"

# Fork of ruslan-korneev/python-backend-claude-plugins
claude plugin marketplace add fibtecltd/python-backend-plugins \
    && echo "[install-plugins] python-backend-plugins (fibtecltd fork) OK" \
    || echo "[install-plugins] WARNING: python-backend-plugins failed"

# Fork of alirezarezvani/claude-skills
claude plugin marketplace add fibtecltd/claude-skills \
    && echo "[install-plugins] claude-code-skills (fibtecltd fork) OK" \
    || echo "[install-plugins] WARNING: claude-code-skills failed"

# Optional marketplaces — best effort, non-blocking
claude plugin marketplace add levnikolaevich/claude-code-skills \
    2>/dev/null && echo "[install-plugins] levnikolaevich OK" || true
claude plugin marketplace add K-Dense-AI/scientific-agent-skills \
    2>/dev/null && echo "[install-plugins] K-Dense-AI OK" || true
claude plugin marketplace add JoelLewis/finance_skills \
    2>/dev/null && echo "[install-plugins] JoelLewis OK" || true

echo "[install-plugins] Installing plugins ..."

# ── claude-plugins-official (11) ─────────────────────────────
claude plugins install claude-md-management@claude-plugins-official   || true
claude plugins install commit-commands@claude-plugins-official         || true
claude plugins install context7@claude-plugins-official                || true
claude plugins install feature-dev@claude-plugins-official             || true
claude plugins install frontend-design@claude-plugins-official         || true
claude plugins install github@claude-plugins-official                  || true
claude plugins install pr-review-toolkit@claude-plugins-official       || true
claude plugins install pyright-lsp@claude-plugins-official             || true
claude plugins install ralph-loop@claude-plugins-official              || true
claude plugins install skill-creator@claude-plugins-official           || true
claude plugins install superpowers@claude-plugins-official             || true

# ── claude-skills — fibtecltd/claude-skills (7) ──
claude plugins install engineering-skills@claude-code-skills           || true
claude plugins install data-quality-auditor@claude-code-skills         || true
claude plugins install docker-development@claude-code-skills           || true
claude plugins install finance-skills@claude-code-skills               || true
claude plugins install karpathy-coder@claude-code-skills               || true
claude plugins install statistical-analyst@claude-code-skills          || true
claude plugins install terraform-patterns@claude-code-skills           || true

# ── claude-code-workflows — fibtecltd/claude-workflows (18) ──
claude plugins install agent-orchestration@claude-code-workflows        || true
claude plugins install api-scaffolding@claude-code-workflows            || true
claude plugins install api-testing-observability@claude-code-workflows  || true
claude plugins install application-performance@claude-code-workflows    || true
claude plugins install backend-development@claude-code-workflows        || true
claude plugins install blockchain-web3@claude-code-workflows            || true
claude plugins install cloud-infrastructure@claude-code-workflows       || true
claude plugins install code-documentation@claude-code-workflows         || true
claude plugins install comprehensive-review@claude-code-workflows       || true
claude plugins install data-engineering@claude-code-workflows           || true
claude plugins install database-cloud-optimization@claude-code-workflows || true
claude plugins install documentation-generation@claude-code-workflows   || true
claude plugins install frontend-mobile-development@claude-code-workflows || true
claude plugins install performance-testing-review@claude-code-workflows  || true
claude plugins install python-development@claude-code-workflows          || true
claude plugins install quantitative-trading@claude-code-workflows        || true
claude plugins install security-scanning@claude-code-workflows           || true
claude plugins install unit-testing@claude-code-workflows                || true

# ── python-backend-plugins — fibtecltd/python-backend-plugins (4) ──
claude plugins install clean-code@python-backend-plugins       || true
claude plugins install pytest-assistant@python-backend-plugins  || true
claude plugins install python-typing@python-backend-plugins     || true
claude plugins install ruff-lint@python-backend-plugins         || true

# ── Optional — levnikolaevich (2) ───────────────────────────
claude plugins install \
    ln-100-documents-pipeline@levnikolaevich-skills-marketplace || true
claude plugins install \
    ln-620-codebase-auditor@levnikolaevich-skills-marketplace   || true

# ── Optional — K-Dense-AI scientific (2) ────────────────────
claude plugins install \
    data-analysis@K-Dense-AI-scientific-agent-skills      || true
claude plugins install \
    scientific-computing@K-Dense-AI-scientific-agent-skills || true

# ── Optional — JoelLewis finance (4) ────────────────────────
claude plugins install compliance@JoelLewis-finance-skills        || true
claude plugins install core@JoelLewis-finance-skills              || true
claude plugins install trading-operations@JoelLewis-finance-skills || true
claude plugins install wealth-management@JoelLewis-finance-skills  || true

echo ""
INSTALLED=$(find /home/claude/.claude/plugins -name "plugin.json" \
    2>/dev/null | wc -l)
echo "[install-plugins] Complete. Plugin manifests installed: $INSTALLED"
