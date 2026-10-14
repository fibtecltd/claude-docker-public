#!/bin/bash
# Tests for first-runs.sh against a stubbed `aws`, run-task.sh and ecs-deploy.sh:
# no network, no account, no task is started.
# Run:  scripts/run/test-first-runs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRST="$SCRIPT_DIR/first-runs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
FIX="$WORK/fix"
mkdir -p "$BIN" "$FIX"
export WORK FIX

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }

# aws: answers the few calls first-runs.sh makes. Task counts come from $FIX/running (a
# list of values, one per call; the last repeats), so a test can leave a task "running".
cat > "$BIN/aws" <<'STUB'
#!/bin/bash
echo "aws $*" >> "$WORK/aws.log"
all="$*"
case "$all" in
    *"describe-stacks"*ClusterName*) echo "claude-ecs" ;;
    *"list-tasks"*"--started-by"*) echo "${LEFTOVER_ARN:-}" ;;
    *"list-tasks"*"length(taskArns)"*)
        n=$(( $(cat "$WORK/running.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/running.calls"
        vals=( $(cat "$FIX/running" 2>/dev/null || echo 0) )
        i=$(( n - 1 )); [ "$i" -lt "${#vals[@]}" ] || i=$(( ${#vals[@]} - 1 ))
        echo "${vals[$i]}" ;;
    *"stop-task"*) echo "stopped" >> "$WORK/stopped.log" ;;
    *) echo "stub aws: unexpected call: $all" >&2; exit 254 ;;
esac
STUB

# run-task.sh: prints what the real one prints; $FIX/fail_first makes the first call exit 1.
cat > "$WORK/run-task.sh" <<'STUB'
#!/bin/bash
echo "$$" >> "$WORK/rt.calls"   # one line per call; parallel calls must not share a counter
echo "$*" >> "$WORK/rt.args"
profile=""; budget=""; turns=""; repo=""; ref=""; spot=""; model=""; prompt=""; fmt=""
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) profile="$2"; shift 2 ;;
        --max-budget-usd) budget="$2"; shift 2 ;;
        --max-turns) turns="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --ref) ref="$2"; shift 2 ;;
        --model) model="$2"; shift 2 ;;
        --prompt) prompt="$2"; shift 2 ;;
        --output-format) fmt="$2"; shift 2 ;;
        --spot) spot=1; shift ;;
        *) shift ;;
    esac
done
echo "call $$ profile=$profile model=${model:-default} budget=$budget turns=$turns repo=$repo ref=$ref spot=${spot:-0}" >> "$WORK/rt.log"
id="run$$"; [ -z "$spot" ] || id=spot
echo "start $id" >> "$WORK/rt.order"
sleep "${RT_SLEEP:-0}"
echo "end $id" >> "$WORK/rt.order"
echo "started arn:aws:ecs:eu-west-1:123456789012:task/claude-ecs/t$$ (FARGATE, $profile)"
echo "status: STOPPED"
echo "--- logs (/claude-ecs, stream $profile/claude/t$$)"
rc=0; cost=0.0123; text=""; subtype=success
case "$prompt" in
    *montecarlo.py\ gets*)
        cost=0.2345
        if [ "${STUB_G3:-full}" = weak ]; then
            text="The numbers are pre-drawn outside the kernel."
        else
            text="run_monte_carlo_var seeds np.random.seed(seed), then _draw_random_shocks calls np.random.randn in pure Python,
outside the njit kernel; the shocks array is passed to _simulate_paths as an argument."
        fi ;;
    *engine/metrics.py\ completely*)
        cost=0.0612
        if [ -n "${STUB_CAP_OK:-}" ]; then text="ok"; else subtype=error_max_budget_usd; rc=1; fi ;;
    *aws\ sts\ get-caller-identity*)
        cost=0.0777
        text="1) exit 0: arn:aws:sts::123456789012:assumed-role/claude-ecs-Task-core/abc
2) exit 254: AccessDenied when calling ListBuckets
3) 200"
        if [ -n "${STUB_PORT80_OPEN:-}" ]; then text="$text
4) 200"; else text="$text
4) curl exit 28: connection timed out"; fi ;;
    *) text="ok" ;;
esac
if [ "$fmt" = json ] && [ -z "${STUB_PLAIN:-}" ]; then
    if [ "$subtype" = success ]; then
        jq -nc --arg r "$text" --argjson c "$cost" '{type: "result", subtype: "success", is_error: false, num_turns: 2, result: $r, total_cost_usd: $c}'
    else
        jq -nc --argjson c "$cost" '{type: "result", subtype: "error_max_budget_usd", is_error: true, num_turns: 3, total_cost_usd: $c}'
    fi
