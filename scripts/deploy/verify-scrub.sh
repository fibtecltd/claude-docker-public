#!/usr/bin/env bash
# ============================================================
# verify-scrub.sh - does the credential scrub work inside a real Fargate task?
#
#   scripts/deploy/verify-scrub.sh [--config FILE] [--env-file FILE] [--skip-image]
#
# The image ships with CLAUDE_CODE_SUBPROCESS_ENV_SCRUB off. This script switches it on for one
# guardrail run and reads the answer. One step after the other:
#   1. identity   the AWS credentials must belong to EXPECTED_ACCOUNT (settings file)
#   2. digest     which image `latest` points at now
#   3. image      build, smoke-test and push the image (skipped with --skip-image)
#   4. G4 runs    ecs-in-docker.sh runs --groups G4: the role/egress run switches the scrub on and
#                 has the agent run six commands (caps add up to USD 0.55)
#   5. verdict    read from the G4b row of first-runs-report.md: the key is hidden from a command,
#                 no /proc/*/environ holds it, and whether sts still shows the task role
#   6. diagnosis  only when the verdict is not a pass: one task with the scrub OFF that asks
#                 bubblewrap and the kernel directly (cap USD 0.30)
# It ends with a summary to paste back. Nothing here changes the stack, and the pushed image does
# nothing different unless a run switches the scrub on, so there is nothing to roll back.
#
# Exit code: 0 the scrub works in a Fargate task; 1 it does not, or could not be checked;
# 2 a usage or configuration error (nothing was started).
# Needs: Docker, and the same AWS credentials as ecs-in-docker.sh. Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="${ECS_IN_DOCKER:-$SCRIPT_DIR/ecs-in-docker.sh}"
REPORT="$REPO_DIR/first-runs-report.md"

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "verify-scrub: $*" >&2; exit 2; }
step() { printf '\n== %s ==\n' "$*"; }

CONFIG="" ENV_FILE="" SKIP_IMAGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --env-file) ENV_FILE="${2:?--env-file needs a file}"; shift 2 ;;
        --skip-image) SKIP_IMAGE=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[ -n "$CONFIG" ] || CONFIG="$REPO_DIR/scripts/private/fibtec.env"
[ -f "$CONFIG" ] || die "no settings file $CONFIG (pass --config FILE)"
# The settings file is a shell file; EXPECTED_ACCOUNT in it is the guard on the account.
# shellcheck disable=SC1090
EXPECTED="$(. "$CONFIG"; printf '%s' "${EXPECTED_ACCOUNT:-}")"
[ -n "$EXPECTED" ] || die "EXPECTED_ACCOUNT is not set in $CONFIG: it is the only guard on the account"

wrap=("$WRAPPER" --config "$CONFIG")
[ -z "$ENV_FILE" ] || wrap+=(--env-file "$ENV_FILE")
w() { "${wrap[@]}" "$@"; }

# What the diagnostic task is asked to run (scrub off, so the Bash tool works even if bubblewrap does not).
IFS= read -r -d '' DIAG_PROMPT <<'EOF' || true
Read-only: run these commands one at a time and report the exit code and the first 5 lines of output of each, nothing else.
1) `bwrap --version`
2) `cat /proc/sys/user/max_user_namespaces`
3) `bwrap --unshare-pid --ro-bind / / true; echo exit=$?`
4) `env | cut -d= -f1 | sort`
Never print the value of any variable.
EOF
DIAG_PROMPT="${DIAG_PROMPT//$'\n'/ }"
DIAG_PROMPT="${DIAG_PROMPT% }"

latest_digest() { # the digest `latest` points at, or "none"
    local d
    d="$(w exec aws ecr describe-images --repository-name claude-ecs --image-ids imageTag=latest \
        --query 'imageDetails[0].imageDigest' --output text 2>/dev/null | tail -n 1)" || d=""
    case "$d" in "" | None) echo none ;; *) echo "$d" ;; esac
}

