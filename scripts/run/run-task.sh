#!/usr/bin/env bash
# Start one headless Claude Code task on ECS Fargate, wait for it, and print
# its logs and timings. Written for bash 3.2 (macOS) and the AWS CLI v2; needs jq.
#
# Cost caps are required on every run (--max-turns and --max-budget-usd), because
# they belong to the task, not to the profile. Infrastructure details come from
# the outputs of the `claude-ecs` CloudFormation stack (see infra/README.md).
#
# Example:
#   scripts/run/run-task.sh --profile pyvar --repo fibtecltd/pyvar \
#       --prompt "Summarise the repository layout" \
#       --model claude-haiku-5-5 --effort max --max-turns 10 --max-budget-usd 1
set -euo pipefail

STACK="${CLAUDE_ECS_STACK:-claude-ecs}"
LOG_GROUP="/claude-ecs"
MAX_OVERRIDES_CHARS=8000   # ECS rejects container overrides of 8192 characters or more

usage() {
    cat <<'USAGE'
Usage: run-task.sh --profile NAME (--prompt TEXT | --prompt-file FILE)
                   --max-turns N --max-budget-usd USD [options] [-- claude args...]

Required
  --profile NAME          a name from profiles/, e.g. core or pyvar (task definition claude-ecs-NAME)
  --prompt TEXT           the task, passed as `claude -p TEXT`
  --prompt-file FILE      read the prompt from FILE instead
  --max-turns N           stop after N agent turns
  --max-budget-usd USD    stop after spending USD

Options
  --model ID              e.g. claude-haiku-5-5 (default: the image's default)
  --effort LEVEL          low, medium, high, xhigh or max
  --output-format FMT     text (default), json or stream-json
  --repo OWNER/NAME       run inside a shallow clone of this repository
  --ref BRANCH_OR_TAG     with --repo: what to clone (default: the default branch)
  --env NAME=VALUE        extra environment variable for the container (repeatable);
                          visible to anyone who can call ecs:DescribeTasks, so no secrets
  --spot                  use Fargate Spot (can be interrupted) instead of on-demand
  --timeout SECONDS       how long to wait for the task to stop (default 1800)
  --no-wait               start the task and print its ARN, nothing else
  --dry-run               print the run-task request and exit; nothing is started
  --                      everything after is passed to claude unchanged

Environment
  CLAUDE_ECS_STACK        CloudFormation stack name (default claude-ecs)
  CLAUDE_ECS_POLL_SECONDS seconds between status checks (default 10)
  CLAUDE_ECS_CLUSTER, CLAUDE_ECS_SUBNETS (comma separated), CLAUDE_ECS_SECURITY_GROUP,
  CLAUDE_ECS_ASSIGN_PUBLIC_IP (ENABLED or DISABLED): set all four to skip the stack lookup
USAGE
}

die() { echo "run-task: $*" >&2; exit 2; }

profile="" prompt="" prompt_file="" model="" effort="" fmt="" repo="" ref=""
max_turns="" max_budget="" timeout_s=1800 spot=0 wait=1 dry_run=0
envs=() extra=()

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
        --prompt) prompt="${2:?--prompt needs a value}"; shift 2 ;;
        --prompt-file) prompt_file="${2:?--prompt-file needs a value}"; shift 2 ;;
        --model) model="${2:?--model needs a value}"; shift 2 ;;
        --effort) effort="${2:?--effort needs a value}"; shift 2 ;;
        --output-format) fmt="${2:?--output-format needs a value}"; shift 2 ;;
        --max-turns) max_turns="${2:?--max-turns needs a value}"; shift 2 ;;
        --max-budget-usd) max_budget="${2:?--max-budget-usd needs a value}"; shift 2 ;;
        --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
        --ref) ref="${2:?--ref needs a value}"; shift 2 ;;
        --env) envs+=("${2:?--env needs NAME=VALUE}"); shift 2 ;;
        --timeout) timeout_s="${2:?--timeout needs a value}"; shift 2 ;;
        --spot) spot=1; shift ;;
        --no-wait) wait=0; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h | --help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ "$profile" =~ ^[A-Za-z0-9_-]+$ ]] || die "--profile is required (letters, digits, - and _)"