elif [ "$subtype" = success ]; then
    printf '%s\n' "$text"
else
    echo "Error: Exceeded USD budget (0.05)"
fi
echo "--- summary"
echo "stopped:     Essential container in task exited"
echo "container:   exit code $rc "
echo "provisioning (created -> image pull start): 12s"
echo "image pull:                                 5s"
echo "start-up (created -> running):              20s"
echo "run (running -> stopped):                   3s"
if [ -f "$FIX/fail_first" ] && [ "$(wc -l < "$WORK/rt.calls" | tr -d ' ')" = 1 ]; then exit 1; fi
exit "$rc"
STUB
cat > "$WORK/ecs-deploy.sh" <<'STUB'
#!/bin/bash
echo "ecs-deploy $*" >> "$WORK/deploy.log"
echo "  [OK]   same account as the baseline"
echo "  [OK]   pyvar-dev-pipeline: no new execution"
exit "${STUB_VERIFY_RC:-0}"
STUB
chmod +x "$BIN/aws" "$WORK/run-task.sh" "$WORK/ecs-deploy.sh"
export PATH="$BIN:$PATH"
export RUN_TASK="$WORK/run-task.sh" ECS_DEPLOY="$WORK/ecs-deploy.sh"
export AWS_REGION=eu-west-1

