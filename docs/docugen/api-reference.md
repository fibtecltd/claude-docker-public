# API reference

**Scope.** The repository defines no network API: a search of its Python code found no web framework, route or server code, and the Dockerfile and Compose file expose no ports (`infra/app.py:1-46`, `infra/stacks/claude_ecs_stack.py:1-221`, `Dockerfile:1-175`, `docker-compose.yml:22-41`). What it does define are command-line, environment, file-format and Python interfaces. This reference documents those. An OpenAPI description does not apply.

Placeholders in capitals (`PROFILE`, `TASK_ID`) stand for values you supply.

## 1. Container interface (image `ecs-base`)

The image runs `ecs-claude` as its `ENTRYPOINT` with an empty default `CMD`, so everything after the image name is passed to `claude` (`Dockerfile:134-135`, `scripts/runtime/ecs-claude:2-8`).

### Environment variables read by `ecs-claude`

| Variable | Default | Meaning | Source |
|---|---|---|---|
| `CLAUDE_PROFILE` | `core` | Profile name; must match `^[A-Za-z0-9_-]+$` and name a file `PROFILE.plugins` | `scripts/runtime/ecs-claude:16`, `:21` |
| `ECS_PROFILES_DIR` | `/opt/claude/profiles` | Directory holding profile files | `scripts/runtime/ecs-claude:17` |
| `ECS_PLUGINS_DIR` | `/opt/claude/plugins` | Directory holding plugin directories | `scripts/runtime/ecs-claude:18` |
| `CLAUDE_REPO` | unset | `owner/name` to shallow-clone from github.com | `scripts/runtime/ecs-claude:35-38`, `:53` |
| `CLAUDE_REF` | unset | Branch or tag to clone; characters `A-Za-z0-9_./-`, not starting with `-` | `scripts/runtime/ecs-claude:36`, `:41-44` |
| `ECS_WORKSPACE_DIR` | `/workspace` | Parent of the clone directory `repo` | `scripts/runtime/ecs-claude:45` |
| `GITHUB_TOKEN` | unset | When set, authenticates the clone through a credential helper | `scripts/runtime/ecs-claude:49-54` |

