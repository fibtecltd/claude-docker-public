# Runbook: running headless Claude Code tasks on ECS

`scripts/run/run-task.sh` starts one task, waits for it, then prints its logs, its exit code and where the time went. This runbook covers the setup it needs and what to expect.

**Status:** deployed and run on 2026-10-14 (eu-west-1, Fargate on arm64, public IPs, no NAT): five runs, then eleven with cost capture (groups G1-G4). All 16 behaved as designed. Concurrency and Spot (group G5, `first-runs.sh --all`) have not been run.

## 1. One-time setup

**Fast path, with only Docker on the machine.** Have the AWS credentials of the account exported, or in a `.env` file in the repository (or `--env-file FILE`), then:

```bash
scripts/deploy/ecs-in-docker.sh deploy --use-env-key   # build, smoke test, checks, stack, key, image, verify
scripts/deploy/ecs-in-docker.sh runs                   # the quick set of 5 runs; add --all for all 15; prints a report
```

`deploy` stops on any NO-GO, asks for the account id and for a y/n on the IAM changes, and can be run again (a deployed stack and a stored key are skipped). `--use-env-key` stores `$ANTHROPIC_API_KEY`; leave it out to be asked. `runs` makes 5 runs by default (cold and warm start, a read-only question about pyvar, the spend cap, the task role, the egress rules and what a command can see of the API key; caps add up to USD 2.05) or 15 with `--all` (USD 4.55; it refuses to start over USD 5). It ends with a markdown report of timings, guardrail evidence and a Quality section: the pyvar answer scored against six facts from the real code, and whether each run behaved as designed. Both run the AWS and CDK work in a container, so the machine needs no AWS CLI. Details: `scripts/deploy/ecs-in-docker.sh --help`.

**By hand.** Follow `infra/README.md` (bootstrap, `cdk deploy`, secrets, image push) and check:

```bash
aws cloudformation describe-stacks --stack-name claude-ecs --query 'Stacks[0].Outputs'
aws ecs list-task-definitions --family-prefix claude-ecs
aws ecr describe-images --repository-name claude-ecs --query 'imageDetails[].imageTags'
```

You need one task definition per profile in `profiles/` (`claude-ecs-core`, `claude-ecs-pyvar`, and any profile you add), an image tagged `latest` (or your `image_tag`) built for the architecture you deployed, and the real API key in `claude-ecs/anthropic-api-key`. For private repositories deploy with `-c github_token=true` and put a token in `claude-ecs/github-token`.

Requirements on your machine for `run-task.sh`: AWS CLI (v1 or v2) with credentials for the account and region, and `jq`. The `ecs-in-docker.sh` route needs only Docker.

## 2. First run

```bash
scripts/run/run-task.sh --profile core --prompt "Reply with exactly: ok" \
    --max-turns 1 --max-budget-usd 0.25
```

`--max-turns` and `--max-budget-usd` are required on every run: limits belong to the task, not the profile. Add `--dry-run` to print the exact request without starting anything.

## 3. Model matrix (rate-limit evidence)

The quickest way is `scripts/deploy/ecs-in-docker.sh runs --groups G2` (six runs, caps add up to USD 1.50): it prints the models side by side with start-up, run time, turns and what each cost. By hand, run the same trivial prompt against each model and compare with what you see from other paths:

```bash
for m in claude-sonnet-5-5 claude-opus-5-5 claude-sonnet-5 claude-opus-5 claude-haiku-5-5; do
  echo "== $m"
  scripts/run/run-task.sh --profile core --prompt "say hi" --model "$m" \
      --max-turns 1 --max-budget-usd 0.5 || true
done
```

A 429 shows up in the task logs and a non-zero exit code.

## 4. Recipes

```bash
# A task inside a repository (its CLAUDE.md and .claude/ are loaded)
scripts/run/run-task.sh --profile pyvar --repo fibtecltd/pyvar --ref master \
    --prompt "Describe how engine/montecarlo.py draws its random numbers" \
    --max-turns 15 --max-budget-usd 2

# Haiku 5.5 at maximum effort (max cannot be stored in settings.json)
scripts/run/run-task.sh --profile core --prompt "..." \
    --model claude-haiku-5-5 --effort max --max-turns 10 --max-budget-usd 1

# Fargate Spot (cheaper; can be interrupted) and machine-readable output
scripts/run/run-task.sh --profile core --prompt "..." --spot --output-format json \
    --max-turns 10 --max-budget-usd 1

# Anything else for claude goes after --
scripts/run/run-task.sh --profile core --prompt "..." --max-turns 10 --max-budget-usd 1 \
    -- --append-system-prompt "Answer in one paragraph."
```

`--repo` makes the image shallow-clone `OWNER/NAME` (a branch or tag with `--ref`, not a commit) into `/workspace/repo` and start Claude Code there. It uses `GITHUB_TOKEN` when the secret is configured. ECS cannot override an entrypoint at run time, which is why this is done by environment variables (`CLAUDE_REPO`, `CLAUDE_REF`) read by `ecs-claude`.

## 5. Reading the result

