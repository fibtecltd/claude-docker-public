#!/bin/bash
# Tests for ecs-deploy.sh against a stubbed `aws`: no network, no account is touched.
# Run:  scripts/deploy/test-ecs-deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/ecs-deploy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"
BIN="$WORK/bin"
mkdir -p "$BIN"
export FIX WORK

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }

# The stub answers from files: $FIX/<service>_<operation>[_<arg value>].json, or .err for a failure.
cat > "$BIN/aws" <<'STUB'
#!/bin/bash
svc="$1"; op="$2"; shift 2
echo "$svc $op $*" >> "$WORK/aws.log"
all="$*"
case "$all" in *file://*) f="${all##*file://}"; f="${f%% *}"; cp "$f" "$WORK/secret.copy" ;; esac
key="${svc}_${op}"
prev=""
for a in "$@"; do
    case "$prev" in
        --stack-name|--quota-code|--name|--pipeline-name) [ -f "$FIX/${key}_$a.json" ] || [ -f "$FIX/${key}_$a.err" ] && key="${key}_$a" ;;
    esac
    prev="$a"
done
if [ -f "$FIX/$key.err" ]; then cat "$FIX/$key.err" >&2; exit 254; fi
if [ -f "$FIX/$key.json" ]; then cat "$FIX/$key.json"; exit 0; fi
echo "stub: no fixture for $key" >&2
exit 254
STUB
cat > "$BIN/npx" <<'STUB'
#!/bin/bash
echo "$*" >> "$WORK/npx.log"
case "$2" in diff) cat "$FIX/npx_diff.txt" ;; esac
STUB
chmod +x "$BIN/aws" "$BIN/npx"
export PATH="$BIN:$PATH"
mkdir -p "$WORK/venv/bin" && ln -s "$(command -v python3)" "$WORK/venv/bin/python"
export ECS_DEPLOY_VENV="$WORK/venv"

put()  { printf '%s\n' "$2" > "$FIX/$1.json"; rm -f "$FIX/$1.err"; }
err()  { printf '%s\n' "$2" > "$FIX/$1.err"; rm -f "$FIX/$1.json"; }

