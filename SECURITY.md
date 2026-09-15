# Security Policy

This repository builds a Docker image that runs Claude Code — an AI coding
agent — with real credentials (an Anthropic API key, optionally a GitHub
token, AWS credentials, etc.) passed through as environment variables. A
vulnerability here could mean credential exposure or an agent running
outside the isolation this setup is meant to provide, so we take reports
seriously and ask that you report them responsibly rather than through a
public GitHub issue.

## Reporting a vulnerability

**Do not open a public issue or PR for a security vulnerability.**

Email **security@fibtec.co.uk** with:

- A description of the vulnerability and its potential impact.
- Steps to reproduce.
- Whether it's a credential-exposure issue, a container-isolation escape,
  or something in the bundled plugin/marketplace tooling.

We aim to acknowledge reports within **3 business days** and to provide an
initial assessment within **10 business days**. We'll coordinate with you on
disclosure timing once a fix is available; please give us a reasonable
window to patch before any public disclosure.

## Scope

In scope:

- `Dockerfile`, `entrypoint.sh`, `install-plugins.sh`, `docker-compose.yml` —
  how credentials/secrets flow into and are handled inside the container.
- `claude-backup/` — the Claude Code configuration baked into the image
  (settings, hooks, skills, plugin marketplace registrations).
- The `scripts/` sync tooling that produces this repository's content from
  Fibtec's private original.

Out of scope:

- Vulnerabilities in the upstream projects this repo forks as plugin
  marketplaces (`fibtecltd/claude-workflows`, `fibtecltd/python-backend-plugins`,
  `fibtecltd/claude-skills`, and their own upstreams) — report those to the
  relevant upstream project instead, unless the issue is specifically in how
  this repo installs or configures them.
- Findings that require access to Fibtec's own private infrastructure,
  CI secrets, or internal systems not represented in this repository.
- `claude-backup/settings.json` shipping with `"defaultMode": "bypassPermissions"`
  is a documented, intentional default for this containerized environment
  (see SETUP.md) — not itself a vulnerability report, though a way that
  setting could be silently defeated or misrepresented would be.

## Supported versions

This repository has no release/version scheme — only the current `main` is
supported. Security fixes land on `main`.

## Known limitations

`claude-backup/settings.json` intentionally ships with
`"permissions": {"defaultMode": "bypassPermissions"}`. Read SETUP.md before
building if you are not comfortable running an unattended agent with
per-action confirmation prompts disabled.