- **Logs:** CloudWatch group `/claude-ecs`, stream `<profile>/claude/<task id>`, kept 30 days. The script prints them once the task stops.
- **Exit code:** the script exits with the container's exit code. Exit 2 is a configuration error in the wrapper (unknown profile, bad `CLAUDE_REPO`), 3 is a failed clone, anything else is Claude Code's own.
- **Timings:** the summary splits the wall time into provisioning, image pull, start-up and run. Start-up (created to running) is the cost of choosing Fargate over Lambda; record it here after the first runs:

| Date | Profile | Provisioning | Image pull | Start-up | Run | Note |
|---|---|---|---|---|---|---|
| 2026-10-14 | core | 11 s | 16 s | 30 s | 30 s | first task after the image push, answer `ok` |
| 2026-10-14 | core | 17 s | 14 s | 36 s | 30 s | second task, same prompt |
| 2026-10-14 | pyvar | 12 s | 16 s | 32 s | 41 s | clones `fibtecltd/pyvar` at `master`, answers a question about `engine/montecarlo.py` |
| 2026-10-14 | pyvar | 14 s | 15 s | 33 s | 37 s | stopped by `--max-budget-usd 0.05` (exit 1) |
| 2026-10-14 | core | 12 s | 15 s | 32 s | 53 s | four shell commands, one of them waiting out an 8 s curl timeout |