good() {
    rm -rf "$FIX"; mkdir -p "$FIX"
    put sts_get-caller-identity '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/alice","UserId":"X"}'
    err cloudformation_describe-stacks_claude-ecs 'An error occurred (ValidationError): Stack with id claude-ecs does not exist'
    put cloudformation_describe-stacks_CDKToolkit '{"Stacks":[{"StackStatus":"UPDATE_COMPLETE","LastUpdatedTime":"2026-01-01T00:00:00Z"}]}'
    err ecr_describe-repositories 'An error occurred (RepositoryNotFoundException): not found'
    put ecs_describe-clusters '{"clusters":[],"failures":[{"reason":"MISSING"}]}'
    put logs_describe-log-groups '{"logGroups":[]}'
    put secretsmanager_list-secrets '{"SecretList":[]}'
    put ssm_get-parameter '{"Parameter":{"Value":"21"}}'
    put service-quotas_get-service-quota_L-3032A538 '{"Quota":{"Value":40}}'
    put service-quotas_get-service-quota_L-F678F1CE '{"Quota":{"Value":5}}'
    put secretsmanager_put-secret-value '{}'
    put ecs_list-clusters '{"clusterArns":["arn:c1"]}'
    put ecs_list-tasks '{"taskArns":["arn:t1","arn:t2"]}'
    put ecs_describe-tasks '{"tasks":[{"launchType":"FARGATE","cpu":"512"},{"launchType":"FARGATE","cpu":"512"}]}'
    put ec2_describe-vpcs '{"Vpcs":[{},{}]}'
    put codepipeline_list-pipelines '{"pipelines":[{"name":"app-dev-pipeline"},{"name":"other"}]}'
    put codepipeline_get-pipeline-state '{"stageStates":[{"actionStates":[{"actionName":"Approve","latestExecution":{"status":"InProgress"}},{"actionName":"Deploy","latestExecution":{"status":"Succeeded"}}]}]}'
    put codepipeline_list-pipeline-executions '{"pipelineExecutionSummaries":[{"pipelineExecutionId":"exec-1","status":"Succeeded"}]}'
    put budgets_describe-budgets '{"Budgets":[{"BudgetName":"monthly","BudgetLimit":{"Amount":"1000","Unit":"USD"},"CalculatedSpend":{"ActualSpend":{"Amount":"500"}}}]}'
    err organizations_describe-organization 'An error occurred (AWSOrganizationsNotInUseException): not in use'
    put resourcegroupstaggingapi_get-resources '{"ResourceTagMappingList":[{"Tags":[{"Key":"Project","Value":"common"},{"Key":"Owner","Value":"acme"}]}]}'
    cat > "$WORK/template.json" <<'JSON'
{"Rules":{"CheckBootstrapVersion":{"Assertions":[{"AssertDescription":"CDK bootstrap stack version 6 required. Please run 'cdk bootstrap'."}]}},
 "Resources":{"Repo":{"Type":"AWS::ECR::Repository","Properties":{"Tags":[{"Key":"Owner","Value":"acme"},{"Key":"Project","Value":"common"}]}}}}
JSON
    cat > "$WORK/config" <<'CFG'
AWS_REGION=eu-west-1
EXPECTED_ACCOUNT=123456789012
FORBIDDEN_PRINCIPAL_REGEX='user/ci-deployer$'
TAGS_JSON='{"Project":"common","Owner":"acme"}'
RESERVED_VCPU=12
WATCH_PIPELINE_PREFIX=app-
CFG
    export TEMPLATE_OVERRIDE="$WORK/template.json"
    export BASELINE_FILE="$WORK/baseline.json" DIFF_FILE="$WORK/diff.txt"
}

run_preflight() { OUT="$("$DEPLOY" --config "$WORK/config" preflight 2>&1)" && RC=0 || RC=$?; }
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}

good; run_preflight;                  expect "everything fine: GO, exit 0" 0 "Verdict: GO."
if [ -s "$BASELINE_FILE" ]; then ok "preflight writes a baseline"; else fail "no baseline written"; fi

