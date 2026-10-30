# Claude Code on AWS ECS Fargate

Container images for running [Claude Code](https://code.claude.com) headlessly on AWS ECS Fargate, plus a local way to build and smoke-test them.

## Images

Docker builds the last stage when no `--target` is given (that is `ecs-deploy`), so always name the target you want.

| Target | Contents |
|---|---|
| `ecs-base` | `node:22-slim`, Claude Code (pinned), git, gh, jq, a Python 3.12 venv (pip, uv, pytest, ruff, boto3, awscli), the plugins pinned in `plugins.lock` and the profiles that choose among them |
| `ecs-deploy` | `ecs-base` plus the AWS CDK (CLI and Python library), the Stripe CLI and the AWS SSM session-manager plugin |

Not included: Numba, Ray, Dask, QuantLib or a C toolchain.

Design choices that matter on ECS:

- Runs as a non-root `claude` user, with nothing executed at container start (no `chown`/`chmod`/`sed` pass).
- `ENTRYPOINT` is `ecs-claude`, a small wrapper that adds the selected profile's plugins, optionally clones a repository (`CLAUDE_REPO`, `CLAUDE_REF`), and then `exec`s `claude`, so container arguments are still Claude Code arguments. A headless run is `-p "…"`, which maps directly onto an ECS command override.
- No agents, commands, skills or hooks are baked into the user-level config; they come from plugins and from the project being worked on. The only user-level file is `claude-config/settings.json` (model, effort levels, permission mode).
- Plugins are plain directories fetched at the commits pinned in `plugins.lock` (no marketplace, no install step), owned by root and read-only for the `claude` user.
- The API key is in the environment of every command the agent runs. Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` would hide it, but it runs commands through `bubblewrap`, which cannot create a user namespace in a Fargate task, so the image leaves it off and it must not be switched on in a task (runbook, section 6). The image installs `bubblewrap` and `socat` (the two packages Claude Code's Linux sandbox needs) for runtimes where it works, for example `docker compose run -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 …`.
- The optional GitHub token used while fetching plugins is a BuildKit secret mount, not a build argument, so it does not end up in image history.
- Versions are pinned where they can be: Claude Code (`CLAUDE_CODE_VERSION`), `uv`, the Stripe CLI (`STRIPE_CLI_VERSION`). The SSM plugin is not.

## Quick start

```bash
cp .env.example .env                 # add your ANTHROPIC_API_KEY
docker compose build claude-ecs-base
docker compose run --rm claude-ecs-base -p "say hi"
```

`ANTHROPIC_API_KEY` is read from `.env` by Compose; nothing needs exporting. Only the variables listed under `environment` in `docker-compose.yml` reach the container: `ANTHROPIC_API_KEY`, `CLAUDE_PROFILE`, `GITHUB_PERSONAL_ACCESS_TOKEN` and `GITHUB_TOKEN` (the last three are optional). `.env` itself is not passed in, so a new variable has to be added to that list.

Other ways to run it:

```bash
docker compose run --rm claude-ecs-base                       # interactive
docker compose run --rm -T claude-ecs-base -p "..." > out.txt # no TTY, for scripts
docker compose run --rm --entrypoint bash claude-ecs-base     # a shell
```

Building the images without Compose:

```bash
docker build --target ecs-base   -t claude-ecs-base .
docker build --target ecs-deploy -t claude-ecs-deploy \
    --secret id=github_token,env=GITHUB_PERSONAL_ACCESS_TOKEN .   # secret is optional
```

BuildKit is required (it is the default in current Docker).

## Profiles

One image holds every plugin; a **profile** says which ones a run loads. Set `CLAUDE_PROFILE` (default `core`) in the environment, which on ECS is one variable in the task definition:

| Profile | Plugins |
|---|---|
| `core` | superpowers, github, frontend-design, comprehensive-review, security-scanning, python-development, unit-testing, backend-development, python, karpathy-coder |
| `pyvar` | `core` plus fastapi (FastAPI/Alembic scaffolding and migration review) |

```bash
docker compose run --rm -e CLAUDE_PROFILE=pyvar claude-ecs-base -p "say hi"
```

A profile is a plain list, `profiles/<name>.plugins`, one name from `plugins.lock` per line. To add a deployment, add a file; to change a plugin set, edit one. The project being worked on supplies its own `CLAUDE.md` and `.claude/skills`, which load as usual.

Cost limits are not part of a profile: pass them per task, e.g. `-p "…" --max-turns 20 --max-budget-usd 2`. `--bare` is available the same way for a leaner run, but it skips plugins, hooks, skills and `CLAUDE.md` loading, so use it only for tasks that do not need them.

The `github` plugin talks to GitHub's hosted MCP server and needs `GITHUB_PERSONAL_ACCESS_TOKEN` in the container's environment (set it in `.env`; Compose passes it through); without it that one server reports as failed and everything else works. `GITHUB_TOKEN` is read by the `gh` CLI in the image. Use tokens scoped to only the repositories a run needs.

### Models and effort

`claude-config/settings.json` sets the default model (`claude-sonnet-5-5`) and a default effort per model: Sonnet 5.5 `xhigh`, Opus 5.5 `high`, Haiku 5.5 `xhigh`. Haiku 5.5 needs Claude Code 2.1.293 or later, which the pinned `CLAUDE_CODE_VERSION` satisfies.

`max` effort cannot be stored in `settings.json` (`effortLevel` and `modelSettings` accept `low` to `xhigh`). Ask for it per task:

```bash
docker compose run --rm claude-ecs-base -p "..." --model claude-haiku-5-5 --effort max
```

`CLAUDE_CODE_EFFORT_LEVEL=max` also works, but it overrides the stored level for every model in that container. A `--model` or `--effort` after the image name goes to Claude Code like any other argument, including in an ECS command override.

### Pinning and updating plugins

`plugins.lock` lists `NAME REPO SHA PATH` per plugin. To move a pin to the head of its repository's default branch:

```bash
scripts/build/bump-plugin.sh superpowers   # then review the diff and open a PR
```

CI validates every plugin with `claude plugin validate` after the build. To fetch the plugins locally, for example to inspect them: `scripts/build/fetch-plugins.sh plugins.lock /tmp/plugins`.

## Checks

`scripts/ci/smoke-ecs.sh IMAGE [base|deploy]` runs the smoke tests against a built image; no API key needed:

```bash
scripts/ci/smoke-ecs.sh claude-ecs-base:latest base
```

It checks the entrypoint and that an unknown profile is refused, the user, the Python version, the toolchain, that the installed plugins match `plugins.lock` and pass `claude plugin validate`, that every profile only lists installed plugins, and that no credentials were left in the image or its history. `deploy` mode adds the CDK CLI and library, the Stripe CLI and the SSM plugin.

GitHub Actions (`.github/workflows/build-ecs.yml`) builds both targets and runs these checks on pull requests that touch the build inputs. Third-party actions are pinned by commit SHA. If a repository listed in `plugins.lock` ever becomes private, add a repository secret named `PLUGIN_GITHUB_TOKEN`; the build has not needed it so far.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | the two targets |
| `docker-compose.yml` | the `claude-ecs-base` service for local runs |
| `.dockerignore` | allowlist: only the paths the Dockerfile reads enter the build context |
| `plugins.lock` | the plugins in the image, each pinned to a commit |
| `profiles/` | one plugin list per deployment |
| `claude-config/` | user-level Claude Code settings baked into the image |
| `scripts/build/` | `fetch-plugins.sh` (used by the Dockerfile) and `bump-plugin.sh` |
| `scripts/runtime/ecs-claude` | the entrypoint wrapper |
| `scripts/run/run-task.sh` | starts one headless task on ECS, waits, prints logs, exit code and timings (see `docs/runbook.md`) |
| `scripts/run/first-runs.sh` | the first runs against a deployed stack (timings, cost, guardrails) with a report |
| `scripts/run/check-scrub-local.sh` | checks, with `docker compose`, whether Claude Code's credential scrub can run in your Docker (writes a report) |
| `scripts/run/check-scrub-fargate.sh` | the same check in a Fargate task (three tasks, at most USD 1.00; `--push-image` first puts the current image in ECR), through `ecs-in-docker.sh`; writes a report |
| `scripts/run/scrub-verdict.sh` | the scrub probe and the reading of its answers, shared by the two checks above |
| `scripts/deploy/` | `ecs-in-docker.sh` (deploy and run with only Docker on the machine) and `ecs-deploy.sh` (the guarded stack deploy) |
| `docs/runbook.md` | setup, recipes, data handling and troubleshooting for running tasks on ECS |
| `infra/` | CDK app: ECR repository, cluster, network and one task definition per profile (see `infra/README.md`) |
| `scripts/ci/smoke-ecs.sh` | smoke tests, used by CI and runnable locally |

## Status

Done:

- Both images build in CI and pass their smoke tests; profiles select plugins per deployment.
- The `infra/` CDK app is deployed and has run tasks. The reference deployment is ECS on Fargate (arm64, public subnets, no NAT). `docs/runbook.md` has the 16 runs of 2026-10-14 (timings, cost, what each guardrail showed) and the guardrail runs of 2026-10-29.

Known limits, measured (details in `docs/runbook.md`, section 6):

- A command the agent runs can read the API key from its environment. Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` hides it where `bubblewrap` can create namespaces. Neither a Fargate task nor Docker on macOS allowed that in our runs (on a Fargate task and with Docker's default flags `bwrap` cannot create a namespace; with `--cap-add SYS_ADMIN` on macOS it fails later, at `pivot_root`), so the image leaves the scrub off. `scripts/run/check-scrub-local.sh` checks whether your own Docker allows it.
- Outbound HTTPS is open to any host by default; it can be restricted to an allowlist (runbook, section 6).

Not yet run: concurrency and Spot (group G5 of `first-runs.sh`).

The plugin lists in `profiles/` are a first cut and are expected to be reviewed.

The Docker images cannot be built in the environment this repository is developed in, so changes to the Dockerfile are validated by CI rather than locally.
