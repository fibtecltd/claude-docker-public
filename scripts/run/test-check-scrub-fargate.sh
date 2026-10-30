#!/bin/bash
# Tests for check-scrub-fargate.sh against a stubbed ecs-in-docker.sh: no Docker, no AWS, no API calls.
# Run:  scripts/run/test-check-scrub-fargate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/run" "$REPO/scripts/deploy"
export WORK

# The script works out its repository from its own location, so test a copy (with the library it sources) in a scratch tree.
cp "$SCRIPT_DIR/check-scrub-fargate.sh" "$SCRIPT_DIR/scrub-verdict.sh" "$REPO/scripts/run/"
CHECK="$REPO/scripts/run/check-scrub-fargate.sh"
# shellcheck source-path=SCRIPTDIR source=scrub-verdict.sh
source "$SCRIPT_DIR/scrub-verdict.sh"
PROBE="$(scrub_probe_prompt)"

# What the three tasks print. The account id is one the script must mask.
ACCOUNT=210987654321
PH=$'plain-ok\nplain-key=hidden\nplain-proc=0'
FH=$'key-hidden\nproc-environ-with-key: 0'
PV=$'plain-ok\nplain-key=VISIBLE\nplain-proc=3'
FV=$'key-VISIBLE\nproc-environ-with-key: 3'
REFUSED=$'A variable in braces in this command can\'t be checked before it runs\nA for or select loop in this command can\'t be checked before it runs'
SOCAT_OFF=$'1. `Sandbox is required but failed to initialize: Sandbox dependencies not available: socat not installed. Restart to retry.`\n2. `Accesses /proc/*/environ which may expose secrets`'
BW_ERR='bwrap: No permissions to create new namespace, likely because the kernel does not allow non-privileged user namespaces. See <https://deb.li/bubblewrap> or <file:///usr/share/doc/bubblewrap/README.Debian>.'
NS_ERR="$BW_ERR"$'\nThis command requires approval'
SOCAT_ON=$'socat by Gerhard Rieger and contributors - see www.dest-unreach.org\nsocat version 1.7.4.4 on Jan  1 2024 00:00:00'
export DEF_ON="$NS_ERR"
export DEF_CONTROL="$PV"$'\n'"$FV"
export DEF_BWRAP=$'bubblewrap 0.8.0\nuser-ns exit=1\n'"$BW_ERR"$'\nfresh-proc exit=1\nexisting-proc exit=1\n'"$SOCAT_ON"
export ACCOUNT

