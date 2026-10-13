# Contributing to claude-docker-public

Thanks for considering a contribution. One thing differs from a usual project:
this repository is an **export**. Fibtec maintains it in a private source
repository, and a script copies that source here after checking it for secrets and
for anything not meant to be public. Read this before opening a pull request.

## How a contribution travels

- Open a pull request here as usual. It is reviewed here.
- If it is accepted, a maintainer applies the same change to the source repository
  before the next export, because an export replaces this repository's files (the
  export's dry run shows any difference, so a change made only here is noticed).
  The pull request is merged here so your commit stays in the history.
- So a merged change can take a little longer than usual to be reflected in the
  source, and a change that is not applied there would be undone by the next export.
  If you notice that happening, say so in an issue.
- Files that exist only here (`LICENSE`, `NOTICE`, `SECURITY.md`, this file, the
  issue templates and `articles/`) are edited directly and are never overwritten.

## Ways to contribute

- **Image and build fixes**: `Dockerfile`, `docker-compose.yml`, `scripts/build/`,
  `scripts/runtime/ecs-claude`.
- **Infrastructure**: the CDK app in `infra/`, `scripts/run/run-task.sh` and
  `docs/runbook.md`.
- **Plugins and profiles**: `plugins.lock` pins, and a `profiles/<name>.plugins` file
  for a new deployment.
- **Documentation**: `README.md`, `docs/`, `infra/README.md`.
- **Bug reports and ideas**: a GitHub issue (see the templates).

## Pull request checklist

- [ ] Nothing that is not meant for a public audience: no credentials, account ids,
      internal names or personal data.
- [ ] Shell changes pass `shellcheck` (CI runs it on every script).
- [ ] If you change the `Dockerfile` or a plugin pin, the image builds and
      `scripts/ci/smoke-ecs.sh IMAGE base` passes (CI does both; a Docker build
      needs BuildKit).
- [ ] If you change `infra/`, `cd infra && python -m pytest` passes.
- [ ] Commit messages say what changed and why. No format is enforced here.

## Questions

Open a GitHub issue, or write to info@fibtec.co.uk.
