# Security Policy

This repository builds container images that run Claude Code, an AI coding agent,
with real credentials (an Anthropic API key, optionally GitHub tokens) passed in as
environment variables, and a CDK app that runs those images on AWS ECS Fargate. A
vulnerability here could mean credential exposure, an agent running outside the
isolation this setup is meant to provide, or over-broad AWS permissions, so we take
reports seriously and ask that you report them responsibly rather than through a
public GitHub issue.

## Reporting a vulnerability

**Do not open a public issue or PR for a security vulnerability.**

Email **security@fibtec.co.uk** with:

- A description of the vulnerability and its potential impact.
- Steps to reproduce.
- Whether it is a credential-exposure issue, a container-isolation escape, an
  infrastructure (IAM, network, secrets) issue, or something in how plugins are
  fetched and pinned.

We aim to acknowledge reports within **3 business days** and to provide an initial
assessment within **10 business days**. We will coordinate with you on disclosure
timing once a fix is available; please give us a reasonable window to patch before
any public disclosure.

## Scope

In scope:

- `Dockerfile`, `docker-compose.yml`, `scripts/runtime/ecs-claude`: how credentials
  flow into and are handled inside the container, and the non-root user.
- `scripts/build/` and `plugins.lock`: how plugins are fetched, pinned and installed
  (including the BuildKit secret used for the optional GitHub token).
- `claude-config/settings.json`: the Claude Code settings baked into the image.
- `infra/`: the CDK app (IAM roles, security groups and egress, secrets handling,
  logging).
- `scripts/run/run-task.sh` and `.github/workflows/`.

Out of scope:

- Vulnerabilities in the upstream projects whose plugins are pinned in `plugins.lock`
  (and their own upstreams): report those to the relevant project instead, unless the
  issue is specifically in how this repository fetches or configures them.
- Findings that need access to Fibtec's own private infrastructure, CI secrets or
  internal systems that this repository does not contain.
- `claude-config/settings.json` shipping with `"defaultMode": "bypassPermissions"`:
  a documented, intentional default for a headless run in a disposable container
  (see "Known limitations"). It is not itself a vulnerability report, though a way
  that setting could be silently defeated or misrepresented would be.

## Supported versions

This repository has no release or version scheme; only the current `main` is
supported. Security fixes land on `main`.

## Known limitations

- `claude-config/settings.json` ships with `"permissions": {"defaultMode":
  "bypassPermissions"}` and `skipDangerousModePermissionPrompt`, because a headless
  run cannot answer permission prompts. The agent can run any tool in the container.
  Run it with tokens scoped to what a task needs, and set cost limits per task
  (`--max-turns`, `--max-budget-usd`).
- The prompt, repository name and `--env` values passed to `run-task.sh` are part of
  the ECS request, so they are visible to anyone who can call `ecs:DescribeTasks` and
  appear in CloudTrail. Everything the container prints goes to CloudWatch Logs. See
  `docs/runbook.md` before running a workload with data-handling restrictions.
