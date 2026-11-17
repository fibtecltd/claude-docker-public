# Onboarding guide

This guide gets a new contributor from a fresh checkout to a first change. It describes the repository as the source documents it. The commands below are copied from the repository's own documentation and scripts; they were not run while writing this guide, because the session could only read the source.

Read the [architecture overview](architecture.md) for how the parts fit together and the [API reference](api-reference.md) for every option and variable.

## 1. What this repository is

It builds Docker images that run Claude Code headlessly and a CDK app plus scripts that run them as one-off tasks on AWS ECS Fargate (`README.md:3`). The reference deployment is ECS on Fargate with public subnets and no NAT (`README.md:134`). Nothing runs until someone starts a task: there is no ECS service and no schedule (`infra/README.md:3`).

The repository is also an export. The maintainers keep the source in a private repository and a script copies it here, so a change merged here must be applied upstream before the next export, or it would be undone (`CONTRIBUTING.md:3-17`). Files that exist only here (`LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`, the issue templates and `articles/`) are edited directly (`CONTRIBUTING.md:18-19`).

## 2. Repository tour

| Path | What to know | Source |
|---|---|---|
| `Dockerfile` | Two targets, `ecs-base` and `ecs-deploy` | `README.md:9-12` |
| `docker-compose.yml` | The `claude-ecs-base` service for local runs | `docker-compose.yml:23-41` |
| `scripts/runtime/ecs-claude` | The container entrypoint | `README.md:118` |
| `plugins.lock`, `profiles/` | Which plugins are in the image, and which a run loads | `README.md:114-115` |
| `claude-config/settings.json` | The only user-level Claude Code file baked into the image | `README.md:20` |
| `scripts/build/` | `fetch-plugins.sh` and `bump-plugin.sh` | `README.md:117` |
| `scripts/run/` | `run-task.sh`, `first-runs.sh`, the scrub checks | `README.md:119-123` |
| `scripts/deploy/` | `ecs-deploy.sh` and `ecs-in-docker.sh` | `README.md:124` |
| `scripts/ci/smoke-ecs.sh` | Image smoke tests, used by CI and runnable locally | `README.md:127` |
| `infra/` | The CDK app; `infra/README.md` documents it | `README.md:126` |
| `docs/runbook.md` | Setup, recipes, measurements, data handling, troubleshooting | `README.md:125` |
| `articles/` | Long-form write-ups and HTML copies; not code | `CONTRIBUTING.md:18-19` |

## 3. Prerequisites

Which tools you need depends on what you change.

| To do this | You need | Source |
|---|---|---|
| Build and run the image locally | Docker with BuildKit (the default in current Docker) and Compose; an `ANTHROPIC_API_KEY` to run a real prompt | `README.md:28-31`, `README.md:52` |
| Test the CDK app | Python 3 with a venv; `infra/requirements-dev.txt` installs `aws-cdk-lib`, `constructs`, `pytest` and `cfn-lint` | `infra/README.md:73-79`, `infra/requirements.txt:1-2`, `infra/requirements-dev.txt:1-3` |
| Lint the shell scripts | `shellcheck`, which CI runs over every script | `.github/workflows/infra.yml:70-71`, `CONTRIBUTING.md:36` |
| Start tasks on ECS | AWS CLI (v1 or v2) with credentials, and `jq` | `docs/runbook.md:28` |
| Deploy with only Docker on the machine | Docker and AWS credentials, through `ecs-in-docker.sh` | `docs/runbook.md:9-16`, `scripts/deploy/ecs-in-docker.sh:7-9` |

The README notes that the Docker images cannot be built in the environment the maintainers develop in, so Dockerfile changes are validated by CI (`README.md:145`).

## 4. First hour

### 4.1 Run the image locally

```bash
cp .env.example .env                 # add your ANTHROPIC_API_KEY
docker compose build claude-ecs-base
docker compose run --rm claude-ecs-base -p "say hi"
```

(`README.md:28-32`.) Compose reads `ANTHROPIC_API_KEY` from `.env`. Only the variables listed under `environment` in `docker-compose.yml` reach the container, and `.env` itself is not passed in, so a new variable must be added to that list (`README.md:34`, `docker-compose.yml:31-38`). `.env` is git-ignored (`.gitignore:1`). Do not put a real key anywhere else in the repository.

To choose a profile: `docker compose run --rm -e CLAUDE_PROFILE=pyvar claude-ecs-base -p "say hi"` (`README.md:64`).

### 4.2 Run the smoke tests

```bash
scripts/ci/smoke-ecs.sh claude-ecs-base:latest base
```