# ecs-in-docker.sh stub: logs every call; run-task.sh runs print what run-task.sh prints, with the agent's answer from
# STUB_ON / STUB_CONTROL / STUB_BWRAP, an exit code from STUB_<X>_RC and a start failure from STUB_<X>_NOSTART.
cat > "$REPO/scripts/deploy/ecs-in-docker.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$WORK/wrapper.log"
echo "Read from /Users/ops/claude-docker-ecs/.env: AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"
case "$1" in
    identity)
        [ -z "${STUB_ID_FAIL:-}" ] || { echo "ecs-in-docker: Docker is not running" >&2; exit 1; }
        echo "{\"Account\": \"$ACCOUNT\", \"Arn\": \"arn:aws:iam::$ACCOUNT:user/ops\"}"; exit 0 ;;
    image)
        [ -z "${STUB_IMAGE_FAIL:-}" ] || { echo "smoke test failed" >&2; exit 1; }
        echo "pushed $ACCOUNT.dkr.ecr.eu-west-2.amazonaws.com/claude-ecs:latest"; exit 0 ;;
    exec)
        case "$2" in
            aws)
                case "$3 $4" in
                    "ecr describe-images")
                        [ -z "${STUB_ECR_FAIL:-}" ] || exit 1
                        printf 'sha256:abc123\t2026-10-29T19:00:00+00:00\n'; exit 0 ;;
                    "ecs list-tasks")
                        [ -z "${STUB_RUNNING_FAIL:-}" ] || exit 1
                        echo "${STUB_RUNNING:-0}"; exit 0 ;;
                esac ;;
            scripts/run/run-task.sh)
                all=" $* "
                case "$all" in
                    *"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1"*) X=ON; OUT="${STUB_ON:-$DEF_ON}"; RC="${STUB_ON_RC:-0}"; NOSTART="${STUB_ON_NOSTART:-}" ;;
                    *"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0"*) X=CONTROL; OUT="${STUB_CONTROL:-$DEF_CONTROL}"; RC="${STUB_CONTROL_RC:-0}"; NOSTART="${STUB_CONTROL_NOSTART:-}" ;;
                    *) X=BWRAP; OUT="${STUB_BWRAP:-$DEF_BWRAP}"; RC="${STUB_BWRAP_RC:-0}"; NOSTART="${STUB_BWRAP_NOSTART:-}" ;;
                esac
                if [ -n "$NOSTART" ]; then
                    echo "run-task: could not read the stack outputs of 'claude-ecs' (is it deployed, and are credentials set?)" >&2; exit 2
                fi
                echo "started arn:aws:ecs:eu-west-2:$ACCOUNT:task/claude-ecs/abc123 (FARGATE, core)"
                echo "status: STOPPED"
                echo "--- logs (/claude-ecs, stream core/claude/abc123)"
                printf '%s\n' "$OUT"
                echo "--- summary"
                echo "stopped:     Essential container in task exited"
                echo "container:   exit code $RC"
                echo "run (running -> stopped):                   41s"
                exit "$RC" ;;
        esac ;;
esac
exit 0
STUB
chmod +x "$REPO/scripts/deploy/ecs-in-docker.sh"

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

reset() {
    rm -f "$WORK/wrapper.log" "$REPO"/scrub-check-fargate-*.md "$WORK/report.md"; : > "$WORK/wrapper.log"
    unset STUB_ON STUB_CONTROL STUB_BWRAP STUB_ON_RC STUB_CONTROL_RC STUB_BWRAP_RC STUB_ON_NOSTART STUB_CONTROL_NOSTART \
        STUB_BWRAP_NOSTART STUB_ID_FAIL STUB_IMAGE_FAIL STUB_ECR_FAIL STUB_RUNNING STUB_RUNNING_FAIL
}
checkit() { OUT="$("$CHECK" --report "$WORK/report.md" "$@" 2>&1 < /dev/null)" && RC=0 || RC=$?; }
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF -- "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}
logged() { grep -qF -- "$1" "$WORK/wrapper.log"; }
runs() { grep -c 'scripts/run/run-task.sh' "$WORK/wrapper.log" || true; }
line_of() { grep -nF -m1 -- "$1" "$WORK/wrapper.log" | cut -d: -f1; }