step "1. identity"
if ! IDENT="$(w identity 2>&1)"; then
    printf '%s\n' "$IDENT" >&2
    die "could not read the AWS identity (see above)"
fi
ACCOUNT="$(printf '%s' "$IDENT" | tr -d '\n' | sed -n 's/.*"Account": *"\([0-9]*\)".*/\1/p')"
[ -n "$ACCOUNT" ] || die "could not read the account from: $IDENT"
[ "$ACCOUNT" = "$EXPECTED" ] || die "the credentials belong to another account than EXPECTED_ACCOUNT in $CONFIG: nothing was started"
echo "the credentials belong to EXPECTED_ACCOUNT"

step "2. image before"
OLD="$(latest_digest)"
echo "latest = $(printf '%s' "$OLD" | cut -c1-19)"

step "3. image"
NEW="$OLD"
if [ "$SKIP_IMAGE" = 1 ]; then
    echo "skipped (--skip-image): the image already in ECR is what runs"
else
    w image || { echo "verify-scrub: the image step failed (see above); nothing was run" >&2; exit 1; }
    NEW="$(latest_digest)"
    echo "latest = $(printf '%s' "$NEW" | cut -c1-19)"
fi

step "4. guardrail runs (G4, caps add up to USD 0.55)"
rm -f "$REPORT"
RUNS_RC=0
w runs --groups G4 || RUNS_RC=$?

step "5. verdict"
ROW=""
[ ! -f "$REPORT" ] || ROW="$(grep -F '| G4-role-egress |' "$REPORT" | grep -F 'key hidden:' | head -n 1 || true)"
field() { printf '%s' "$ROW" | sed -n "s/.*$1: \\([A-Za-z]*\\).*/\\1/p"; }
KEYHID="$(field 'key hidden')"; PROC="$(field 'proc clean')"; ROLE="$(field 'role')"
DESIGNED="$(printf '%s' "$ROW" | awk -F'|' 'NF > 4 { gsub(/ /, "", $(NF - 1)); print $(NF - 1) }')"
VERDICT="FAIL"
REASON=""
if [ -z "$ROW" ]; then
    REASON="no G4b row in $REPORT: the run did not finish or the report is missing"
elif [ "$KEYHID" = "yes" ] && [ "$PROC" = "yes" ]; then
    VERDICT="PASS"
    REASON="the key is hidden from a command and no /proc/*/environ holds it"
    [ "$ROLE" = "yes" ] || REASON="$REASON; but sts no longer shows the task role (the scrub may have removed the container credentials)"
else
    REASON="the scrub did not hold, or the agent could not run its commands"
fi
echo "key hidden from a command:   ${KEYHID:-n/a}"
echo "no /proc/*/environ has it:   ${PROC:-n/a}"
echo "sts shows the task role:     ${ROLE:-n/a}"
echo "G4b as designed (all six):   ${DESIGNED:-n/a}"
echo "verdict: $VERDICT - $REASON"

if [ "$VERDICT" != "PASS" ]; then
    step "6. diagnosis (scrub OFF, cap USD 0.30)"
    w exec scripts/run/run-task.sh --profile core --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
        --max-turns 6 --max-budget-usd 0.30 --output-format json --prompt "$DIAG_PROMPT" || true
    echo "Read the exit= line of command 3: non-zero means bubblewrap cannot create its namespaces in this task."
fi

step "summary (paste this back)"
echo "image:        before $(printf '%s' "$OLD" | cut -c1-19), after $(printf '%s' "$NEW" | cut -c1-19)"
[ ! -f "$REPORT" ] || grep -E 'tasks still running|ecs-deploy.sh .verify. \(exit|^\*\*(Spend|Behaved)' "$REPORT" || true
[ -z "$ROW" ] || echo "G4b row:      $ROW"
echo "runs exit:    $RUNS_RC"
echo "verdict:      $VERDICT - $REASON"
echo "report:       $REPORT"
[ "$VERDICT" = "PASS" ]