Other variables reach Claude Code, not the wrapper. `ANTHROPIC_API_KEY` is named in `docker-compose.yml:32` and in the ECS secrets (`infra/stacks/claude_ecs_stack.py:207`). The image sets `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_SKIP_ONBOARDING=1`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` and `PYTHONUNBUFFERED=1` (`Dockerfile:128-131`).

### Exit codes of the wrapper

| Code | Cause | Source |
|---|---|---|
| 2 | Unknown or malformed `CLAUDE_PROFILE`; a listed plugin not installed; malformed `CLAUDE_REPO` or `CLAUDE_REF` | `scripts/runtime/ecs-claude:21-25`, `:30-31`, `:37-44` |
| 3 | The shallow clone failed | `scripts/runtime/ecs-claude:54`, `:57` |
| other | Whatever `claude` returns, because the wrapper ends with `exec claude` | `scripts/runtime/ecs-claude:62` |

### Build interface

| Item | Value | Source |
|---|---|---|
| Targets | `ecs-base`, `ecs-deploy` (last stage is the default) | `Dockerfile:36`, `Dockerfile:139` |
| Build argument `CLAUDE_CODE_VERSION` | default `2.1.294` | `Dockerfile:41` |
| Build argument `STRIPE_CLI_VERSION` | default `1.53.0`, `ecs-deploy` only | `Dockerfile:152` |
| BuildKit secret `github_token` | optional; read inside one `RUN` and used for git through environment config | `Dockerfile:89-99` |

### Compose service `claude-ecs-base`

Builds target `ecs-base`, tags it `claude-ecs-base:latest`, runs with `stdin_open` and `tty`, `network_mode: bridge` and `working_dir: /workspace`. Only `ANTHROPIC_API_KEY`, `CLAUDE_PROFILE`, `GITHUB_PERSONAL_ACCESS_TOKEN` and `GITHUB_TOKEN` are passed to the container (`docker-compose.yml:23-41`).

## 2. `scripts/run/run-task.sh`

Starts one headless task on ECS Fargate and waits for it. Usage: `run-task.sh --profile NAME (--prompt TEXT | --prompt-file FILE) --max-turns N --max-budget-usd USD [options] [-- claude args...]` (`scripts/run/run-task.sh:21-22`).

| Option | Required | Meaning | Source |
|---|---|---|---|
| `--profile NAME` | yes | Profile name; task definition `claude-ecs-NAME` | `:25`, `:82` |
| `--prompt TEXT` or `--prompt-file FILE` | one of them | Passed as `claude -p`; not both | `:26-27`, `:83-88` |
| `--max-turns N` | yes | Whole number | `:28`, `:89` |
| `--max-budget-usd USD` | yes | Number | `:29`, `:90` |
| `--model ID` | no | Default is the image's default | `:32` |
| `--effort LEVEL` | no | `low`, `medium`, `high`, `xhigh` or `max` | `:33`, `:91` |
| `--output-format FMT` | no | `text`, `json` or `stream-json` | `:34`, `:92` |
| `--repo OWNER/NAME`, `--ref BRANCH_OR_TAG` | no | Sets `CLAUDE_REPO` and `CLAUDE_REF`; `--ref` needs `--repo` | `:35-36`, `:93`, `:125-127` |
| `--env NAME=VALUE` | no, repeatable | Extra container environment variable; visible to anyone who can call `ecs:DescribeTasks`, so no secrets | `:37-38`, `:95-97` |
| `--spot` | no | Use `FARGATE_SPOT` instead of `FARGATE` | `:39`, `:130` |
| `--timeout SECONDS` | no | Wait limit, default 1800 | `:40`, `:94` |
| `--no-wait` | no | Print the task ARN and exit | `:41`, `:181-184` |
| `--dry-run` | no | Print the request as JSON, start nothing | `:42`, `:163-166` |
| `-- ARGS` | no | Everything after is passed to `claude` unchanged | `:43`, `:77` |
| `-h`, `--help` | no | Usage | `:76` |

**Environment.** `CLAUDE_ECS_STACK` (default `claude-ecs`), `CLAUDE_ECS_POLL_SECONDS` (default 10), and `CLAUDE_ECS_CLUSTER`, `CLAUDE_ECS_SUBNETS` (comma separated), `CLAUDE_ECS_SECURITY_GROUP`, `CLAUDE_ECS_ASSIGN_PUBLIC_IP`. Setting all four of the last group skips the CloudFormation lookup (`scripts/run/run-task.sh:45-49`, `:104-113`).

**Stack outputs read.** `ClusterName`, `SubnetIds`, `SecurityGroupId`, `AssignPublicIp` (`scripts/run/run-task.sh:109-112`).

**Arguments given to `claude`, in order.** `-p PROMPT --max-turns N --max-budget-usd USD`, then `--model`, `--effort`, `--output-format` when set, then the arguments after `--` (`scripts/run/run-task.sh:119-123`).

**Request shape.** `cluster`, `taskDefinition` (`claude-ecs-PROFILE`), `count` 1, `startedBy` `claude-ecs-run-task`, a one-entry `capacityProviderStrategy` with weight 1, `networkConfiguration.awsvpcConfiguration` (`subnets`, `securityGroups`, `assignPublicIp`), and `overrides.containerOverrides` for the container named `claude` with `command` and `environment` (`scripts/run/run-task.sh:140-157`). The overrides must be 8000 characters or fewer (`scripts/run/run-task.sh:17`, `:159-161`).

**Output.** Task status changes, then logs from group `/claude-ecs` stream `PROFILE/claude/TASK_ID`, then a summary of stop reason, container exit code and four timings: provisioning, image pull, start-up and run (`scripts/run/run-task.sh:16`, `:186-233`).

**Exit codes.**

| Code | Cause | Source |
|---|---|---|
| 0 | `--help`, `--dry-run`, or `--no-wait` after a successful start; also a container that exited 0 | `:76`, `:165`, `:183`, `:233` |
| 1 | ECS did not start the task, or the container reported no exit code | `:174-178`, `:232` |
| 2 | Argument or stack-output error (`die`) | `:53` |
| 124 | The task was still not `STOPPED` at the timeout | `:194-198` |
| other | The container's exit code | `:233` |

## 3. Deployment scripts

### `scripts/deploy/ecs-deploy.sh [--config FILE] COMMAND`

Run under your own AWS identity. It never runs `cdk bootstrap`. Every check prints GO, NO-GO or UNKNOWN (`scripts/deploy/ecs-deploy.sh:5-14`).

| Command | Does | Source |
|---|---|---|
| `preflight` | Read-only account checks: identity, names free, bootstrap, template tags, Fargate headroom, VPCs, pipelines, budgets, organization, tag convention; writes the baseline file. Returns 1 on any NO-GO, 2 when only UNKNOWN | `:374-400` |
| `stack` | Preflight, `cdk diff` that may only create resources, confirmation, `cdk deploy` | `:404-453` |
| `image` | Builds `ecs-base` for the configured architecture, smoke-tests it, pushes `latest` and the short git SHA | `:461-477` |
| `secret` | Reads a key without echo, requires the `sk-ant-` prefix, stores it in secret `claude-ecs/anthropic-api-key` | `:480-493` |
| `verify` | Compares the account with the baseline; checks stack status, tags and images | `:496-531` |

Anything else prints usage and returns 2; missing `aws`, `jq` or `awk` also returns 2 (`scripts/deploy/ecs-deploy.sh:544-550`).

Settings come from the environment or a shell file passed with `--config` (`scripts/deploy/ecs-deploy.sh:15`, `:68-90`):

| Setting | Default | Meaning |
|---|---|---|
| `AWS_REGION` | required | Region |
| `EXPECTED_ACCOUNT` | empty | NO-GO when credentials belong to another account |
| `FORBIDDEN_PRINCIPAL_REGEX` | empty | NO-GO when the caller ARN matches |
| `TAGS_JSON` | `{"Project":"claude-ecs"}` | Tags for every resource; must be a non-empty JSON object |
| `EGRESS` | `public` | `public` or `nat` |
| `CPU_ARCH` | `ARM64` | `ARM64` or `X86_64` |
| `RESERVED_VCPU` | `0` | Fargate vCPU other workloads may need at peak |
| `MIN_FREE_VCPU` | `4` | vCPU that must stay free after that |
| `BUDGET_ALERT_PCT` | `80` | NO-GO at or above this percentage; `0` lists budgets and never blocks |
| `WATCH_PIPELINE_PREFIX` | empty | CodePipeline names to watch |
| `ALLOW_UNKNOWN` | `0` | `1` lets `stack` continue past UNKNOWN |
| `ASSUME_YES` | `0` | `1` skips confirmations; needs `EXPECTED_ACCOUNT` |
| `BASELINE_FILE` | `.ecs-deploy-baseline.json` in the repository | Baseline location |
| `DIFF_FILE` | `.ecs-deploy-diff.txt` in the repository | Where `stack` keeps the diff |

### `scripts/deploy/ecs-in-docker.sh [--config FILE] [--use-env-key] COMMAND [args]`

For a machine with Docker but no AWS CLI, CDK or Node. Commands: `deploy`, `runs`, `preflight`, `stack`, `secret`, `image`, `verify`, `identity`, `shell`, `exec CMD...` (`scripts/deploy/ecs-in-docker.sh:11-22`, `:283-304`).

| Option | Meaning | Source |
|---|---|---|
| `--config FILE` | Settings file inside the repository (default `scripts/private/fibtec.env` when present) | `:25`, `:65-74` |
| `--env-file FILE` | Read keys from `KEY=value` lines when not exported | `:26` |
| `--use-env-key` | Store `$ANTHROPIC_API_KEY` instead of asking | `:27` |
| `--yes`, `-y` | No typed account id and no CDK y/n on IAM changes | `:29-32`, `:277` |
| `--strict` | Stop on UNKNOWN preflight checks too | `:33-35`, `:278` |

The host needs `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (plus `AWS_SESSION_TOKEN` for temporary credentials), exported or in an env file (`scripts/deploy/ecs-in-docker.sh:37-41`). Unknown commands print usage and return 2 (`scripts/deploy/ecs-in-docker.sh:283-286`).