# ── the default case: the scrub is blocked by bubblewrap, the control sees the key, bwrap fails directly ──
reset; checkit
expect "exit 0 when the report is written" 0 "== summary (paste this back) =="
expect "ON: the namespace error is named and quoted whole (the Debian text is 214 characters)" 0 "ON  scrub on, Fargate task: COULD NOT RUN: bubblewrap could not create a namespace; the agent reported: \"$BW_ERR\" (exit 0)"
expect "CONTROL: the key is seen, both forms of the commands ran" 0 "CONTROL  scrub off, same probe: DOES NOT HOLD: key in a command's environment: yes, /proc/*/environ files with the key: 3; the commands with \${} and a loop: ran (exit 0)"
expect "BWRAP: three exit codes, the error and socat's version" 0 "BWRAP  scrub off, bubblewrap called directly: bubblewrap 0.8.0; --unshare-user exit=1, fresh /proc exit=1, existing /proc exit=1; the agent reported: \"$BW_ERR\"; socat: socat version 1.7.4.4 (exit 0)"
expect "the conclusion: cannot run with socat installed" 0 "The scrub cannot run in a Fargate task with socat installed: bubblewrap cannot create what it needs (the BWRAP line)"
check "the AWS identity is asked first" test "$(line_of 'identity')" = 1
check "three tasks are started" test "$(runs)" = 3
check "no image is pushed unless asked" test -z "$(grep -F 'image' "$WORK/wrapper.log" | grep -v 'describe-images' || true)"
check "ON switches the scrub on, with a turn and a spend cap" logged "exec scripts/run/run-task.sh --profile core --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 --max-turns 10 --max-budget-usd 0.30 --prompt Run these five shell commands"
check "ON sends the probe check-scrub-local.sh sends, whole" logged "--prompt $PROBE"
check "CONTROL switches the scrub off explicitly" logged "--env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 --max-turns 10 --max-budget-usd 0.30 --prompt $PROBE"
check "BWRAP leaves the image's setting alone and has its own cap" logged "run-task.sh --profile core --max-turns 10 --max-budget-usd 0.40 --prompt Read-only: run these commands one at a time"
# shellcheck disable=SC2016  # the prompt holds a literal $? and backticks
check "...and asks for bwrap's three namespace variants and socat" logged 'echo existing-proc exit=$?` 5) `socat -V | head -2`'
check "the running tasks are counted at the end" logged "ecs list-tasks --cluster claude-ecs --desired-status RUNNING"
check "no running-task warning when none is running, although the wrapper prints a line of its own first" test -z "$(printf '%s' "$OUT" | grep -F 'Tasks still running on the cluster' || true)"
check "...and the count in the report is the number, not that line" grep -qF "Tasks still running afterwards: 0" "$WORK/report.md"
check "the direct probe asks for each command's output on its own" logged 'never merge or summarise commands'
check "the report is written where asked" test -s "$WORK/report.md"
check "...with the image in ECR" grep -qF "ECR claude-ecs:latest (digest, pushed at): sha256:abc123 2026-10-29T19:00:00+00:00" "$WORK/report.md"
check "...each task's output" grep -q "^## Task BWRAP (exit 0)" "$WORK/report.md"
check "...each task's command with its caps" grep -qF "scripts/run/run-task.sh --profile core --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 --max-turns 10 --max-budget-usd 0.30 --prompt <the probe>" "$WORK/report.md"
check "...and the summary" grep -qF "conclusion: " "$WORK/report.md"
check "the account id is masked on screen" test -z "$(printf '%s' "$OUT" | grep -F "$ACCOUNT" || true)"
check "...and in the report" test -z "$(grep -F "$ACCOUNT" "$WORK/report.md" || true)"
check "...and replaced by a placeholder" grep -qF "123456789012" "$WORK/report.md"

# ── the key is redacted ──
digit=3; LOOKALIKE="sk-ant-api0${digit}-REALLOOKINGSECRET123"
reset; export STUB_ON="$LOOKALIKE plain-ok"; checkit
check "anything shaped like an Anthropic key is redacted in the report" test -z "$(grep -F 'REALLOOKINGSECRET123' "$WORK/report.md" || true)"
check "...and on screen" test -z "$(printf '%s' "$OUT" | grep -F 'REALLOOKINGSECRET123' || true)"
check "...and replaced by a marker" grep -qF 'sk-ant-REDACTED' "$WORK/report.md"