(`README.md:100`.) No API key is needed. The script checks that the entrypoint passes arguments to `claude`, that an unknown profile exits 2, the user, the Python version, the toolchain, that installed plugins match `plugins.lock` and pass `claude plugin validate`, and that no credentials are left in the image or its history (`README.md:103`, `scripts/ci/smoke-ecs.sh:27-117`). Use mode `deploy` for the `ecs-deploy` image (`scripts/ci/smoke-ecs.sh:98-107`).

### 4.3 Run the CDK tests

```bash
cd infra
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
CDK_OUTDIR=/tmp/out .venv/bin/python app.py
.venv/bin/cfn-lint /tmp/out/claude-ecs.template.json
```

(`infra/README.md:73-79`.) The tests assert on the synthesized template, so they need no AWS account (`infra/tests/test_claude_ecs_stack.py:14-18`, `.github/workflows/infra.yml:3-6`).

### 4.4 See a task request without starting a task

```bash
CLAUDE_ECS_CLUSTER=claude-ecs CLAUDE_ECS_SUBNETS=subnet-a,subnet-b \
CLAUDE_ECS_SECURITY_GROUP=sg-1 CLAUDE_ECS_ASSIGN_PUBLIC_IP=ENABLED \
scripts/run/run-task.sh --profile core --prompt "hi" \
    --max-turns 1 --max-budget-usd 0.25 --dry-run
```

This mirrors the CI step that builds a request with stub values and no AWS calls (`.github/workflows/infra.yml:86-100`). `--max-turns` and `--max-budget-usd` are required on every run: without them the script refuses (`scripts/run/run-task.sh:89-90`, `.github/workflows/infra.yml:101-103`).

## 5. Common changes

### Add a profile

Create `profiles/NAME.plugins` with one plugin name from `plugins.lock` per line. The CDK app adds a task definition `claude-ecs-NAME` on the next deploy, and `run-task.sh --profile NAME` can then target it (`README.md:67`, `infra/README.md:18`, `infra/stacks/claude_ecs_stack.py:75-80`, `:131-136`). The smoke test fails if a profile lists a plugin that is not installed (`scripts/ci/smoke-ecs.sh:85-95`). `first-runs.sh` only allows the `core` and `pyvar` profiles (`scripts/run/first-runs.sh:44`).

### Add or move a plugin pin

Add a line `NAME REPO SHA PATH` to `plugins.lock`, with a full 40-character SHA and a `NAME` equal to the plugin's own manifest name (`scripts/build/fetch-plugins.sh:21-24`, `:38-40`). To move an existing pin to the head of its repository: `scripts/build/bump-plugin.sh NAME`, then review the diff and open a PR; CI validates every plugin (`README.md:87-93`). A plugin that is in the lock but in no profile is installed and never loaded (`plugins.lock:23`, `profiles/core.plugins:3-12`).

### Change an infrastructure setting

Defaults and validation live in the `Settings` dataclass; the context keys are read in `infra/app.py` (`infra/stacks/claude_ecs_stack.py:44-72`, `infra/app.py:24-34`). Add a test in `infra/tests/test_claude_ecs_stack.py`, which already parametrizes invalid settings (`infra/tests/test_claude_ecs_stack.py:204-219`). Switching `egress` replaces the subnets and adds or removes the NAT gateway, so do it between runs (`infra/README.md:27`).

### Change the image

Edit the `Dockerfile` and check that it builds and that `smoke-ecs.sh IMAGE base` passes; CI does both on pull requests that touch the build inputs (`CONTRIBUTING.md:37-39`, `.github/workflows/build-ecs.yml:20-32`). The build context is an allowlist, so a new file the Dockerfile reads must also be added to `.dockerignore` (`.dockerignore:4-9`).

### Change Claude Code defaults

Edit `claude-config/settings.json`: the default model, effort per model and permission mode (`claude-config/settings.json:7-30`). The README explains that `max` effort cannot be stored there and is passed per task with `--effort max` (`README.md:77-81`).

## 6. Deploying and operating (for those with an AWS account)

Deployments are done by a person, not by CI (`infra/README.md:47`). The documented routes:

- Only Docker on the machine: `scripts/deploy/ecs-in-docker.sh deploy --use-env-key`, then `scripts/deploy/ecs-in-docker.sh runs` (`docs/runbook.md:11-14`). It needs a settings file; the default path is `scripts/private/fibtec.env` and the file must be inside the repository (`scripts/deploy/ecs-in-docker.sh:25`, `:64-74`).
- By hand: follow `infra/README.md` (bootstrap, `cdk deploy`, secrets, image push) (`docs/runbook.md:18`).