good; put sts_get-caller-identity '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/ci-deployer"}'
run_preflight;                        expect "the forbidden CI identity is NO-GO" 1 "is not allowed for this deploy"
good; put sts_get-caller-identity '{"Account":"999900001111","Arn":"arn:aws:iam::123456789012:user/alice"}'
run_preflight;                        expect "another account is NO-GO" 1 "expected 123456789012"
good; err sts_get-caller-identity 'Unable to locate credentials'
run_preflight;                        expect "no credentials stops the run" 1 "no usable AWS credentials"
good; put ecr_describe-repositories '{"repositories":[{"repositoryName":"claude-ecs"}]}'
run_preflight;                        expect "an existing ECR repository is NO-GO" 1 "ecr-repository"
good; put cloudformation_describe-stacks_claude-ecs '{"Stacks":[{"StackStatus":"CREATE_COMPLETE"}]}'
run_preflight;                        expect "an existing stack is NO-GO" 1 "stack"
good; err ssm_get-parameter 'An error occurred (ParameterNotFound): nope'
run_preflight;                        expect "a missing bootstrap is NO-GO and is never created" 1 "never bootstraps"
good; put ssm_get-parameter '{"Parameter":{"Value":"4"}}'
run_preflight;                        expect "an old bootstrap is NO-GO" 1 "below the 6"
good; put service-quotas_get-service-quota_L-3032A538 '{"Quota":{"Value":16}}'
run_preflight;                        expect "low Fargate headroom is NO-GO (16 - 1 - 12 = 3 < 4)" 1 "free 3"
good; put service-quotas_get-service-quota_L-F678F1CE '{"Quota":{"Value":2}}'
run_preflight;                        expect "no free VPC is NO-GO" 1 "2 of 2 used"
good; err service-quotas_get-service-quota_L-3032A538 'An error occurred (AccessDeniedException): denied'
err service-quotas_list-service-quotas 'An error occurred (AccessDeniedException): denied'
run_preflight;                        expect "a denied quota read is UNKNOWN, exit 2" 2 "[UNKNOWN]"
good; put codepipeline_get-pipeline-state '{"stageStates":[{"actionStates":[{"actionName":"Deploy","latestExecution":{"status":"InProgress"}}]}]}'
run_preflight;                        expect "a pipeline deploying is NO-GO" 1 "work in progress"
good;                                 run_preflight; expect "a pipeline waiting on an approval is fine" 0 "idle"
good; put budgets_describe-budgets '{"Budgets":[{"BudgetName":"monthly","BudgetLimit":{"Amount":"1000","Unit":"USD"},"CalculatedSpend":{"ActualSpend":{"Amount":"850"}}}]}'
run_preflight;                        expect "a budget at 85% is NO-GO" 1 "at or above 80%"
BUDGET_ALERT_PCT=0 run_preflight;     expect "BUDGET_ALERT_PCT=0 lists the budget but does not block" 0 "not blocking"
good; put organizations_describe-organization '{"Organization":{"Id":"o-1"}}'
run_preflight;                        expect "an Organization is UNKNOWN (check SCPs by hand)" 2 "service control policies"
good; put resourcegroupstaggingapi_get-resources '{"ResourceTagMappingList":[{"Tags":[{"Key":"Project","Value":"common"},{"Key":"Owner","Value":"someone-else"}]}]}'
run_preflight;                        expect "a tag value that differs from the convention is NO-GO" 1 "Owner(existing: someone-else, planned: acme)"
good; cat > "$WORK/template.json" <<'JSON'
{"Rules":{"CheckBootstrapVersion":{"Assertions":[{"AssertDescription":"CDK bootstrap stack version 6 required."}]}},
 "Resources":{"Repo":{"Type":"AWS::ECR::Repository","Properties":{"Tags":[{"Key":"Project","Value":"claude-ecs"}]}}}}
JSON
run_preflight;                        expect "a template without the planned tags is NO-GO" 1 "lacks or differs on"

# verify: same account, nothing moved
good; run_preflight
OUT="$("$DEPLOY" --config "$WORK/config" verify 2>&1)" && RC=0 || RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "stack claude-ecs"; then ok "verify fails while the stack is absent"; else fail "verify should fail without the stack"; echo "$OUT" >&2; fi
put cloudformation_describe-stacks_claude-ecs '{"Stacks":[{"StackStatus":"CREATE_COMPLETE"}]}'
put resourcegroupstaggingapi_get-resources '{"ResourceTagMappingList":[{"Tags":[{"Key":"Project","Value":"common"}]}]}'
put ecr_describe-images '{"imageDetails":[{}]}'
OUT="$("$DEPLOY" --config "$WORK/config" verify 2>&1)" && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "no new execution"; then ok "verify passes when nothing moved"; else fail "verify should pass"; echo "$OUT" >&2; fi
put codepipeline_list-pipeline-executions '{"pipelineExecutionSummaries":[{"pipelineExecutionId":"exec-2","status":"InProgress"}]}'
OUT="$("$DEPLOY" --config "$WORK/config" verify 2>&1)" && RC=0 || RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "new execution exec-2"; then ok "verify fails when a pipeline started"; else fail "verify should flag a new execution"; echo "$OUT" >&2; fi