## 4. Experiment and probe scripts

### `scripts/run/first-runs.sh`

`first-runs.sh [--config FILE] [--all | --groups G1,G3] [--max-total-usd N] [--report FILE] [--dry-run]` (`scripts/run/first-runs.sh:5-6`, `:94-104`). By default it runs the quick set `G1-cold`, `G1-warm`, `G3-pyvar-read`, `G4-budget-cap`, `G4-role-egress` (`scripts/run/first-runs.sh:110`). `--all` selects `G1` to `G5`; `--groups` takes a comma-separated list from `G1` to `G5` (`scripts/run/first-runs.sh:97`, `:107`). `--max-total-usd` defaults to 5 and the report to `first-runs-report.md` in the repository (`scripts/run/first-runs.sh:93`). Exit 0 when every run was executed and the controls hold; the containers' own exit codes are results in the report (`scripts/run/first-runs.sh:32-33`).

### `scripts/run/check-scrub-local.sh`

`check-scrub-local.sh [--no-build] [--no-control] [--report FILE]`. Runs a five-command probe three ways against the `claude-ecs-base` service: scrub on with default flags, scrub on with `--cap-add SYS_ADMIN`, and a scrub-off control. Each run is capped at 10 turns and USD 0.30. Exit codes: 0 report written, 1 image did not build, 2 a prerequisite is missing (`scripts/run/check-scrub-local.sh:5-30`, `:40`, `:45-50`).