The second set of eleven runs (`first-runs.sh --groups G1,G2,G3,G4`, cost taken from Claude Code's `total_cost_usd`, the Anthropic API only):

| Run | Model | Start-up | Run | Turns | Cost (USD) |
|---|---|---|---|---|---|
| one-word answer, first | default (Sonnet 5.5) | 32 s | 29 s | 1 | 0.0955 |
| same, again | default | 31 s | 28 s | 1 | 0.0077 |
| one-word, per model | Sonnet 5.5 | 34 s | 28 s | 1 | 0.0077 |
| | Opus 5.5 | 33 s | 28 s | 1 | 0.1893 |
| | Sonnet 5 | 30 s | 28 s | 1 | 0.1270 |
| | Opus 5 | 34 s | 29 s | 1 | 0.2450 |
| | Haiku 5.5 | 32 s | 30 s | 1 | 0.0049 |
| | Haiku 5.5, effort `max` | 35 s | 30 s | 1 | 0.0018 |
| question about pyvar (clone) | default | 32 s | 42 s | 3 | 0.1615 |
| capped at USD 0.05 | default | 31 s | 35 s | 3 | 0.0680 |
| role and egress commands | default | 31 s | 49 s | 5 | 0.0803 |

Total: USD 0.9887 for the eleven, against caps that add up to USD 3.55. Fargate time is billed separately by AWS.

What the sixteen runs show (one sample each, so read them as orders of magnitude):

- **Start-up is about 32 s** (30-36 s over all 16 runs): roughly 13 s of provisioning, 15 s of image pull and a few seconds to start the container. A trivial one-word task takes about a minute from `run-task.sh` to exit.
- **There is no warm start.** Fargate pulls the image for every task; the second run was not faster than the first.
- **The run phase of a one-word answer is 28-30 s on every model**, Haiku 5.5 at effort `max` and Opus 5 included, so it is not model latency. The capped run reported its own session time (`duration_ms`) as 7.7 s inside a 35 s run phase: most of the run phase is outside the model session (Claude Code starting with the profile's plugins, the repository clone, exit).
- **What a run costs is mostly its starting context.** For the capped run, Claude Code reported 671 output tokens, 26,641 tokens read from the prompt cache and 22,395 written to it. At $2 / $10 per million for Sonnet 5.5, with cache writes at 1.25x and cache reads at 0.1x, that is USD 0.0067 of output, 0.0053 of cache reads and 0.0560 of cache writes, which adds up to the reported 0.0680 to four decimals: 82% of the cost was writing the context, 10% was the answer. Anthropic's pricing page lists Sonnet 5.5 cache reads at 0.05x, and `total_cost_usd` is a client-side estimate from Claude Code's own price table, so at the page's rates (five-minute cache writes) the same tokens come to USD 0.0654, with cache writes 86% of it.
- **The first call pays for the cache, later calls do not.** One-word answer on Sonnet 5.5: USD 0.0955 for the first run, 0.0077 for each later one a few minutes after. In the per-model rows, Sonnet 5.5 and Haiku 5.5 at `max` were second calls on their model; the others were first calls, so the six costs mix cache states and show the order of magnitude per model, not a like-for-like price.
- **Set a cap above the starting context.** A cold one-word run on Sonnet 5.5 cost more than the USD 0.05 cap used for the cap test, so with a cold cache that cap trips on any task on this profile. The run stopped at USD 0.0680, 36% over the cap: a cap ends the run after the turn that crosses it, not to the cent.
- **The spend cap works:** `subtype: error_max_budget_usd`, `terminal_reason: budget_exhausted`, "Reached maximum budget ($0.05)", exit 1.
- **No rate limits:** all six models answered with exit 0.
- **Network and role:** from inside a task, `sts get-caller-identity` shows the task role, `s3 ls` is denied (the role has no permissions), HTTPS to the internet returns 200 and plain HTTP on port 80 times out after 8 s.

## 6. Cost and safety

- The caps are per task. A run that hits `--max-turns` or `--max-budget-usd` stops with a non-zero result.
- The container runs with permission checks bypassed and outbound HTTPS open. Use it for trusted repositories only, with tokens scoped to what a run needs, and treat any untrusted input (for example candidate answers) as a prompt-injection risk. The task role has no AWS permissions by default.
- The API key is in the environment of every command the agent runs. Measured on 2026-10-29: a command's environment lists `ANTHROPIC_API_KEY` and `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` (the address the task role's credentials come from). Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` would hide the key, but **it cannot be used on Fargate**: it runs every command through `bubblewrap` with no unsandboxed fallback, and `bubblewrap` cannot create a namespace in a task. With the scrub switched on, none of the six G4b commands ran (Claude Code blocked all of them); a diagnostic task with the scrub off showed why: `bwrap --unshare-user`, `--unshare-pid` with a fresh `/proc` and `--unshare-pid` with the existing `/proc` all exit 1 with `bwrap: No permissions to create new namespace`, although the kernel allows namespaces (`max_user_namespaces` 16384). Docker on macOS (the Mac mini) did not run it either: `scripts/run/check-scrub-local.sh` (2026-10-29) found that with the scrub on, Claude Code blocked the agent's commands with Docker's default flags and with `--cap-add SYS_ADMIN`, while the control, with the scrub off, ran them, and one of its commands saw the key in its environment and two `/proc/*/environ` files held it. We have not found a container runtime where the scrub runs. So the image leaves the scrub off (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`) and keeps `bubblewrap` installed for a runtime where it might work (not tested: a Linux host or VM, where Claude Code documents it). `first-runs.sh` group G4 reports what a command can see of the key (G4b, commands 5 and 6) without judging it. To close the leak on Fargate, keep the key out of the box (a gateway that holds it, or a role in place of a key). To check whether your own Docker lets `bubblewrap` run, use `scripts/run/check-scrub-local.sh`: it runs the same probe three ways (Docker's default flags, `--cap-add SYS_ADMIN`, and a control with the scrub off), costs at most USD 0.90 and writes a report. Note that `--cap-add SYS_ADMIN` loosens the container's own restrictions. To re-check whether a Fargate task can run `bubblewrap`:

  ```bash
  scripts/deploy/ecs-in-docker.sh exec scripts/run/run-task.sh --profile core \
    --max-turns 10 --max-budget-usd 0.40 --output-format json \
    --prompt 'Read-only: run these commands one at a time and report the exit code and the first 5 lines of output of each, nothing else. 1) `bwrap --version` 2) `bwrap --unshare-user --ro-bind / / true; echo user-ns exit=$?` 3) `bwrap --unshare-pid --ro-bind / / --proc /proc true; echo fresh-proc exit=$?` 4) `bwrap --unshare-pid --ro-bind / / --bind /proc /proc true; echo existing-proc exit=$?`. If a command prints an error, report the error line exactly. Never print the value of any variable.'
  ```
- Outbound HTTPS is open to any host. It can be bounded (private subnets and an allowlist of domains on a forward proxy or a network firewall; `egress=nat` alone filters nothing) or closed (no route out; VPC endpoints for ECR, S3, CloudWatch Logs and Secrets Manager, and the model reached through a provider endpoint inside the VPC). Neither is built here.
- Spot tasks can be interrupted at any time; do not use `--spot` for work that must finish.

## 7. Data handling

- The prompt, the repository name and any `--env` values are part of the run-task request, so they are visible to anyone who can call `ecs:DescribeTasks` and appear in CloudTrail. Overrides are limited to under 8192 characters, so pass a pointer (an S3 key, a path in the repository), not the data.
- Everything the container prints goes to CloudWatch for 30 days. A workload under a zero-retention rule (for example customers' generated code or submitted answers) must write its result to a store with its own expiry and print nothing sensitive. The shared log group has no per-profile retention yet; that is a change to make before such a workload runs.

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Task stops at once with `exec format error` | Image architecture differs from the task definition's `cpu_architecture` |
| `CannotPullContainerError` | No image with that tag in ECR, or (with `egress=nat` off) no route to ECR |
| `ResourceInitializationError` mentioning a secret | The secret is missing or the execution role cannot read it |
| Container exit 1 with `401` / `invalid x-api-key` in the logs | The secret still holds the placeholder |
| Container exit 3 | The clone failed: wrong `--repo`/`--ref`, or no token for a private repository |
| `run-task: ECS did not start the task` with `RESOURCE` | No Fargate capacity right now; retry, or drop `--spot` |
| `could not read the stack outputs` | The stack is not deployed in this account and region, or credentials are missing |

## 9. Switching egress

`egress=public` (default) needs `assignPublicIp=ENABLED` and no NAT; `egress=nat` runs tasks in private subnets behind a NAT gateway. The script reads the right values from the stack outputs, so after `cdk deploy -c egress=nat` nothing else changes.
