# ============================================================
# Dockerfile  —  Claude Code development container
# Location   :  ~/claude-docker/Dockerfile
# Build ctx  :  ~/claude-docker/            ← self-contained
#
# No dependency on ~/projects/pyvar/ at build time.
# Python packages installed from local copies of pyvar
# requirements files. Sync them via: ./sync-requirements.sh
#
# The Numba JIT cache is NOT pre-warmed here — warmup only
# matters for the production runtime image (pyvar/Dockerfile).
# First pytest run compiles it (~2s); the numba_cache named
# volume persists it across restarts.
#
# Stages:
#   python-builder  Compiles C extensions with build tools.
#                   Build tools stripped from the final image.
#   claude-dev      node:22-slim + Python 3.11 + Claude Code.
#
# Build:
#   docker compose build --no-cache
#   docker compose build             (uses layer cache)
#
# Force plugin reinstall:
#   docker compose run --rm --entrypoint sh claude \
#     -c "rm /home/claude/.claude/.plugins-installed"
#
# Required files in ~/claude-docker/ (build context):
#   Dockerfile
#   entrypoint.sh
#   requirements-heavy.txt    ← sync via ./sync-requirements.sh
#   requirements.txt          ← sync via ./sync-requirements.sh
#   docker-compose.yml
#   .env
#   claude-backup/
# ============================================================


# ── Stage 1: python-builder ───────────────────────────────────────
# python:3.11-slim is Debian Bookworm. Build tools available here.
# Packages installed to /install and copied to the final stage.
FROM python:3.11-slim AS python-builder

WORKDIR /build

# Build deps for C extensions
# gcc / g++      — asyncpg, psycopg2, llvmlite (Numba)
# libpq-dev      — PostgreSQL client headers
# liblz4-dev     — PyArrow LZ4 codec (build time)
# libsnappy-dev  — PyArrow Snappy codec (build time)
# libzstd-dev    — PyArrow / Polars Zstandard codec (build time)
# libssl-dev     — Ray TLS, boto3
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libpq-dev \
    liblz4-dev \
    libsnappy-dev \
    libzstd-dev \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip setuptools wheel

# Heavy packages in a separate layer.
# Numba / Ray / QuantLib take 10-15 min — cached independently.
COPY requirements-heavy.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements-heavy.txt

# Application and dev packages.
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: claude-dev ───────────────────────────────────────────
# node:22-slim is Debian Bookworm (amd64 / arm64).
# Python 3.11 installed via apt — no pip calls at build time.
# All Python packages come from python-builder via COPY --from.
FROM node:22-slim AS claude-dev

# System runtime packages
#
# python3.11    — interpreter (Debian Bookworm package, no compilation)
# python3-pip   — pip command for runtime installs inside sessions;
#                 NOT called at build time (avoids PEP 668 block)
# gosu          — entrypoint.sh drops to non-root claude user
# git           — Claude Code version control operations
# libpq5        — asyncpg / psycopg2 runtime (no -dev headers needed)
# liblz4-1      — PyArrow LZ4 codec runtime
# libzstd1      — PyArrow / Polars Zstandard codec runtime
#
# Intentionally excluded:
#   python3.11-dev   — no C extension compilation in this stage
#   python3.11-venv  — not needed; all packages from python-builder
#   libsnappy1       — renamed libsnappy1t64 in Bookworm; not needed
#                      in dev (test fixtures use LZ4 or uncompressed)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3-pip \
    git \
    curl \
    ca-certificates \
    gosu \
    libpq5 \
    liblz4-1 \
    jq \
    libzstd1 \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python  python  /usr/bin/python3.11 1

# GitHub CLI (gh) — for issue filing, PR creation, and repo operations
# from inside Claude Code sessions without needing the web UI.
# Installed via the official GitHub apt repository (Debian Bookworm).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# AWS Session Manager plugin — enables interactive `aws ssm start-session`
# from inside Claude Code sessions (previously only `aws ssm send-command` +
# get-command-invocation worked, requiring a slower request/poll pattern
# during EC2 worker debugging). Architecture-aware: node:22-slim can be
# amd64 or arm64 depending on host, so the .deb URL is selected accordingly.
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "arm64" ]; then \
        SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb"; \
    else \
        SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"; \
    fi \
    && curl -fsSL "$SSM_URL" -o /tmp/ssm-plugin.deb \
    && dpkg -i /tmp/ssm-plugin.deb \
    && rm /tmp/ssm-plugin.deb

# Symlink
RUN ln -sf /usr/bin/python3.11 /usr/local/bin/python3.11

# Non-root user for Claude Code
RUN useradd --create-home --shell /bin/bash claude

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Install Context7 MCP — live API docs for numpy, FastAPI, SQLAlchemy.
# Prevents Claude Code from hallucinating function signatures.
RUN npm install -g @upstash/context7-mcp

# AWS CDK
RUN npm install -g aws-cdk

# Copy pre-built Python packages from python-builder.
# All pyvar deps (NumPy, Numba, FastAPI, Celery, etc.) land here.
# No pip calls needed in this stage.
COPY --from=python-builder /install /usr/local

# Add explicit install with --break-system-packages (overrides Debian PEP 668 protection)
# This is intentional for deployment tooling, not application packages
RUN pip install awscli boto3 aws-cdk-lib constructs pytest ruff --break-system-packages

# Numba cache directory — populated on first import, NOT pre-warmed.
# Persisted across restarts via the numba_cache named volume.
RUN mkdir -p /home/claude/.cache/numba \
    && chown -R claude:claude /home/claude/.cache

# Copy Claude config (settings.json, hooks, skills, plugin tree).
# Session history persists via claude_sessions volume.
# Auth token persists via claude_persist volume (managed by entrypoint.sh).
COPY --chown=claude:claude claude-backup/ /home/claude/.claude/

# Copy Claude default settings.
COPY --chown=claude:claude .claude.json /home/claude/.claude.json

# Strip Windows-built node_modules from plugin tree.
# install-plugins.sh (below) reinstalls the correct Linux binaries.
RUN mkdir -p /home/claude/.claude/plugins \
    && find /home/claude/.claude/plugins -type d -name "node_modules" \
        -exec rm -rf {} + 2>/dev/null || true \
    && chown -R claude:claude /home/claude/.claude/plugins

# Plugins installed at build time via install-plugins.sh (see below)

# /workspace is populated at runtime via bind-mount in docker-compose.yml.
RUN mkdir -p /workspace && chown claude:claude /workspace

# Entrypoint manages Claude Code plugins only.
# Python packages are already installed via COPY --from=python-builder.
# Never add pip install commands here.
COPY install-plugins.sh /tmp/install-plugins.sh
RUN chmod +x /tmp/install-plugins.sh
ARG GITHUB_TOKEN
RUN git config --global \
        url."https://${GITHUB_TOKEN}@github.com/".insteadOf \
        "https://github.com/" \
    && gosu claude /tmp/install-plugins.sh \
    && git config --global --unset-all \
        url."https://${GITHUB_TOKEN}@github.com/".insteadOf \
    && rm /tmp/install-plugins.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV NUMBA_CACHE_DIR=/home/claude/.cache/numba
ENV NUMBA_DISABLE_JIT=0
ENV RAY_DISABLE_IMPORT_WARNING=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/workspace/pyvar

USER root
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
