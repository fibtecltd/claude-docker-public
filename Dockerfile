# ============================================================
# Claude Code images for headless runs on ECS Fargate
#
# Two targets. Without --target Docker builds the last stage (ecs-deploy), so
# always name the target you want:
#   ecs-base    Claude Code + git/gh/jq + a Python 3.12 venv (pip, uv, pytest,
#               ruff, boto3, awscli) + the plugins pinned in plugins.lock and
#               the profiles that choose among them (CLAUDE_PROFILE)
#   ecs-deploy  ecs-base + AWS CDK (CLI and Python lib) + Stripe CLI + SSM plugin
#
# No Numba, Ray, Dask, QuantLib or C toolchain; Python 3.12 comes from uv.
#
# Build (BuildKit required; the GitHub token secret is optional):
#   docker build --target ecs-base   -t claude-ecs-base .
#   docker build --target ecs-deploy -t claude-ecs-deploy \
#       --secret id=github_token,env=GITHUB_PERSONAL_ACCESS_TOKEN .
#   pin Claude Code:  --build-arg CLAUDE_CODE_VERSION=x.y.z
#
# Run (no volumes, no entrypoint script; everything is baked in):
#   docker compose run --rm claude-ecs-base -p "say hi"     (key read from .env)
#   docker run --rm -e ANTHROPIC_API_KEY -e CLAUDE_PROFILE=pyvar claude-ecs-base -p "say hi"
#   docker run --rm -it --entrypoint bash claude-ecs-base
#
# Design notes:
#   - runs as non-root `claude`: no gosu, and no chown/chmod/sed at container start
#   - ENTRYPOINT is `ecs-claude`, a wrapper that adds the profile's plugins and
#     execs claude: container args are still Claude Code args
#   - plugins are plain directories fetched at pinned commits (no marketplace)
#   - the GitHub token comes from a BuildKit secret mount, not ARG, so it never
#     lands in image history (and therefore never in ECR)
#   - minimal inline ~/.claude.json (no personal state); auto-updater disabled
#   - CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is off, and cannot be used on Fargate (see below)
# ============================================================

# ── Stage 1: ecs-base ─────────────────────────────────────────────
FROM node:22-slim AS ecs-base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 2.1.293 is the first release that runs Haiku 5.5 (claude-haiku-5-5).
ARG CLAUDE_CODE_VERSION=2.1.294

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    jq \
    bubblewrap \
    socat \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI — from the official apt repository.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Python 3.12 via uv (Debian Bookworm only ships 3.11). The interpreter is
# installed outside any home directory so the non-root user can read it.
# --seed gives the venv pip, so `pip install -r requirements.txt` keeps working
# in sessions; `uv pip install` is the faster path.
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /uvx /usr/local/bin/
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:${PATH}
RUN uv venv /opt/venv --python 3.12 --seed \
    && uv pip install --python /opt/venv/bin/python awscli boto3 pytest ruff

# Fixed uid so the BuildKit secret mount below can be handed to this user.
RUN useradd --uid 1001 --create-home --shell /bin/bash claude \
    && mkdir -p /workspace \
    && chown claude:claude /workspace

# Claude Code.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# Plugins: plain directories under /opt/claude/plugins, each fetched at the
# commit pinned in plugins.lock and owned by root (read-only for `claude`).
# The script and lock are bind-mounted, so they leave no layer behind. The
# optional token reaches git through environment config, never a file, and only
# inside this RUN.
RUN --mount=type=bind,source=plugins.lock,target=/tmp/plugins.lock \
    --mount=type=bind,source=scripts/build/fetch-plugins.sh,target=/tmp/fetch-plugins.sh \
    --mount=type=secret,id=github_token,required=false \
    set -e; \
    if [ -s /run/secrets/github_token ]; then \
        token="$(cat /run/secrets/github_token)"; \
        export GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0="url.https://${token}@github.com/.insteadOf" \
            GIT_CONFIG_VALUE_0="https://github.com/"; \
    fi; \
    bash /tmp/fetch-plugins.sh /tmp/plugins.lock /opt/claude/plugins

