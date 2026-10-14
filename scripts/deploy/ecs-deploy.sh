#!/bin/bash
# ============================================================
# ecs-deploy.sh - guarded first deploy of the claude-ecs stack.
#
#   scripts/deploy/ecs-deploy.sh [--config FILE] COMMAND
#
#   preflight  read-only checks of the AWS account; writes a baseline file
#   stack      preflight, then cdk diff (new resources only), confirm, cdk deploy
#   image      build the image for the stack's architecture, smoke-test it, push it
#   secret     store the Anthropic API key in Secrets Manager
#   verify     compare the account with the baseline taken by preflight
#
# Run it under YOUR OWN AWS identity. It never runs `cdk bootstrap`. Every check
# prints GO, NO-GO or UNKNOWN; `stack` refuses to continue unless all are GO.
# Settings come from the environment or from --config FILE (a shell file):
#
#   AWS_REGION                 required
#   EXPECTED_ACCOUNT           NO-GO when the credentials belong to another account
#   FORBIDDEN_PRINCIPAL_REGEX  NO-GO when the caller ARN matches (e.g. a CI user)
#   TAGS_JSON                  tags for every resource (default {"Project":"claude-ecs"})
#   EGRESS                     public|nat                       (default public)
#   CPU_ARCH                   ARM64|X86_64                     (default ARM64)
#   RESERVED_VCPU              Fargate vCPU other workloads may need at peak (default 0)
#   MIN_FREE_VCPU              vCPU that must stay free after that          (default 4)
#   BUDGET_ALERT_PCT           NO-GO when a budget is at or above this %    (default 80;
#                              0 = list the budgets, never block)
#   WATCH_PIPELINE_PREFIX      CodePipeline names to watch (e.g. "pyvar-"); empty = none
#   ALLOW_UNKNOWN=1            let `stack` continue past UNKNOWN checks
#   ASSUME_YES=1               `stack` asks nothing: no typed account id, CDK's y/n on IAM
#                              changes off. Needs EXPECTED_ACCOUNT, which preflight enforces.
#   BASELINE_FILE              default .ecs-deploy-baseline.json in the repository
#   DIFF_FILE                  where `stack` keeps the cdk diff, default .ecs-deploy-diff.txt there
#
# Needs: aws (v2), jq, awk; python3 + npx for stack; docker for image.
# Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_NAME="claude-ecs"
BOOTSTRAP_QUALIFIER="hnb659fds"

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }

NOGO=0
UNKNOWN=0
go()      { printf '  [GO]       %s\n' "$*"; }
nogo()    { printf '  [NO-GO]    %s\n' "$*"; NOGO=$((NOGO + 1)); }
unknown() { printf '  [UNKNOWN]  %s\n' "$*"; UNKNOWN=$((UNKNOWN + 1)); }

ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT
# aws_json ARGS...: JSON on stdout. On failure returns 1 and keeps the error text in ERRFILE
# (a file, because most callers run it inside $(...), where a variable would be lost).
aws_json() {
    if aws "$@" --output json 2>"$ERRFILE"; then
        : > "$ERRFILE"
        return 0
    fi
    return 1
}
last_err() { tr '\n' ' ' < "$ERRFILE"; }

denied() { last_err | grep -qiE 'AccessDenied|UnauthorizedOperation|not authorized'; }

load_settings() {
    [ -z "${CONFIG:-}" ] || { [ -f "$CONFIG" ] || { echo "ERROR: no config file $CONFIG" >&2; exit 2; }; }
    # shellcheck disable=SC1090
    [ -z "${CONFIG:-}" ] || . "$CONFIG"
    : "${AWS_REGION:?set AWS_REGION (in the environment or the config file)}"
    export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
    EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-}"
    FORBIDDEN_PRINCIPAL_REGEX="${FORBIDDEN_PRINCIPAL_REGEX:-}"
    TAGS_JSON="${TAGS_JSON:-{\"Project\":\"claude-ecs\"\}}"
    EGRESS="${EGRESS:-public}"
    CPU_ARCH="${CPU_ARCH:-ARM64}"
    RESERVED_VCPU="${RESERVED_VCPU:-0}"
    MIN_FREE_VCPU="${MIN_FREE_VCPU:-4}"
    BUDGET_ALERT_PCT="${BUDGET_ALERT_PCT:-80}"
    WATCH_PIPELINE_PREFIX="${WATCH_PIPELINE_PREFIX:-}"
    ALLOW_UNKNOWN="${ALLOW_UNKNOWN:-0}"
    ASSUME_YES="${ASSUME_YES:-0}"
    BASELINE_FILE="${BASELINE_FILE:-$REPO_DIR/.ecs-deploy-baseline.json}"
    echo "$TAGS_JSON" | jq -e 'type == "object" and length > 0' >/dev/null \
        || { echo "ERROR: TAGS_JSON must be a non-empty JSON object" >&2; exit 2; }
    case "$CPU_ARCH" in ARM64|X86_64) ;; *) echo "ERROR: CPU_ARCH must be ARM64 or X86_64" >&2; exit 2 ;; esac
    case "$EGRESS" in public|nat) ;; *) echo "ERROR: EGRESS must be public or nat" >&2; exit 2 ;; esac
}

