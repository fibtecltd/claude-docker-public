#!/bin/bash
# run-task.sh against a stubbed AWS CLI v1: numeric timestamps, no `logs tail`.
# No network, no account. Run:  scripts/run/test-run-task.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export WORK

cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
case "$1 $2" in
    "ecs run-task") echo '{"tasks":[{"taskArn":"arn:aws:ecs:eu-west-1:123456789012:task/claude-ecs/abc123"}]}' ;;
    "ecs describe-tasks")
        # AWS CLI v1 prints epoch seconds, not ISO strings.
        echo '{"tasks":[{"lastStatus":"STOPPED","stoppedReason":"Essential container exited",
          "createdAt":1760435000.1,"pullStartedAt":1760435012.4,"pullStoppedAt":1760435017.9,
          "startedAt":1760435020.2,"stoppedAt":1760435023.8,
          "containers":[{"exitCode":0}]}]}' ;;
    "logs tail") echo "aws: error: argument operation: Invalid choice, valid choices are: ..." >&2; exit 252 ;;
    "logs get-log-events") echo '{"events":[{"message":"first line"},{"message":"ok"}]}' ;;
    *) echo "stub aws: unexpected call: $*" >&2; exit 254 ;;
esac
STUB
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export CLAUDE_ECS_CLUSTER=claude-ecs CLAUDE_ECS_SUBNETS=subnet-a CLAUDE_ECS_SECURITY_GROUP=sg-1 \
    CLAUDE_ECS_ASSIGN_PUBLIC_IP=ENABLED CLAUDE_ECS_POLL_SECONDS=0

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }

OUT="$("$SCRIPT_DIR/run-task.sh" --profile core --prompt hi --max-turns 1 --max-budget-usd 0.25 2>&1)" && RC=0 || RC=$?
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

if [ "$RC" = 0 ]; then ok "exit code follows the container"; else fail "exit $RC"; echo "$OUT" >&2; fi
if has "first line"; then ok "logs come from get-log-events when 'logs tail' is missing"; else fail "no logs"; echo "$OUT" >&2; fi
if has "provisioning (created -> image pull start): 12s"; then ok "numeric timestamps: provisioning"; else fail "provisioning"; echo "$OUT" >&2; fi
if has "image pull:                                 5s"; then ok "numeric timestamps: image pull"; else fail "image pull"; echo "$OUT" >&2; fi
if has "start-up (created -> running):              20s"; then ok "numeric timestamps: start-up"; else fail "start-up"; echo "$OUT" >&2; fi
if has "run (running -> stopped):                   3s"; then ok "numeric timestamps: run"; else fail "run"; echo "$OUT" >&2; fi

if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