### `scripts/run/check-scrub-fargate.sh`

`check-scrub-fargate.sh [--push-image] [--no-control] [--profile NAME] [--report FILE]`. Starts three tasks (`ON`, `CONTROL`, `BWRAP`) on the stack through `ecs-in-docker.sh`, at most USD 1.00 in total. Exit codes: 0 report written, 1 image did not build or push, 2 a prerequisite is missing (`scripts/run/check-scrub-fargate.sh:5-33`, `:50-60`).

### `scripts/run/scrub-verdict.sh`

Sourced, not run. It provides `scrub_probe_prompt`, `classify`, `works`, `state`, `forms_failed` and `verdict_line`. A run is classified `works`, `visible`, `partly` or `blocked` (`scripts/run/scrub-verdict.sh:17`, `:36`, `:79-86`, `:88`).

## 5. Build and CI scripts

| Script | Usage | Behavior | Source |
|---|---|---|---|
| `scripts/build/fetch-plugins.sh LOCK DEST` | Used by the Dockerfile; runnable locally | Fetches each plugin at its pinned commit without git metadata; fails on a bad lock line, short SHA, name mismatch or duplicate | `scripts/build/fetch-plugins.sh:8-46` |
| `scripts/build/bump-plugin.sh NAME [LOCK]` | Run, then review the diff | Moves every entry sharing the plugin's repository and commit to the head of the default branch | `scripts/build/bump-plugin.sh:5-26` |
| `scripts/ci/smoke-ecs.sh IMAGE [base or deploy]` | Default mode `base`; needs no API key | Checks entrypoint, profile and repo refusal (exit 2), uid 1001, Python 3.12, tools, settings-only user config, scrub off by default, plugins match the lock and validate, no credentials in the image | `scripts/ci/smoke-ecs.sh:9-119` |

## 6. File formats

### `plugins.lock`