cdk_flags() {
    CDK_FLAGS=(-c "egress=$EGRESS" -c "cpu_architecture=$CPU_ARCH" -c "tags=$TAGS_JSON")
}

# ── checks ──────────────────────────────────────────────────────────────

check_identity() {
    local ident arn
    if ! ident="$(aws_json sts get-caller-identity)"; then
        nogo "1 identity: no usable AWS credentials ($(last_err))"
        return
    fi
    ACCOUNT="$(echo "$ident" | jq -r .Account)"
    arn="$(echo "$ident" | jq -r .Arn)"
    if [ -n "$EXPECTED_ACCOUNT" ] && [ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
        nogo "1 identity: account $ACCOUNT, expected $EXPECTED_ACCOUNT"
    elif [ -n "$FORBIDDEN_PRINCIPAL_REGEX" ] && printf '%s' "$arn" | grep -qE "$FORBIDDEN_PRINCIPAL_REGEX"; then
        nogo "1 identity: $arn is not allowed for this deploy (FORBIDDEN_PRINCIPAL_REGEX)"
    else
        go "1 identity: $arn"
    fi
}

check_names_free() {
    local out found=""
    if out="$(aws_json cloudformation describe-stacks --stack-name "$STACK_NAME")"; then
        found="$found stack"
    elif ! last_err | grep -q 'does not exist'; then
        unknown "2 names: cloudformation: $(last_err)"; return
    fi
    if aws_json ecr describe-repositories --repository-names claude-ecs >/dev/null; then
        found="$found ecr-repository"
    elif ! last_err | grep -q 'RepositoryNotFoundException'; then
        unknown "2 names: ecr: $(last_err)"; return
    fi
    if out="$(aws_json ecs describe-clusters --clusters claude-ecs)"; then
        [ "$(echo "$out" | jq '[.clusters[] | select(.status == "ACTIVE")] | length')" = "0" ] || found="$found ecs-cluster"
    else
        unknown "2 names: ecs: $(last_err)"; return
    fi
    if out="$(aws_json logs describe-log-groups --log-group-name-prefix /claude-ecs)"; then
        [ "$(echo "$out" | jq '.logGroups | length')" = "0" ] || found="$found log-group"
    else
        unknown "2 names: logs: $(last_err)"; return
    fi
    if out="$(aws_json secretsmanager list-secrets --filters Key=name,Values=claude-ecs/)"; then
        [ "$(echo "$out" | jq '.SecretList | length')" = "0" ] || found="$found secrets"
    else
        unknown "2 names: secretsmanager: $(last_err)"; return
    fi
    if [ -n "$found" ]; then
        nogo "2 names: already exist:$found"
    else
        go "2 names: nothing named claude-ecs exists"
    fi
}

synth_template() {
    # Synthesize the app (no AWS calls) and set TEMPLATE_FILE. Not run in a subshell: it sets a global.
    if [ -n "${TEMPLATE_OVERRIDE:-}" ]; then
        TEMPLATE_FILE="$TEMPLATE_OVERRIDE"
        return 0
    fi
    ensure_venv
    local out context
    out="$(mktemp -d)"
    context="$(jq -nc --arg e "$EGRESS" --arg c "$CPU_ARCH" --argjson t "$TAGS_JSON" \
        '{egress: $e, cpu_architecture: $c, tags: $t}')"
    (cd "$REPO_DIR/infra" && CDK_OUTDIR="$out" CDK_CONTEXT_JSON="$context" "$VENV/bin/python" app.py >/dev/null) || return 1
    TEMPLATE_FILE="$out/$STACK_NAME.template.json"
}

ensure_venv() {
    VENV="${ECS_DEPLOY_VENV:-$REPO_DIR/infra/.venv}"
    if [ ! -x "$VENV/bin/python" ]; then
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install -q -r "$REPO_DIR/infra/requirements.txt"
    fi
}

check_bootstrap() {
    local have need param
    TOOLKIT_UPDATED=""
    if ! param="$(aws_json ssm get-parameter --name "/cdk-bootstrap/$BOOTSTRAP_QUALIFIER/version")"; then
        if denied; then unknown "3 bootstrap: cannot read the bootstrap version ($(last_err))"; return; fi
        nogo "3 bootstrap: no CDK bootstrap in this account/region (this script never bootstraps)"
        return
    fi
    have="$(echo "$param" | jq -r .Parameter.Value)"
    if toolkit="$(aws_json cloudformation describe-stacks --stack-name CDKToolkit)"; then
        TOOLKIT_UPDATED="$(echo "$toolkit" | jq -r '.Stacks[0].LastUpdatedTime // .Stacks[0].CreationTime')"
    fi
    TEMPLATE_FILE=""
    need=""
    if synth_template; then
        need="$(jq -r '.Rules.CheckBootstrapVersion.Assertions[0].AssertDescription
                       | capture("version (?<n>[0-9]+) required").n' "$TEMPLATE_FILE")" || need=""
    fi
    if [ -z "$need" ]; then
        unknown "3 bootstrap: account has version $have; could not synthesize the stack to learn the minimum"
        return
    fi
    if [ "$have" -ge "$need" ]; then
        go "3 bootstrap: account version $have, stack needs $need (CDKToolkit last updated $TOOLKIT_UPDATED)"
    else
        nogo "3 bootstrap: account version $have is below the $need this stack needs; upgrading it is a change to a shared stack, do it deliberately"
    fi
}

check_template_tags() {
    # The synthesized stack must carry every planned tag, or this checkout predates the tags setting.
    if [ -z "${TEMPLATE_FILE:-}" ] || [ ! -f "$TEMPLATE_FILE" ]; then
        unknown "3b tags: no synthesized template to inspect"; return
    fi
    local missing
    missing="$(jq -r --argjson want "$TAGS_JSON" '
        ([.Resources[] | select(.Type == "AWS::ECR::Repository") | .Properties.Tags // []] | .[0] // []
         | map({(.Key): .Value}) | add // {}) as $have
        | $want | to_entries | map(select($have[.key] != .value) | .key) | join(",")' "$TEMPLATE_FILE")"
    if [ -z "$missing" ]; then
        go "3b tags: the template carries the planned tags"
    else
        nogo "3b tags: the synthesized template lacks or differs on: $missing (is the tags setting merged in this checkout?)"
    fi
}

quota_value() { # quota_value SERVICE CODE NAME_REGEX
    local out
    if out="$(aws_json service-quotas get-service-quota --service-code "$1" --quota-code "$2")"; then
        echo "$out" | jq -r .Quota.Value; return 0
    fi
    denied && return 1
    if out="$(aws_json service-quotas list-service-quotas --service-code "$1")"; then
        echo "$out" | jq -r --arg re "$3" '[.Quotas[] | select(.QuotaName | test($re; "i"))][0].Value // empty'
        return 0
    fi
    return 1
}

fargate_vcpu_in_use() {
    local clusters c tasks total=0 part
    clusters="$(aws_json ecs list-clusters | jq -r '.clusterArns[]')" || return 1
    for c in $clusters; do
        tasks="$(aws_json ecs list-tasks --cluster "$c" --desired-status RUNNING | jq -r '.taskArns[]')" || return 1
        [ -n "$tasks" ] || continue
        # describe-tasks takes at most 100 task ARNs
        while [ -n "$tasks" ]; do
            batch="$(printf '%s\n' "$tasks" | head -n 100)"
            tasks="$(printf '%s\n' "$tasks" | tail -n +101)"
            # shellcheck disable=SC2086
            part="$(aws_json ecs describe-tasks --cluster "$c" --tasks $batch \
                | jq '[.tasks[] | select(.launchType == "FARGATE") | (.cpu | tonumber) / 1024] | add // 0')" || return 1
            total="$(awk -v a="$total" -v b="$part" 'BEGIN { print a + b }')"
        done
    done
    echo "$total"
}

check_fargate() {
    local quota used free
    if ! quota="$(quota_value fargate L-3032A538 'Fargate On-Demand vCPU')" || [ -z "$quota" ]; then
        unknown "4 fargate: cannot read the On-Demand vCPU quota (service-quotas denied or failed)"; return
    fi
    if ! used="$(fargate_vcpu_in_use)"; then
        unknown "4 fargate: cannot count running tasks (ecs list/describe denied or failed)"; return
    fi
    free="$(awk -v q="$quota" -v u="$used" -v r="$RESERVED_VCPU" 'BEGIN { print q - u - r }')"
    if awk -v f="$free" -v m="$MIN_FREE_VCPU" 'BEGIN { exit !(f >= m) }'; then
        go "4 fargate: quota $quota vCPU, in use $used, reserved $RESERVED_VCPU, free $free (need $MIN_FREE_VCPU)"
    else
        nogo "4 fargate: quota $quota vCPU, in use $used, reserved $RESERVED_VCPU, free $free is below $MIN_FREE_VCPU"
    fi
}

check_vpcs() {
    local quota count
    if ! quota="$(quota_value vpc L-F678F1CE 'VPCs per Region')" || [ -z "$quota" ]; then
        unknown "5 vpc: cannot read the VPC quota (service-quotas denied or failed)"; return
    fi
    if ! count="$(aws_json ec2 describe-vpcs | jq '.Vpcs | length')"; then
        unknown "5 vpc: cannot list VPCs ($(last_err))"; return
    fi
    if awk -v q="$quota" -v c="$count" 'BEGIN { exit !(q - c >= 1) }'; then
        go "5 vpc: $count of $quota used"
    else
        nogo "5 vpc: $count of $quota used; the stack creates one"
    fi
}

check_pipelines() {
    PIPELINE_BASELINE='{}'
    if [ -z "$WATCH_PIPELINE_PREFIX" ]; then
        go "6 pipelines: none watched"; return
    fi
    local names n state busy ex id status bad=""
    if ! names="$(aws_json codepipeline list-pipelines | jq -r --arg p "$WATCH_PIPELINE_PREFIX" '.pipelines[].name | select(startswith($p))')"; then
        unknown "6 pipelines: cannot list pipelines ($(last_err))"; return
    fi
    for n in $names; do
        if ! state="$(aws_json codepipeline get-pipeline-state --name "$n")"; then
            unknown "6 pipelines: cannot read $n ($(last_err))"; return
        fi
        # an action waiting on a manual approval is normal, anything else in progress is not
        busy="$(echo "$state" | jq -r '[.stageStates[].actionStates[]
                | select(.latestExecution.status == "InProgress")
                | select(.actionName | test("approv"; "i") | not) | .actionName] | join(",")')"
        [ -z "$busy" ] || bad="$bad $n($busy)"
        ex="$(aws_json codepipeline list-pipeline-executions --pipeline-name "$n" --max-items 1)" || { unknown "6 pipelines: cannot read executions of $n"; return; }
        id="$(echo "$ex" | jq -r '.pipelineExecutionSummaries[0].pipelineExecutionId // "none"')"
        status="$(echo "$ex" | jq -r '.pipelineExecutionSummaries[0].status // "none"')"
        PIPELINE_BASELINE="$(echo "$PIPELINE_BASELINE" | jq -c --arg n "$n" --arg i "$id" '. + {($n): $i}')"
        echo "             $n: latest execution $id ($status)"
    done
    if [ -n "$bad" ]; then
        nogo "6 pipelines: work in progress in:$bad"
    else
        go "6 pipelines: idle ($(echo "$PIPELINE_BASELINE" | jq 'length') watched)"
    fi
}

check_budgets() {
    local out report hot
    if ! out="$(aws_json budgets describe-budgets --account-id "$ACCOUNT")"; then
        unknown "7 budget: cannot read budgets ($(last_err))"; return
    fi
    report="$(echo "$out" | jq -r '.Budgets[]? | "\(.BudgetName): \(.CalculatedSpend.ActualSpend.Amount // "0") of \(.BudgetLimit.Amount) \(.BudgetLimit.Unit)"')"
    hot="$(echo "$out" | jq -r --argjson p "$BUDGET_ALERT_PCT" '.Budgets[]?
        | select((.CalculatedSpend.ActualSpend.Amount // "0" | tonumber) * 100 >= ($p * (.BudgetLimit.Amount | tonumber)))
        | .BudgetName' | paste -sd, -)"
    [ -z "$report" ] || printf '%s\n' "$report" | sed 's/^/             /'
    if [ "$BUDGET_ALERT_PCT" = "0" ]; then
        go "7 budget: listed above, not blocking (BUDGET_ALERT_PCT=0)"
    elif [ -n "$hot" ]; then
        nogo "7 budget: at or above ${BUDGET_ALERT_PCT}%: $hot"
    else
        go "7 budget: all below ${BUDGET_ALERT_PCT}% of their limit"
    fi
}

check_organization() {
    if aws_json organizations describe-organization >/dev/null; then
        unknown "8 organization: this account is in an AWS Organization; service control policies may apply (check them by hand)"
    elif last_err | grep -q 'AWSOrganizationsNotInUse'; then
        go "8 organization: not in an Organization, so no SCPs"
    else
        unknown "8 organization: cannot tell ($(last_err))"
    fi
}

check_tag_convention() {
    local project out clash="" key want have
    project="$(echo "$TAGS_JSON" | jq -r '.Project // empty')"
    if [ -z "$project" ]; then
        go "9 tags: no Project tag planned, nothing to compare"; return
    fi
    if ! out="$(aws_json resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$project")"; then
        unknown "9 tags: cannot read tagged resources ($(last_err))"; return
    fi
    if [ "$(echo "$out" | jq '.ResourceTagMappingList | length')" = "0" ]; then
        go "9 tags: no existing resources with Project=$project, so no convention to match"; return
    fi
    for key in $(echo "$TAGS_JSON" | jq -r 'keys[] | select(. != "Project")'); do
        want="$(echo "$TAGS_JSON" | jq -r --arg k "$key" '.[$k]')"
        have="$(echo "$out" | jq -r --arg k "$key" '[.ResourceTagMappingList[].Tags[] | select(.Key == $k) | .Value] | unique | join(",")')"
        if [ -n "$have" ] && [ "$have" != "$want" ]; then
            clash="$clash $key(existing: $have, planned: $want)"
        fi
    done
    if [ -n "$clash" ]; then
        nogo "9 tags: differs from resources already tagged Project=$project:$clash"
    else
        go "9 tags: consistent with the $(echo "$out" | jq '.ResourceTagMappingList | length') resources tagged Project=$project"
    fi
}

write_baseline() {
    jq -n --arg account "$ACCOUNT" --arg region "$AWS_REGION" --arg toolkit "${TOOLKIT_UPDATED:-}" \
        --argjson pipelines "${PIPELINE_BASELINE:-{\}}" \
        '{account: $account, region: $region, cdkToolkitUpdated: $toolkit, pipelines: $pipelines}' > "$BASELINE_FILE"
    echo "Baseline written to $BASELINE_FILE (contains account identifiers; it is git-ignored)."
}

cmd_preflight() {
    echo "Preflight for the $STACK_NAME stack in $AWS_REGION (read-only):"
    ACCOUNT=""
    check_identity
    if [ -z "$ACCOUNT" ]; then
        echo; echo "Stopped: no identity, nothing else can be checked."; return 1
    fi
    check_names_free
    check_bootstrap
    check_template_tags
    check_fargate
    check_vpcs
    check_pipelines
    check_budgets
    check_organization
    check_tag_convention
    write_baseline
    echo
    if [ "$NOGO" -gt 0 ]; then
        echo "Verdict: NO-GO ($NOGO blocking, $UNKNOWN unknown). Nothing was changed."
        return 1
    elif [ "$UNKNOWN" -gt 0 ]; then
        echo "Verdict: $UNKNOWN check(s) UNKNOWN. Resolve them by hand, or set ALLOW_UNKNOWN=1 for stack."
        return 2
    fi
    echo "Verdict: GO."
}

# ── actions ─────────────────────────────────────────────────────────────

cmd_stack() {
    local rc=0
    cmd_preflight || rc=$?
    if [ "$rc" -eq 1 ] || { [ "$rc" -eq 2 ] && [ "$ALLOW_UNKNOWN" != "1" ]; }; then
        echo "Not deploying."; return 1
    fi
    ensure_venv
    cdk_flags
    local log changed created other toolkit
    log="${DIFF_FILE:-$REPO_DIR/.ecs-deploy-diff.txt}"
    echo; echo "cdk diff (nothing is deployed by this step):"
    (cd "$REPO_DIR/infra" && PATH="$VENV/bin:$PATH" npx aws-cdk diff "${CDK_FLAGS[@]}" --no-color) >"$log" 2>&1 || true
    created="$(grep -c '^\[+\]' "$log" || true)"
    changed="$(grep -cE '^\[(~|-)\]' "$log" || true)"
    echo "  $created item(s) to create, $changed to change or remove (full diff: $log)"
    if [ "$created" = "0" ]; then
        echo "NO-GO: the diff shows nothing to create, so cdk diff probably failed. Its output ends:"
        tail -n 20 "$log" | sed 's/^/    /'
        return 1
    fi
    { grep '^\[+\]' "$log" | cut -c1-110 | sed 's/^/    /'; } || true
    if [ "$changed" != "0" ]; then
        echo "NO-GO: the diff touches existing resources:"
        { grep -E '^\[(~|-)\]' "$log" | cut -c1-110 | sed 's/^/    /'; } || true
        echo "Not deploying."; return 1
    fi
    # Only the diff proper is judged: the "Stack NAME" headers and the [+]/[~]/[-] items. Free text
    # around it (CLI notices, parameter descriptions) may mention the bootstrap stack at will.
    other="$(grep -E '^Stack ' "$log" | grep -vE "^Stack $STACK_NAME([[:space:]]|\$)" || true)"
    toolkit="$(grep -E '^\[[-+~]\]' "$log" | grep 'CDKToolkit' || true)"
    if [ -n "$other" ] || [ -n "$toolkit" ]; then
        echo "NO-GO: the diff touches a stack other than $STACK_NAME, or the bootstrap stack (CDKToolkit):"
        printf '%s\n%s\n' "$other" "$toolkit" | grep . | cut -c1-110 | sed 's/^/    /' || true
        echo "Read $log; not deploying."
        return 1
    fi
    echo
    local approval=()
    if [ "$ASSUME_YES" = "1" ]; then
        # Preflight check 1 has already stopped on any account other than EXPECTED_ACCOUNT.
        [ -n "$EXPECTED_ACCOUNT" ] || { echo "ERROR: ASSUME_YES=1 needs EXPECTED_ACCOUNT: it is then the only guard on the account." >&2; return 1; }
        echo "ASSUME_YES=1: deploying to account $ACCOUNT (EXPECTED_ACCOUNT) without asking."
        approval=(--require-approval never)
    else
        printf 'Type the account id (%s) to deploy: ' "$ACCOUNT"
        read -r answer
        [ "$answer" = "$ACCOUNT" ] || { echo "Not confirmed."; return 1; }
        # the default approval level stays on: CDK asks before creating IAM roles or opening network access
    fi
    (cd "$REPO_DIR/infra" && PATH="$VENV/bin:$PATH" npx aws-cdk deploy "${CDK_FLAGS[@]}" ${approval[@]+"${approval[@]}"})
}

stack_output() { # stack_output KEY
    aws_json cloudformation describe-stacks --stack-name "$STACK_NAME" \
        | jq -r --arg k "$1" '.Stacks[0].Outputs[] | select(.OutputKey == $k) | .OutputValue'
}

cmd_image() {
    local platform repo sha img
    case "$CPU_ARCH" in ARM64) platform=linux/arm64 ;; X86_64) platform=linux/amd64 ;; esac
    repo="$(stack_output RepositoryUri)"
    [ -n "$repo" ] || { echo "ERROR: the $STACK_NAME stack has no RepositoryUri output (deploy it first)." >&2; return 1; }
    sha="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    img="claude-ecs-base:$sha"
    echo "Building $img for $platform (the stack runs $CPU_ARCH):"
    (cd "$REPO_DIR" && docker buildx build --platform "$platform" --target ecs-base -t "$img" --load .)
    echo "Smoke test before anything is pushed:"
    (cd "$REPO_DIR" && scripts/ci/smoke-ecs.sh "$img" base)
    aws ecr get-login-password | docker login --username AWS --password-stdin "${repo%%/*}"
    docker tag "$img" "$repo:latest"
    docker tag "$img" "$repo:$sha"
    docker push "$repo:latest"
    docker push "$repo:$sha"
    echo "Pushed $repo:latest and :$sha"
}

cmd_secret() {
    local key tmp
    echo "Use a NEW Anthropic API key made for this stack only, with its own spend limit."
    echo "Never reuse a product or CI key."
    printf 'Key (hidden): '
    read -rs key
    echo
    case "$key" in sk-ant-*) ;; *) echo "ERROR: that does not look like an Anthropic key (sk-ant-...)." >&2; return 1 ;; esac
    tmp="$(mktemp)"; chmod 600 "$tmp"
    printf '%s' "$key" > "$tmp"
    key=""
    aws secretsmanager put-secret-value --secret-id claude-ecs/anthropic-api-key --secret-string "file://$tmp" >/dev/null
    rm -f "$tmp"
    echo "Stored in claude-ecs/anthropic-api-key."
}