# Profiles (which plugins a run loads) and the entrypoint wrapper.
COPY profiles/ /opt/claude/profiles/
COPY --chmod=0755 scripts/runtime/ecs-claude /usr/local/bin/ecs-claude

# User-level Claude config: settings only (no agents, commands, skills or hooks;
# those come from plugins and from the project being worked on). The minimal
# ~/.claude.json is written inline so there is no personal state in the image.
COPY --chown=claude:claude claude-config/ /home/claude/.claude/
RUN printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false,"theme":"dark","projects":{"/workspace":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}' \
        > /home/claude/.claude.json \
    && chown claude:claude /home/claude/.claude.json

USER claude

# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: off. With 1, Claude Code removes credentials (ANTHROPIC_API_KEY among
# them) from the environment of the commands it runs, and on Linux runs them in their own PID namespace so
# they cannot read the parent's environment through /proc. The Claude Code process itself keeps the key for
# its API calls; GITHUB_TOKEN and GH_TOKEN are left in place by design.
# DO NOT SWITCH IT ON IN A FARGATE TASK. It runs every command through bubblewrap with no unsandboxed
# fallback, and bubblewrap cannot create a user namespace in a Fargate task ("bwrap: No permissions to
# create new namespace", measured 2026-10-29), so every command the agent runs is blocked. Where a runtime
# lets bubblewrap create namespaces (a VM, or a local container that allows it), switch it on per run:
#   docker compose run --rm -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 claude-ecs-base -p "..."
# bubblewrap and socat are installed for that case: Claude Code's Linux sandbox needs both. With the scrub
# on and bubblewrap missing, Claude Code exits at start; with socat missing it refuses every command
# ("Sandbox is required but failed to initialize: ... socat not installed", seen 2026-10-29).
# scripts/run/first-runs.sh (G4b) reports what a command can see of the API key. docs/runbook.md section 6.
ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_SKIP_ONBOARDING=1 \
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
    PYTHONUNBUFFERED=1

WORKDIR /workspace
ENTRYPOINT ["ecs-claude"]
CMD []

# ── Stage 2: ecs-deploy ───────────────────────────────────────────
# ecs-base + what `cdk deploy` and the Stripe/SSM smoke scripts need.
FROM ecs-base AS ecs-deploy

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

RUN npm install -g aws-cdk \
    && npm cache clean --force \
    && uv pip install --python /opt/venv/bin/python aws-cdk-lib constructs

# Stripe CLI — static binary from GitHub Releases. The version is pinned: no
# api.github.com lookup, which is rate-limited for anonymous callers on shared
# CI runners. Release assets name amd64 as x86_64 (not dpkg's "amd64"), so the
# architecture is mapped explicitly.
ARG STRIPE_CLI_VERSION=1.53.0
RUN case "$(dpkg --print-architecture)" in \
        amd64) STRIPE_ARCH=x86_64 ;; \
        arm64) STRIPE_ARCH=arm64 ;; \
        *) echo "Stripe CLI: unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/stripe.tar.gz \
        "https://github.com/stripe/stripe-cli/releases/download/v${STRIPE_CLI_VERSION}/stripe_${STRIPE_CLI_VERSION}_linux_${STRIPE_ARCH}.tar.gz" \
    && tar -xzf /tmp/stripe.tar.gz -C /usr/local/bin stripe \
    && rm /tmp/stripe.tar.gz

# AWS Session Manager plugin — amd64/arm64 selected by dpkg.
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "arm64" ]; then \
        SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb"; \
    else \
        SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"; \
    fi \
    && curl -fsSL "$SSM_URL" -o /tmp/ssm-plugin.deb \
    && dpkg -i /tmp/ssm-plugin.deb \
    && rm /tmp/ssm-plugin.deb

USER claude
