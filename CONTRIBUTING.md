# Contributing to claude-docker-public

Thanks for considering a contribution. This repo is a public mirror — it
does not accept direct pushes or merges into its own history the way a
normal project would, so what "contributing" means here is a bit different.
Read this before opening a PR.

## How this repo is maintained

`claude-docker-public` is generated from Fibtec's private `claude-docker`
repo by `scripts/sync-to-public.sh`, which applies a sanitization policy
(strips internal-project-specific config, replaces personal Claude Code
telemetry with clean templates, runs a secret scan) before anything is
pushed here. See that script (in the private repo) for the exact policy.

This means:

- A PR against this repo can be reviewed and merged here directly — that's
  the normal path for anything scoped to this repo (Dockerfile, entrypoint,
  scripts, `claude-backup/` content, docs).
- Changes get folded back into the private original by hand
  (`scripts/sync-from-public.sh`, additive-only, never overwrites the
  private repo's real config) — so a merged PR here may take a little
  longer to show up reflected everywhere than a normal single-repo project.

## Ways to contribute

- **Docker/build fixes** — `Dockerfile`, `docker-compose.yml`,
  `entrypoint.sh`, `install-plugins.sh`.
- **Claude Code configuration** — additions or fixes to `claude-backup/`
  (agents, commands, skills, hooks). Note `claude-backup/settings.json`,
  `claude-backup/config.json`, and `claude-backup/policy-limits.json` are
  patched by the sync script from private-repo originals — a PR touching
  those three specifically will need manual reconciliation on the private
  side rather than a normal merge.
- **Documentation** — `README.md`, `SETUP.md`, this file.
- **Bug reports** — via a GitHub issue (see the templates).

## PR checklist

- [ ] Doesn't reintroduce anything the sanitization policy strips (real
      credentials, internal project names, personal telemetry — see
      `scripts/public-mirror/lib.sh` in the private repo if you have access,
      or just: nothing that isn't meant for a public audience).
- [ ] Shell changes pass `bash -n <file>` at minimum.
- [ ] If you're changing `Dockerfile`/`docker-compose.yml`, you've actually
      run `docker compose build --no-cache claude` and
      `docker compose run --rm claude` locally.
- [ ] Commit messages are reasonably descriptive — no fixed convention is
      enforced here, unlike the private repo's Conventional Commits rule.

## Questions

Open a GitHub issue, or reach out at info@fibtec.co.uk.