# ── the other conclusions ──
reset; export STUB_ON="$SOCAT_OFF"; checkit
expect "socat missing, seen by the scrub-on task: the cause is quoted" 0 "ON  scrub on, Fargate task: COULD NOT RUN: every command was blocked, even a trivial one; the agent reported: \"Sandbox is required but failed to initialize: Sandbox dependencies not available: socat not installed. Restart to retry.\" (exit 0)"
expect "...and the conclusion says to push the image" 0 "socat is missing from the image these tasks ran, so this says nothing about bubblewrap yet: run again with --push-image"
reset; export STUB_BWRAP=$'bubblewrap 0.8.0\nuser-ns exit=1\nbash: socat: command not found'; checkit
expect "socat missing, seen by the direct task" 0 "; socat: NOT INSTALLED (exit 0)"
expect "...and the conclusion says to push the image" 0 "run again with --push-image"
reset; export STUB_ON="$PH"$'\n'"$FH" STUB_BWRAP=$'bubblewrap 0.8.0\nuser-ns exit=0\nfresh-proc exit=0\nexisting-proc exit=0\nsocat version 1.7.4.4'; checkit
expect "the scrub works: the key is hidden and no /proc file holds it" 0 "ON  scrub on, Fargate task: WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it; the commands with \${} and a loop: ran (exit 0)"
expect "...the conclusion says so" 0 "Claude Code's scrub works in a Fargate task"
expect "...and the direct task shows no error" 0 "--unshare-user exit=0, fresh /proc exit=0, existing /proc exit=0; socat: socat version 1.7.4.4 (exit 0)"
reset; export STUB_ON="$PH"$'\n'"$REFUSED"; checkit
expect "plain commands that run while the \${}/loop ones are refused are reported as refused" 0 "WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it; the commands with \${} and a loop: refused (exit 0)"
expect "...with the warning about first-runs.sh" 0 "scripts/run/first-runs.sh checks the key and /proc/*/environ (G4b, commands 5 and 6) with that kind of command"
reset; export STUB_ON="$PV"$'\n'"$FV"; checkit
expect "the scrub on and the key still visible is concluded as such" 0 "The scrub starts in a Fargate task, but the key is still visible to a command or to /proc/*/environ"
reset; export STUB_BWRAP=$'bubblewrap 0.8.0\nuser-ns exit=0\nfresh-proc exit=1\nexisting-proc exit=0\nsocat version 1.7.4.4'; checkit
expect "each direct exit code is shown as it is" 0 "bubblewrap 0.8.0; --unshare-user exit=0, fresh /proc exit=1, existing /proc exit=0; socat: socat version 1.7.4.4 (exit 0)"
expect "...and one non-zero exit is a bubblewrap failure" 0 "The scrub cannot run in a Fargate task with socat installed"
# A real task: the agent merged the three bwrap commands into one answer and gave no "user-ns exit=N" lines.
reset; export STUB_BWRAP=$'bubblewrap 0.8.0\nAll three bwrap probes failed:\n'"$BW_ERR"$'\nsocat version 1.7.4.4'; checkit
expect "a bwrap error line counts as a failure when the exit codes are not reported one by one" 0 "BWRAP  scrub off, bubblewrap called directly: bubblewrap 0.8.0; --unshare-user exit=n/a, fresh /proc exit=n/a, existing /proc exit=n/a; the agent reported: \"$BW_ERR\"; socat: socat version 1.7.4.4 (exit 0)"
expect "...so the conclusion is that it cannot run, not that there is no answer" 0 "The scrub cannot run in a Fargate task with socat installed"
reset; export STUB_BWRAP="nothing useful"; checkit
expect "a direct task with no marker says so" 0 "BWRAP  scrub off, bubblewrap called directly: COULD NOT RUN: no marker in the output (see the log) (exit 0)"
expect "...and the conclusion does not claim a cause" 0 "No clear answer"
reset; export STUB_ON=$'1. `printf \'plain-%s\\n\' ok` failed with `bwrap: pivot_root: Operation not permitted`.'; checkit
expect "a bwrap error that is not the namespace error is not called one" 0 "ON  scrub on, Fargate task: COULD NOT RUN: bubblewrap failed; the agent reported: \"bwrap: pivot_root: Operation not permitted\" (exit 0)"