reset() { rm -rf "$FIX" "$WORK"/*.log "$WORK"/rt.order "$WORK"/rt.calls "$WORK"/rt.args "$WORK"/running.calls; mkdir -p "$FIX"; unset RT_SLEEP STUB_VERIFY_RC STUB_G3 STUB_CAP_OK STUB_PORT80_OPEN STUB_PLAIN; }
first() { OUT="$("$FIRST" --report "$WORK/report.md" "$@" 2>&1)" && RC=0 || RC=$?; }
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF -- "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
logged() { grep -qF -- "$1" "$WORK/$2"; }

# ── the plan and its limits ──
reset; first --dry-run
expect "the default is the quick set of 5 runs, USD 2.05 of caps" 0 "Plan (the quick set): 5 run(s), budgets add up to USD 2.05"
check "...and calls nothing" test ! -e "$WORK/aws.log"
reset; first --dry-run --all
expect "--all lists the 15 runs and the total cap" 0 "Plan (groups G1,G2,G3,G4,G5): 15 run(s), budgets add up to USD 4.55"
check "...at most 3 at once" grep -qF "at most 3 at once" <<<"$OUT"
reset; first --dry-run --max-total-usd 2
expect "a plan over the spend limit is refused" 2 "over the limit of USD 2"
reset; first --dry-run --groups G1,G5
expect "groups select runs" 0 "Plan (groups G1,G5): 6 run(s)"
reset; first --groups G9
expect "an unknown group is refused" 2 "--groups must be"

# ── the quick set, end to end ──
reset; first
expect "the quick set completes" 0 "Report saved to"
check "five runs were made" test "$(wc -l < "$WORK/rt.calls" | tr -d ' ')" = 5
check "...the pyvar one on master, the spend-cap one at USD 0.05" logged "budget=0.05 turns=10" rt.log
check "the report ends with the Quality section" test "$(grep -n '^## ' "$WORK/report.md" | tail -n 1 | cut -d: -f2)" = "## Quality"
check "the rubric scores the pyvar answer 6/6" grep -qF "**Rubric score: 6/6**" "$WORK/report.md"
check "every run behaved as designed: 5 of 5" grep -qF "**Behaved as designed: 5 of 5**" "$WORK/report.md"
check "every run was asked for the JSON result" test "$(grep -c -- '--output-format json' <<<"$(cat "$WORK/rt.args")")" = 5
check "the timing table carries turns and cost per run" grep -qF "| G1-cold | core | default | on-demand | 0 | 12s | 5s | 20s | 3s | 2 | 0.0123 |" "$WORK/report.md"
check "the spend is the sum of the reported costs" grep -qF "**Spend: USD 0.3980 reported by 5 of 5 runs**" "$WORK/report.md"
check "the pyvar answer is shown as text, not as JSON" grep -qF "outside the njit kernel; the shocks array is passed" "$WORK/report.md"
check "a run stopped by the cap still reports its cost" grep -qF "| G4-budget-cap | pyvar | default | on-demand | 1 | 12s | 5s | 20s | 3s | 3 | 0.0612 |" "$WORK/report.md"
reset; export STUB_PLAIN=1; first
expect "plain-text output (no JSON) still completes" 0 "Report saved to"
check "...with the cost shown as n/a" grep -qF "**Spend: USD 0.0000 reported by 0 of 5 runs**" "$WORK/report.md"
check "...and the checks still read the text answers: 5 of 5" grep -qF "**Behaved as designed: 5 of 5**" "$WORK/report.md"

# ── the model matrix ──
reset; first --groups G2
expect "G2 completes" 0 "Report saved to"
check "the matrix lists the models side by side" grep -qF "| claude-opus-5-5 | 0 | ok | 20s | 3s | 2 | 0.0123 |" "$WORK/report.md"
check "...with the effort level where one was set" grep -qF "| claude-haiku-5-5, effort max | 0 | ok |" "$WORK/report.md"
check "...six rows" test "$(grep -c '^| claude-' "$WORK/report.md")" = 6
check "the six behaved as designed: 6 of 6" grep -qF "**Behaved as designed: 6 of 6**" "$WORK/report.md"

# ── a full group ──
reset; first --groups G1
expect "G1 completes" 0 "Report saved to"
check "two runs started" test "$(wc -l < "$WORK/rt.calls" | tr -d ' ')" = 2
check "the core profile with caps was used" logged "profile=core model=default budget=0.25 turns=1" rt.log
check "the timing table has the cold run with its numbers" grep -qF "| G1-cold | core | default | on-demand | 0 | 12s | 5s | 20s | 3s |" "$WORK/report.md"
check "the report records that no task is left" grep -qF "tasks still running in the cluster: 0" "$WORK/report.md"
check "verify ran with the config" logged "verify" deploy.log
check "the two G1 runs behaved as designed: 2 of 2" grep -qF "**Behaved as designed: 2 of 2**" "$WORK/report.md"

# ── the pyvar run uses the public repository on master ──
reset; first --groups G3
expect "G3 completes and the rubric scores the answer 6/6" 0 "Rubric score: 6/6"
check "...on fibtecltd/pyvar at master, profile pyvar" logged "profile=pyvar model=default budget=1.00 turns=15 repo=fibtecltd/pyvar ref=master" rt.log

reset; export STUB_G3=weak; first --groups G3
expect "a thin answer scores low on the rubric" 0 "Rubric score: 1/6"

# ── the guardrail runs ──
reset; first --groups G4
expect "G4 completes" 0 "G4a - spend cap"
check "the cap run uses USD 0.05" logged "budget=0.05 turns=10" rt.log
check "the role and egress run is in the report" grep -qF "G4b - task role and egress" "$WORK/report.md"
check "both guardrails behaved as designed: 2 of 2" grep -qF "**Behaved as designed: 2 of 2**" "$WORK/report.md"
reset; export STUB_CAP_OK=1; first --groups G4
check "a task that finishes under the cap does not count as the cap working" grep -qF "**Behaved as designed: 1 of 2**" "$WORK/report.md"
reset; export STUB_PORT80_OPEN=1; first --groups G4
check "an open port 80 does not count as blocked" grep -qF "80 blocked: NO" "$WORK/report.md"
check "...so that run did not behave as designed" grep -qF "**Behaved as designed: 1 of 2**" "$WORK/report.md"

# ── concurrency ──
reset; export RT_SLEEP=1; first --groups G5
expect "G5 completes" 0 "waiting for the parallel tasks"
starts_before_first_end="$(awk '/^end/ { exit } /^start/ { n++ } END { print n }' "$WORK/rt.order")"
check "three tasks run at once" test "$starts_before_first_end" = 3
ends_before_spot="$(awk '/^start spot/ { exit } /^end/ { n++ } END { print n + 0 }' "$WORK/rt.order")"
check "the spot run starts after the parallel ones finish" test "$ends_before_spot" = 3
check "the spot run is on Spot" logged "spot=1" rt.log

# ── stops and failures ──
reset; touch "$FIX/fail_first"; first --groups G1,G2
expect "a failed G1-cold stops the remaining runs" 1 "the remaining runs were skipped"
check "...only the first run was made" test "$(wc -l < "$WORK/rt.calls" | tr -d ' ')" = 1
check "...and the report says so" grep -qF "G1-cold failed" "$WORK/report.md"

reset; echo "0 1" > "$FIX/running"; first --groups G1
expect "a task left running is a failure" 1 "still running"

reset; echo "2" > "$FIX/running"; first --groups G1
expect "tasks already running before the start are refused" 2 "already running"
check "...and nothing was started" test ! -e "$WORK/rt.calls"

reset; export STUB_VERIFY_RC=1; first --groups G1
expect "a verify difference is a failure" 1 "verify found a difference"
check "...and is shown in the report" grep -qF "(exit 1)" "$WORK/report.md"

if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
