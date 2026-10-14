# infra: Claude Code on ECS Fargate

A CDK app (Python) with one stack, `claude-ecs`. It defines where headless Claude Code runs; it never starts a run. There is no ECS service and no schedule: a run is an `aws ecs run-task` call, so the idle cost is ECR storage, plus the NAT gateway if you choose `egress=nat`.

## What it creates

| Resource | Notes |
|---|---|
| ECR repository `claude-ecs` | scan on push, keeps the newest 10 images, retained if the stack is deleted |
| VPC | 2 AZs; see Egress below |
| Security group | no inbound rule; outbound TCP 443 only |
| ECS cluster `claude-ecs` | Fargate and Fargate Spot capacity providers, Container Insights off |
| Log group `/claude-ecs` | 30 days |
| One task definition per profile | `claude-ecs-<profile>` for every `profiles/<name>.plugins`; sets `CLAUDE_PROFILE`, 1 vCPU / 4 GiB / 30 GiB disk by default |
| Secret `claude-ecs/anthropic-api-key` | injected as `ANTHROPIC_API_KEY`; created with a placeholder value |
| Secret `claude-ecs/github-token` | optional (`github_token=true`); injected as both `GITHUB_PERSONAL_ACCESS_TOKEN` and `GITHUB_TOKEN` |

Adding a profile file to `profiles/` adds a task definition on the next deploy.

IAM: each task role starts with **no permissions** (what the code inside the container can do on AWS). Each execution role can pull from this ECR repository, write to the log group and read only this stack's secrets.

## Egress

Set with `-c egress=public|nat`.

- `public` (default): public subnets, no NAT gateway. Run tasks with `assignPublicIp=ENABLED`. Nothing can connect in (no inbound rule); the task reaches the internet directly over 443.
- `nat`: tasks in private subnets behind one NAT gateway (billed per hour plus per GB processed), `assignPublicIp=DISABLED`. An S3 gateway endpoint keeps ECR layer pulls off the NAT. Switching modes replaces the subnets and adds or removes the NAT gateway, so do it between runs.

The stack outputs `AssignPublicIp` and `SubnetIds` for whichever mode is deployed.

## Settings

Passed as CDK context: `-c key=value`, or `CDK_CONTEXT_JSON` when running `python app.py`.

| Key | Default | Meaning |
|---|---|---|
| `egress` | `public` | `public` or `nat` |
| `image_tag` | `latest` | tag the task definitions run; use a git SHA tag to pin |
| `cpu`, `memory_mib` | `1024`, `4096` | Fargate size (CDK rejects invalid combinations) |
| `ephemeral_storage_gib` | `30` | 20 to 200 |
| `cpu_architecture` | `X86_64` | `X86_64` or `ARM64`; must match the image you push |
| `github_token` | `false` | create the GitHub token secret and inject it |
| `tags` | `{"Project": "claude-ecs"}` | tags on every resource, as JSON: `-c 'tags={"Project":"x","Owner":"y"}'`. Match your account's tagging convention |

AWS account and region come from your credentials (`CDK_DEFAULT_ACCOUNT` / `CDK_DEFAULT_REGION`); nothing is hard-coded.

## Deploy (by you; not done by CI)

`scripts/deploy/ecs-deploy.sh` wraps the steps below with checks that run before anything changes: `preflight` (read-only checks of the account: identity, name clashes, CDK bootstrap version, Fargate and VPC headroom, budgets, pipelines, tag convention), `stack` (preflight, a diff that must only create resources, and a typed confirmation, then `cdk deploy`), `image` (build, smoke test, push), `secret` and `verify`. It never runs `cdk bootstrap`. Settings come from the environment or `--config FILE`; see the header of the script.

The manual steps:

```bash
cd infra
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
npx aws-cdk bootstrap            # once per account and region
npx aws-cdk deploy -c egress=public

# secrets are created with a placeholder; set the real values
aws secretsmanager put-secret-value --secret-id claude-ecs/anthropic-api-key --secret-string "$ANTHROPIC_API_KEY"

# push an image (repository URI is the RepositoryUri output)
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker buildx build --platform linux/amd64 --target ecs-base -t <RepositoryUri>:latest --push ..
```

The platform must match `cpu_architecture`. CI builds `linux/amd64`, so `X86_64` is the default. On an Apple-silicon Mac a native build is `linux/arm64`: build that and deploy with `-c cpu_architecture=ARM64` (Graviton Fargate is also cheaper per hour), or accept a slower emulated amd64 build.

The `ecs-deploy` image has the CDK CLI and library if you prefer to deploy from a container.

## Checks

```bash
cd infra
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q                       # assertions on the synthesized template
CDK_OUTDIR=/tmp/out .venv/bin/python app.py         # synth without the CDK CLI
.venv/bin/cfn-lint /tmp/out/claude-ecs.template.json
```

The tests cover: one task definition per profile with the right `CLAUDE_PROFILE`; no inbound rule and HTTPS-only outbound; no NAT in `public` mode and one NAT plus the S3 endpoint in `nat` mode; secrets injected, retained and placeholder-only; empty task roles; ECR scanning, expiry and retention. `.github/workflows/infra.yml` runs them, synthesizes both modes and runs cfn-lint on every pull request that touches `infra/` or `profiles/`.

## Not covered here

- **Not deployed or run.** Everything above is validated by tests, synthesis and cfn-lint only. The first deploy and the first real task are the first test against AWS.
- **Bedrock.** Auth is the Anthropic API key. When Bedrock access arrives it means `bedrock:InvokeModel*` on the task role and `CLAUDE_CODE_USE_BEDROCK=1`.
- **Starting a run** (cloning the repository into `/workspace`, the `run-task` command, passing a prompt and cost caps) is the next piece, a runbook.
- **ECS Exec, VPC interface endpoints, alarms, image push from CI** are not set up.