# stack: the deploy only happens after a clean preflight, a create-only diff and the typed account id
stack() { OUT="$("$DEPLOY" --config "$WORK/config" stack 2>&1 <<<"$1")" && RC=0 || RC=$?; }
printf '[+] AWS::ECR::Repository Repository\n[+] AWS::ECS::Cluster Cluster\n' > "$FIX/npx_diff.txt"
rm -f "$WORK/npx.log"; good_with_template() { good; printf '[+] AWS::ECR::Repository Repository\n' > "$FIX/npx_diff.txt"; }

good_with_template; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" = 0 ] && grep -q "^aws-cdk deploy" "$WORK/npx.log" && grep -q "cpu_architecture=ARM64" "$WORK/npx.log" && grep -q "tags=" "$WORK/npx.log"; then
    ok "stack deploys after a clean preflight, a create-only diff and the right account id"
else fail "stack should deploy"; echo "$OUT" >&2; cat "$WORK/npx.log" >&2 || true; fi
if grep -q "bootstrap" "$WORK/npx.log"; then fail "bootstrap must never run"; else ok "bootstrap is never run"; fi

good_with_template; rm -f "$WORK/npx.log"; stack "wrong"
if [ "$RC" != 0 ] && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "a wrong confirmation does not deploy"; else fail "wrong confirmation deployed"; fi

good_with_template; printf '[~] AWS::IAM::Role CDKToolkit/Role\n' >> "$FIX/npx_diff.txt"; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "touches existing resources" && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then
    ok "a diff that changes existing resources does not deploy"
else fail "changing diff should stop"; echo "$OUT" >&2; fi

# a new stack's diff always carries its own BootstrapVersion parameter and rule: that must not stop it
good_with_template; cat >> "$FIX/npx_diff.txt" <<'DIFF'
Stack claude-ecs
Parameters
[+] Parameter BootstrapVersion BootstrapVersion: {"Type":"AWS::SSM::Parameter::Value<String>","Default":"/cdk-bootstrap/hnb659fds/version"}
Other Changes
[+] Unknown Rules: {"CheckBootstrapVersion":{"Assertions":[{"AssertDescription":"CDK bootstrap stack version 6 required. Please run 'cdk bootstrap'."}]}}
DIFF
rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" = 0 ] && grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "the BootstrapVersion parameter and rule of a new stack do not stop the deploy"
else fail "bootstrap parameter in the diff stopped the deploy"; echo "$OUT" >&2; fi
if printf '%s' "$OUT" | grep -q "AWS::ECR::Repository Repository"; then ok "...and the diff lists what will be created"; else fail "created items not listed"; echo "$OUT" >&2; fi

# CLI notices and parameter descriptions may talk about the bootstrap stack: only the diff proper counts
good_with_template; printf 'Stack claude-ecs\n\nNOTICES\n\n29483 Update your CDKToolkit bootstrap stack to the latest version (bootstrap)\n' >> "$FIX/npx_diff.txt"
rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" = 0 ] && grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "notices that mention CDKToolkit and bootstrap do not stop the deploy"
else fail "notices stopped the deploy"; echo "$OUT" >&2; fi

good_with_template; printf '[+] AWS::IAM::Role CDKToolkit/Role CDKToolkitRole1\n' >> "$FIX/npx_diff.txt"; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "CDKToolkit/Role" && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "an item for the bootstrap stack stops the deploy, and is shown"
else fail "a CDKToolkit item should stop"; echo "$OUT" >&2; fi

good_with_template; printf 'Stack CDKToolkit\n' >> "$FIX/npx_diff.txt"; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "other than claude-ecs" && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "a diff that names the bootstrap stack does not deploy"
else fail "CDKToolkit in the diff should stop"; echo "$OUT" >&2; fi

good_with_template; printf 'Stack some-other-stack\n' >> "$FIX/npx_diff.txt"; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "a diff that names another stack does not deploy"; else fail "another stack should stop"; echo "$OUT" >&2; fi

