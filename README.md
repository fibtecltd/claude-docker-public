# claude-docker-public

Fibtec's containerized Claude Code development environment — Docker + Docker
Compose setup that bakes plugins into the image at build time, persists auth
and session history across `--rm` restarts, and pre-installs the Python
toolchain for [pyvar](https://github.com/fibtecltd/pyvar), Fibtec's public
risk-computation platform.

This is the **public mirror** of Fibtec's internal `claude-docker` repo. It's
kept in sync via `scripts/sync-to-public.sh`, run from the private repo —
see that script for exactly what is and isn't mirrored here (personal
Claude Code auth/telemetry and a couple of project-specific integrations are
deliberately excluded).

## Before you build

- **Read [SETUP.md](./SETUP.md) first.** It covers the fork-based plugin
  architecture, build steps, and — importantly — the permission-mode
  default this image ships with.
- `claude-backup/settings.json` ships with
  `"permissions": {"defaultMode": "bypassPermissions"}`. Claude Code will run
  tools in this container without per-action confirmation prompts. That's a
  deliberate choice for a disposable containerized environment, not Claude
  Code's own default — decide for yourself whether you want that before you
  build.
- Copy `.env.example` to `.env` and fill in your own `ANTHROPIC_API_KEY`
  (and optionally a `GITHUB_TOKEN`) before running `docker compose build`.
  Never commit `.env`.

## Quick start

```bash
git clone https://github.com/fibtecltd/claude-docker-public
cd claude-docker-public
cp .env.example .env   # add ANTHROPIC_API_KEY
docker compose build --no-cache claude
docker compose run --rm claude
```

## License

MIT — see [LICENSE](./LICENSE). Bundled plugin marketplaces (forks of
third-party projects) retain their own upstream licenses; see LICENSE for
details.
