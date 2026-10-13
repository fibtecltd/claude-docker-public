# Runbook: running headless Claude Code tasks on ECS

`scripts/run/run-task.sh` starts one task, waits for it, then prints its logs, its exit code and where the time went. This runbook covers the setup it needs and what to expect.

**Status:** none of this has run against AWS yet. The first deploy and the first task are the first test; the timings in "Reading the result" are to be filled in from that run.

## 1. One-time setup

Follow `infra/README.md` (bootstrap, `cdk deploy`, secrets, image push) and check:

```bash
aws cloudformation describe-stacks --stack-name claude-ecs --query 'Stacks[0].Outputs'
aws ecs list-task-definitions --family-prefix claude-ecs
aws ecr describe-images --repository-name claude-ecs --query 'imageDetails[].imageTags'
```

You need one task definition per profile in `profiles/` (`claude-ecs-core`, `claude-ecs-pyvar`, and any profile you add), an image tagged `latest` (or your `image_tag`) built for the architecture you deployed, and the real API key in `claude-ecs/anthropic-api-key`. For private repositories deploy with `-c github_token=true` and put a token in `claude-ecs/github-token`.

Requirements on your machine: AWS CLI v2 with credentials for the account and region, and `jq`.

## 2. First run

```bash
scripts/run/run-task.sh --profile core --prompt "Reply with exactly: ok" \
    --max-turns 1 --max-budget-usd 0.25
```

`--max-turns` and `--max-budget-usd` are required on every run: limits belong to the task, not the profile. Add `--dry-run` to print the exact request without starting anything.

## 3. Model matrix (rate-limit evidence)

Run the same trivial prompt against each model and compare with what you see from other paths:

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
scripts/run/run-task.sh --profile pyvar --repo fibtecltd/pyvar --ref main \
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
| | | | | | | |

## 6. Cost and safety

- The caps are per task. A run that hits `--max-turns` or `--max-budget-usd` stops with a non-zero result.
- The container runs with permission checks bypassed and outbound HTTPS open. Use it for trusted repositories only, with tokens scoped to what a run needs, and treat any untrusted input (for example candidate answers) as a prompt-injection risk. The task role has no AWS permissions by default.
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