cmd_verify() {
    local bad=0 base ident now want n
    # vcheck OK_TEXT FAIL_TEXT ACTUAL EXPECTED: counts a failure when they differ
    vcheck() {
        if [ "$3" = "$4" ]; then
            echo "  [OK]   $1"
        else
            echo "  [FAIL] $2"; bad=1
        fi
    }
    [ -f "$BASELINE_FILE" ] || { echo "ERROR: no baseline ($BASELINE_FILE); run preflight first." >&2; return 1; }
    base="$(cat "$BASELINE_FILE")"
    echo "Verify against the baseline:"
    ident="$(aws_json sts get-caller-identity)" || { echo "  [FAIL] no credentials"; return 1; }
    vcheck "same account as the baseline" "different account from the baseline" \
        "$(echo "$ident" | jq -r .Account)" "$(echo "$base" | jq -r .account)"
    now="$(aws_json cloudformation describe-stacks --stack-name CDKToolkit | jq -r '.Stacks[0].LastUpdatedTime // .Stacks[0].CreationTime')" || now="?"
    want="$(echo "$base" | jq -r .cdkToolkitUpdated)"
    vcheck "CDKToolkit unchanged ($now)" "CDKToolkit changed: $want -> $now" "$now" "$want"
    for n in $(echo "$base" | jq -r '.pipelines | keys[]'); do
        now="$(aws_json codepipeline list-pipeline-executions --pipeline-name "$n" --max-items 1 | jq -r '.pipelineExecutionSummaries[0].pipelineExecutionId // "none"')"
        want="$(echo "$base" | jq -r --arg n "$n" '.pipelines[$n]')"
        vcheck "$n: no new execution" "$n: new execution $now (was $want)" "$now" "$want"
    done
    now="$(aws_json cloudformation describe-stacks --stack-name "$STACK_NAME" | jq -r '.Stacks[0].StackStatus')" || now="missing"
    case "$now" in CREATE_COMPLETE|UPDATE_COMPLETE) echo "  [OK]   stack $STACK_NAME: $now" ;; *) echo "  [FAIL] stack $STACK_NAME: $now"; bad=1 ;; esac
    local project untagged
    project="$(echo "$TAGS_JSON" | jq -r '.Project')"
    n="$(aws_json resourcegroupstaggingapi get-resources --tag-filters "Key=aws:cloudformation:stack-name,Values=$STACK_NAME" \
        | jq -r --arg p "$project" '[.ResourceTagMappingList[] | select([.Tags[] | select(.Key == "Project" and .Value == $p)] | length == 0)] | length')" || n="?"
    untagged="$n"
    vcheck "every tagged stack resource carries Project=$project" \
        "$untagged stack resource(s) without Project=$project" "$untagged" "0"
    n="$(aws_json ecr describe-images --repository-name claude-ecs | jq '.imageDetails | length')" || n=0
    [ "$n" -gt 0 ] && echo "  [OK]   $n image(s) in the repository" || echo "  [INFO] no image pushed yet"
    return "$bad"
}

main() {
    CONFIG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) break ;;
        esac
    done
    local cmd="${1:-}"
    case "$cmd" in
        preflight|stack|image|secret|verify) ;;
        *) usage >&2; return 2 ;;
    esac
    for tool in aws jq awk; do
        command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found." >&2; return 2; }
    done
    load_settings
    "cmd_$cmd"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