[ -n "$prompt" ] && [ -n "$prompt_file" ] && die "use --prompt or --prompt-file, not both"
if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || die "cannot read $prompt_file"
    prompt="$(cat "$prompt_file")"
fi
[ -n "$prompt" ] || die "a prompt is required (--prompt or --prompt-file)"
[[ "$max_turns" =~ ^[0-9]+$ ]] || die "--max-turns is required and must be a whole number"
[[ "$max_budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--max-budget-usd is required and must be a number"
[ -z "$effort" ] || [[ "$effort" =~ ^(low|medium|high|xhigh|max)$ ]] || die "--effort must be low, medium, high, xhigh or max"
[ -z "$fmt" ] || [[ "$fmt" =~ ^(text|json|stream-json)$ ]] || die "--output-format must be text, json or stream-json"
[ -z "$ref" ] || [ -n "$repo" ] || die "--ref needs --repo"
[[ "$timeout_s" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds"
for kv in ${envs[@]+"${envs[@]}"}; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || die "--env expects NAME=VALUE, got '$kv'"
done

# Where to run: stack outputs, unless all four are given.
stack_output() {
    aws cloudformation describe-stacks --stack-name "$STACK" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}
cluster="${CLAUDE_ECS_CLUSTER:-}"
subnets="${CLAUDE_ECS_SUBNETS:-}"
security_group="${CLAUDE_ECS_SECURITY_GROUP:-}"
assign_ip="${CLAUDE_ECS_ASSIGN_PUBLIC_IP:-}"
if [ -z "$cluster" ] || [ -z "$subnets" ] || [ -z "$security_group" ] || [ -z "$assign_ip" ]; then
    cluster="$(stack_output ClusterName 2>/dev/null)" || cluster=""
    subnets="$(stack_output SubnetIds 2>/dev/null)" || subnets=""
    security_group="$(stack_output SecurityGroupId 2>/dev/null)" || security_group=""
    assign_ip="$(stack_output AssignPublicIp 2>/dev/null)" || assign_ip=""
fi
for v in "$cluster" "$subnets" "$security_group" "$assign_ip"; do
    { [ -n "$v" ] && [ "$v" != "None" ]; } || die "could not read the stack outputs of '$STACK' (is it deployed, and are credentials set?)"
done

# The claude arguments: the prompt first, then the per-task limits.
claude_args=(-p "$prompt" --max-turns "$max_turns" --max-budget-usd "$max_budget")
[ -z "$model" ] || claude_args+=(--model "$model")
[ -z "$effort" ] || claude_args+=(--effort "$effort")
[ -z "$fmt" ] || claude_args+=(--output-format "$fmt")
claude_args+=(${extra[@]+"${extra[@]}"})

env_args=()
[ -z "$repo" ] || env_args+=("CLAUDE_REPO=$repo")
[ -z "$ref" ] || env_args+=("CLAUDE_REF=$ref")
for kv in ${envs[@]+"${envs[@]}"}; do env_args+=("$kv"); done

if [ "$spot" -eq 1 ]; then provider="FARGATE_SPOT"; else provider="FARGATE"; fi

# jq --args keeps each argument whole, including newlines inside a prompt.
command_json="$(jq -n -c '$ARGS.positional' --args -- "${claude_args[@]}")"
if [ ${#env_args[@]} -gt 0 ]; then
    env_json="$(jq -n -c '$ARGS.positional' --args -- "${env_args[@]}")"
else
    env_json="[]"
fi

request="$(
    jq -n --arg cluster "$cluster" --arg family "claude-ecs-$profile" --arg provider "$provider" \
        --arg subnets "$subnets" --arg sg "$security_group" --arg ip "$assign_ip" \
        --argjson command "$command_json" --argjson env "$env_json" '{
        cluster: $cluster,
        taskDefinition: $family,
        count: 1,
        startedBy: "claude-ecs-run-task",
        capacityProviderStrategy: [{capacityProvider: $provider, weight: 1}],
        networkConfiguration: {awsvpcConfiguration: {
            subnets: ($subnets | split(",")), securityGroups: [$sg], assignPublicIp: $ip}},
        overrides: {containerOverrides: [{
            name: "claude",
            command: $command,
            environment: ($env | map(index("=") as $i | {name: .[:$i], value: .[$i + 1:]}))
        }]}
    }'
)"

overrides_size="$(jq -c '.overrides' <<<"$request" | wc -c | tr -d ' ')"
[ "$overrides_size" -le "$MAX_OVERRIDES_CHARS" ] \
    || die "the prompt and settings are $overrides_size characters; ECS allows under 8192. Put the input in S3 or the repository and keep the prompt short."

if [ "$dry_run" -eq 1 ]; then
    echo "$request" | jq .
    exit 0
fi

req_file="$(mktemp)"
trap 'rm -f "$req_file"' EXIT
echo "$request" > "$req_file"

result="$(aws ecs run-task --cli-input-json "file://$req_file")"
task_arn="$(jq -r '.tasks[0].taskArn // empty' <<<"$result")"
if [ -z "$task_arn" ]; then
    echo "run-task: ECS did not start the task:" >&2
    jq -r '.failures[]? | "  \(.arn // "-"): \(.reason // "?") \(.detail // "")"' <<<"$result" >&2
    exit 1
fi
task_id="${task_arn##*/}"
echo "started $task_arn ($provider, $profile)"
if [ "$wait" -eq 0 ]; then
    echo "$task_arn"
    exit 0
fi

# Wait for STOPPED.
deadline=$(( $(date +%s) + timeout_s ))
last=""
while :; do
    desc="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn")"
    status="$(jq -r '.tasks[0].lastStatus' <<<"$desc")"
    if [ "$status" != "$last" ]; then echo "status: $status"; last="$status"; fi
    [ "$status" = "STOPPED" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "run-task: still $status after ${timeout_s}s. Stop it with:" >&2
        echo "  aws ecs stop-task --cluster $cluster --task $task_arn" >&2
        exit 124
    fi
    sleep "${CLAUDE_ECS_POLL_SECONDS:-10}"
done

# Seconds between two task timestamps; "n/a" when either is missing or unparsable.
# All timestamps share one UTC offset, so their differences are right. AWS CLI v2 prints
# ISO 8601 strings, v1 prints epoch numbers; both are accepted.
epoch() {
    jq -r --arg f "$1" '.tasks[0][$f] // empty
        | if type == "number" then floor
          else sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime end' <<<"$desc" 2>/dev/null || true
}
span() {
    local a b
    a="$(epoch "$1")"; b="$(epoch "$2")"
    if [ -n "$a" ] && [ -n "$b" ]; then echo "$((b - a))s"; else echo "n/a"; fi
}

log_stream="$profile/claude/$task_id"
echo "--- logs ($LOG_GROUP, stream $log_stream)"
# AWS CLI v1 (the one in the image) has no `logs tail`; fall back to get-log-events.
aws logs tail "$LOG_GROUP" --log-stream-names "$log_stream" --since 3h --format short 2>/dev/null \
    || aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$log_stream" \
        --start-from-head --output json 2>/dev/null | jq -er '.events[].message' \
    || echo "(could not read the log stream; try the CloudWatch console)"

exit_code="$(jq -r '.tasks[0].containers[0].exitCode // empty' <<<"$desc")"
echo "--- summary"
echo "stopped:     $(jq -r '.tasks[0].stoppedReason // "-"' <<<"$desc")"
echo "container:   exit code ${exit_code:-none} $(jq -r '.tasks[0].containers[0].reason // empty' <<<"$desc")"
echo "provisioning (created -> image pull start): $(span createdAt pullStartedAt)"
echo "image pull:                                 $(span pullStartedAt pullStoppedAt)"
echo "start-up (created -> running):              $(span createdAt startedAt)"
echo "run (running -> stopped):                   $(span startedAt stoppedAt)"
[ -n "$exit_code" ] || exit 1
exit "$exit_code"