good_with_template; printf 'Unable to resolve AWS account\n' > "$FIX/npx_diff.txt"; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "cdk diff probably failed" && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "a diff with nothing to create (cdk failed) does not deploy"
else fail "an empty diff should stop"; echo "$OUT" >&2; fi

# ASSUME_YES=1: nothing is asked, CDK's own approval is off, the account is still pinned
good_with_template; rm -f "$WORK/npx.log"
OUT="$(ASSUME_YES=1 "$DEPLOY" --config "$WORK/config" stack 2>&1 </dev/null)" && RC=0 || RC=$?
if [ "$RC" = 0 ] && grep -q "^aws-cdk deploy .*--require-approval never" "$WORK/npx.log"; then ok "ASSUME_YES=1 deploys without asking, with CDK approval off"
else fail "ASSUME_YES should deploy"; echo "$OUT" >&2; cat "$WORK/npx.log" >&2 || true; fi
good_with_template; rm -f "$WORK/npx.log"; stack "123456789012"
if grep -q "require-approval" "$WORK/npx.log"; then fail "approval must stay on by default"; else ok "without ASSUME_YES CDK's approval stays on"; fi
good_with_template; put sts_get-caller-identity '{"Account":"999900001111","Arn":"arn:aws:iam::123456789012:user/alice"}'; rm -f "$WORK/npx.log"
OUT="$(ASSUME_YES=1 "$DEPLOY" --config "$WORK/config" stack 2>&1 </dev/null)" && RC=0 || RC=$?
if [ "$RC" != 0 ] && [ ! -f "$WORK/npx.log" ]; then ok "ASSUME_YES=1 still stops on another account"; else fail "ASSUME_YES deployed to another account"; fi
good_with_template; grep -v '^EXPECTED_ACCOUNT=' "$WORK/config" > "$WORK/config.noaccount"; rm -f "$WORK/npx.log"
OUT="$(ASSUME_YES=1 "$DEPLOY" --config "$WORK/config.noaccount" stack 2>&1 </dev/null)" && RC=0 || RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "needs EXPECTED_ACCOUNT" && ! grep -q "^aws-cdk deploy" "$WORK/npx.log"; then ok "ASSUME_YES=1 without EXPECTED_ACCOUNT is refused"
else fail "ASSUME_YES without an expected account should stop"; echo "$OUT" >&2; fi

good_with_template; put sts_get-caller-identity '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/ci-deployer"}'; rm -f "$WORK/npx.log"; stack "123456789012"
if [ "$RC" != 0 ] && [ ! -f "$WORK/npx.log" ]; then ok "a NO-GO preflight stops before cdk is called at all"; else fail "NO-GO preflight reached cdk"; fi

# secret: the key goes through a file, never through the command line
good; : > "$WORK/aws.log"; rm -f "$WORK/secret.copy"
OUT="$("$DEPLOY" --config "$WORK/config" secret 2>&1 <<<"sk-ant-api03-test-key")" && RC=0 || RC=$?
if [ "$RC" = 0 ] && grep -q "put-secret-value" "$WORK/aws.log" && ! grep -q "sk-ant" "$WORK/aws.log" && grep -q "sk-ant-api03-test-key" "$WORK/secret.copy"; then
    ok "the secret is stored from a file, not from the command line"
else fail "secret handling"; echo "$OUT" >&2; fi
: > "$WORK/aws.log"
OUT="$("$DEPLOY" --config "$WORK/config" secret 2>&1 <<<"not-a-key")" && RC=0 || RC=$?
if [ "$RC" != 0 ] && ! grep -q "put-secret-value" "$WORK/aws.log"; then ok "a value that is not an Anthropic key is refused"; else fail "bad key accepted"; fi

# usage
if "$DEPLOY" >/dev/null 2>&1; then fail "no command should fail"; else ok "no command prints usage and fails"; fi

if [ "$FAILS" -gt 0 ]; then echo "$FAILS test(s) failed." >&2; exit 1; fi
echo "All tests passed."