One plugin per line: `NAME REPO SHA PATH`. `NAME` must equal the `name` in the plugin's `.claude-plugin/plugin.json`; `SHA` is a full commit; `PATH` is the plugin directory in the repository, `.` when the repository is the plugin. Lines starting with `#` and blank lines are ignored (`plugins.lock:1-10`, `scripts/build/fetch-plugins.sh:19-26`).

### `profiles/NAME.plugins`

One plugin name from `plugins.lock` per line; `#` comments and blank lines ignored (`profiles/core.plugins:1-2`, `scripts/runtime/ecs-claude:29`). Adding a file adds a profile and, on the next deploy, a task definition (`infra/README.md:18`, `infra/stacks/claude_ecs_stack.py:75-80`).

## 7. CDK interface (`infra/`)

### Context keys

Passed as `-c key=value`, or as `CDK_CONTEXT_JSON` when running `python app.py` (`infra/README.md:33`). Read in `infra/app.py:24-34`.

| Key | Default | Accepted values | Source |
|---|---|---|---|
| `egress` | `public` | `public`, `nat` | `infra/stacks/claude_ecs_stack.py:22`, `:48`, `:59-60` |
| `image_tag` | `latest` | any string | `infra/stacks/claude_ecs_stack.py:49` |
| `cpu` | `1024` | integer; CDK rejects invalid Fargate combinations | `infra/stacks/claude_ecs_stack.py:50`, `infra/README.md:39` |
| `memory_mib` | `4096` | integer | `infra/stacks/claude_ecs_stack.py:51` |
| `ephemeral_storage_gib` | `30` | 20 to 200 | `infra/stacks/claude_ecs_stack.py:52`, `:66-67` |
| `cpu_architecture` | `X86_64` | `X86_64`, `ARM64` | `infra/stacks/claude_ecs_stack.py:23`, `:53`, `:61-65` |
| `github_token` | `false` | `1`, `true`, `yes` (case-insensitive) mean true | `infra/app.py:18-20`, `infra/stacks/claude_ecs_stack.py:54` |
| `tags` | `{"Project": "claude-ecs"}` | JSON string or object; at most 50; key not empty and not `aws:*`; value not empty | `infra/stacks/claude_ecs_stack.py:33-34`, `:68-72`, `infra/app.py:32` |

Invalid values raise `ValueError` from `Settings.__post_init__` (`infra/stacks/claude_ecs_stack.py:58-72`).

### Python surface of `infra/stacks/claude_ecs_stack.py`

| Name | Signature | Behavior | Line |
|---|---|---|---|
| `Settings` | frozen dataclass with `egress`, `image_tag`, `cpu`, `memory_mib`, `ephemeral_storage_gib`, `cpu_architecture`, `github_token`, `tags`, `profiles` | Validates in `__post_init__` | `:44-72` |
| `parse_tags` | `parse_tags(value) -> tuple[tuple[str, str], ...]` | Accepts a JSON string or a mapping | `:37-41` |
| `profile_names` | `profile_names(profiles_dir=PROFILES_DIR) -> tuple[str, ...]` | Sorted stems of `*.plugins`; `ValueError` when none | `:75-80` |
| `ClaudeEcsStack` | `ClaudeEcsStack(scope, construct_id, *, settings, **kwargs)` | Builds all resources; helpers `_network` and `_secrets` | `:83-220` |

### Stack outputs

`RepositoryUri`, `ClusterName`, `SubnetIds`, `SecurityGroupId`, `AssignPublicIp` (`ENABLED` for `public`, `DISABLED` for `nat`) and `TaskDefinitionFamilies` (comma-separated) (`infra/stacks/claude_ecs_stack.py:156-162`).

## Sources

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
scripts/run/check-scrub-local.sh
scripts/run/check-scrub-fargate.sh
scripts/run/scrub-verdict.sh
scripts/deploy/ecs-deploy.sh
scripts/deploy/ecs-in-docker.sh
infra/app.py
infra/stacks/claude_ecs_stack.py
infra/README.md