Things that regularly surprise people, all stated in the source:

- **Architecture must match.** The image platform must match `cpu_architecture`. The CDK default is `X86_64`, while `ecs-deploy.sh` defaults to `ARM64` and passes it to CDK (`infra/README.md:67`, `infra/stacks/claude_ecs_stack.py:53`, `scripts/deploy/ecs-deploy.sh:78`, `:93`). A mismatch shows up as `exec format error` (`docs/runbook.md:143`).
- **The key starts as a placeholder.** The stack creates the secret with a placeholder value; replace it with `aws secretsmanager put-secret-value` or the `secret` command. A `401` or `invalid x-api-key` in the logs means the placeholder is still there (`infra/README.md:59-60`, `docs/runbook.md:146`). Use a new key with its own spend limit (`scripts/deploy/ecs-deploy.sh:482-483`).
- **Do not switch the credential scrub on in a Fargate task.** `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` runs every command through `bubblewrap`, which could not create a namespace in a task, so every command is blocked (`Dockerfile:115-127`, `README.md:22`).
- **Overrides are small.** The prompt and settings in a task request must be under 8192 characters; the script enforces 8000 (`docs/runbook.md:136`, `scripts/run/run-task.sh:17`, `:159-161`).
- **Cost caps belong to the task.** Pass `--max-turns` and `--max-budget-usd` every time. Set the budget above the starting context: a cold run can cost more than a very small cap, and a cap stops the run after the turn that crosses it (`docs/runbook.md:115`).
- **Start-up takes about 30 seconds.** The runbook measured about 32 s to start and no warm start (`docs/runbook.md:110-111`).
- **Logs go to CloudWatch.** Group `/claude-ecs`, stream `PROFILE/claude/TASK_ID`, kept 30 days (`docs/runbook.md:78`, `scripts/run/run-task.sh:216`).

## 7. When something fails

The runbook has a symptom table covering `exec format error`, `CannotPullContainerError`, secret errors, exit codes 1 and 3, no Fargate capacity and missing stack outputs (`docs/runbook.md:139-149`). Exit code 2 from the container is a wrapper configuration error and 3 is a failed clone (`docs/runbook.md:79`, `scripts/runtime/ecs-claude:25`, `:54`).

## 8. Sending a change

- Open a pull request as usual; a maintainer applies accepted changes to the private source before the next export (`CONTRIBUTING.md:10-17`).
- Checklist: nothing unfit for a public audience (no credentials, account ids, internal names or personal data); shell changes pass `shellcheck`; Dockerfile or pin changes build and pass the smoke test; `cd infra && python -m pytest` passes for infra changes; commit messages say what and why (`CONTRIBUTING.md:34-41`).
- Report security issues privately using the contact in `SECURITY.md`, not in a public issue (`SECURITY.md:11-21`).
- Generated files stay out of Git: `.env`, `infra/cdk.out/`, `infra/.venv/`, `.ecs-deploy-baseline.json`, `first-runs-report.md`, `scrub-check-*.md` and `.ecs-deploy-diff.txt` (`.gitignore:1-10`).

## 9. Where to read next

1. `README.md`, for images, profiles, models and the status section.
2. `infra/README.md`, for resources, egress modes and settings.
3. `docs/runbook.md`, for running tasks, measured timings and cost, the credential-scrub findings, data handling and troubleshooting.
4. The scripts' own header comments: `ecs-deploy.sh`, `ecs-in-docker.sh` and `first-runs.sh` print them with `--help` (`scripts/deploy/ecs-deploy.sh:45`, `scripts/deploy/ecs-in-docker.sh:58`, `scripts/run/first-runs.sh:48`).

## Sources

README.md
CONTRIBUTING.md
SECURITY.md
.gitignore
.dockerignore
.env.example
Dockerfile
docker-compose.yml
plugins.lock
profiles/core.plugins
claude-config/settings.json
scripts/runtime/ecs-claude
scripts/build/fetch-plugins.sh
scripts/build/bump-plugin.sh
scripts/ci/smoke-ecs.sh
scripts/run/run-task.sh
scripts/run/first-runs.sh
scripts/deploy/ecs-deploy.sh
scripts/deploy/ecs-in-docker.sh
infra/README.md
infra/requirements.txt
infra/requirements-dev.txt
infra/stacks/claude_ecs_stack.py
infra/app.py
infra/tests/test_claude_ecs_stack.py
.github/workflows/build-ecs.yml
.github/workflows/infra.yml
docs/runbook.md