# ── tasks that do not run ──
reset; export STUB_ON_NOSTART=1; checkit
expect "a task that could not start is not read as a result" 0 "ON  scrub on, Fargate task: COULD NOT RUN: the task did not finish (could not read the stack outputs of 'claude-ecs' (is it deployed, and are credentials set?)) (exit 2)"
expect "...and the conclusion says to read the log" 0 "The scrub-on task did not finish: read the log."
reset; export STUB_CONTROL_NOSTART=1; checkit
expect "a control that could not start is flagged" 0 "(Control note: the control did not run its commands: read its log.)"
reset; export STUB_CONTROL="$PH"$'\n'"$FH"; checkit
expect "a control that hides the key too is flagged" 0 "the probe cannot tell the two settings apart here"
reset; export STUB_RUNNING=2; checkit
expect "tasks still running are reported with the command to check" 0 "(Tasks still running on the cluster: 2. Check: scripts/deploy/ecs-in-docker.sh exec aws ecs list-tasks --cluster claude-ecs --desired-status RUNNING)"
reset; export STUB_RUNNING_FAIL=1; checkit
expect "a running-task count that cannot be read is not a warning" 0 "== summary (paste this back) =="
check "...and is n/a in the report" grep -qF "Tasks still running afterwards: n/a" "$WORK/report.md"
check "...and the conclusion has no running-task warning" test -z "$(printf '%s' "$OUT" | grep -F 'Tasks still running on the cluster' || true)"
reset; export STUB_RUNNING=None; checkit
check "a count that is not a number is n/a, not a warning" grep -qF "Tasks still running afterwards: n/a" "$WORK/report.md"
check "...and the conclusion has no running-task warning" test -z "$(printf '%s' "$OUT" | grep -F 'Tasks still running on the cluster' || true)"
reset; export STUB_ECR_FAIL=1; checkit
check "an unreadable ECR image is n/a in the report, not a failure" grep -qF "(digest, pushed at): n/a" "$WORK/report.md"

# ── options ──
reset; checkit --no-control
check "--no-control starts two tasks" test "$(runs)" = 2
check "...and has no control line" test -z "$(printf '%s' "$OUT" | grep -F 'CONTROL  scrub off' || true)"
reset; checkit --profile pyvar
check "--profile is passed to every task" test "$(grep -c -- 'run-task.sh --profile pyvar ' "$WORK/wrapper.log")" = 3
reset; checkit --push-image
check "--push-image pushes the image first" logged "image"
check "...before the first task" test "$(line_of 'image')" -lt "$(line_of 'scripts/run/run-task.sh')"
check "...and the pushed image is shown with the account masked" test -z "$(printf '%s' "$OUT" | grep -F "$ACCOUNT" || true)"
reset; checkit --push-image; check "the report says the image was pushed by this run" grep -qF "Image pushed by this run: yes" "$WORK/report.md"
reset; OUT="$("$CHECK" 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "without --report the report goes to scrub-check-fargate-<time>.md in the repository" 0 "report: $REPO/scrub-check-fargate-"
check "...and the file exists" test -n "$(ls "$REPO"/scrub-check-fargate-*.md 2>/dev/null)"
reset; checkit --help
expect "--help describes the three tasks" 0 "This script starts three tasks"

# ── refusals ──
reset; export STUB_ID_FAIL=1; checkit
expect "credentials or Docker not usable is refused, exit 2" 2 "Docker or the AWS credentials are not usable"
check "...and nothing was started" test "$(runs)" = 0
reset; export STUB_IMAGE_FAIL=1; checkit --push-image
expect "a failed push stops with exit 1" 1 "the image did not build or push"
check "...before any task" test "$(runs)" = 0
reset; checkit --bogus
expect "an unknown option is refused, exit 2" 2 "unknown option"
reset; checkit --profile 'bad name'
expect "a bad profile name is refused, exit 2" 2 "--profile takes letters, digits"
check "...and nothing was started" test ! -s "$WORK/wrapper.log"
reset; mv "$REPO/scripts/deploy/ecs-in-docker.sh" "$WORK/stub-away"; checkit
expect "a missing wrapper is refused, exit 2" 2 "is missing or not executable"
mv "$WORK/stub-away" "$REPO/scripts/deploy/ecs-in-docker.sh"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
