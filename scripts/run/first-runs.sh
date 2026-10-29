#!/usr/bin/env bash
# ============================================================
# first-runs.sh - the first runs against a deployed claude-ecs stack.
#
#   scripts/run/first-runs.sh [--config FILE] [--all | --groups G1,G3] [--max-total-usd N]
#                             [--report FILE] [--dry-run]
#
# By default the quick set of 5 runs: G1-cold, G1-warm, G3, G4 spend cap, G4 role and egress.
# --all runs every group below, --groups G1,G3 only those.
#
# Runs, one after the other (G5 starts three at once), through run-task.sh:
#   G1  cold and warm start of the core profile, trivial prompt
#   G2  the model matrix on one trivial prompt, plus Haiku 5.5 at --effort max
#   G3  a read-only question about a public repository (pyvar, --ref master)
#   G4  guardrails: a spend cap that is hit, the task role and the egress rules, and the
#       what a command can see of the API key (reported, not judged)
#   G5  three tasks at once, then one on Fargate Spot
# and writes a markdown report (timings, outcomes, evidence) that is also printed. It ends with a
# Quality section: the pyvar answer scored against 6 facts taken from engine/montecarlo.py, and
# whether each run behaved as designed (n of the runs that were made).
#
# Controls, all enforced here:
#   - only the core and pyvar profiles, no GitHub token, prompts start "Read-only:"
#   - every run has --max-turns and --max-budget-usd; the sum of the budgets must
#     stay under --max-total-usd (default 5), else nothing starts
#   - never more than 3 tasks at once; nothing may be running in the cluster before
#   - tasks this script started are stopped if it is interrupted
#   - afterwards: no task left running, and `ecs-deploy.sh verify` compares the
#     account with the baseline taken by preflight (pipelines, CDKToolkit untouched)
#
# Needs: aws, jq, awk. Credentials for the account the stack lives in.
# Exit code: 0 when every run was executed and the controls hold; the containers'
# own exit codes are results in the report, not failures.
# Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TASK="${RUN_TASK:-$SCRIPT_DIR/run-task.sh}"
DEPLOY="${ECS_DEPLOY:-$REPO_DIR/scripts/deploy/ecs-deploy.sh}"
STACK="${CLAUDE_ECS_STACK:-claude-ecs}"
ALLOWED_PROFILES="core pyvar"
MAX_PARALLEL=3
RUN_TIMEOUT=900

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "first-runs: $*" >&2; exit 2; }

TRIVIAL='Read-only: reply with exactly: ok'
PYVAR_PROMPT='Read-only: do not modify or create any file and do not push anything. In at most 8 lines, explain how engine/montecarlo.py gets its random numbers: where they are drawn, whether the draw happens inside or outside the Numba-compiled kernel, how the numbers reach the kernel, and how a seed is applied. Name the functions involved.'
CAP_PROMPT='Read-only: read engine/montecarlo.py and engine/metrics.py completely, then write a detailed review of about 400 words for each file. Do not modify anything.'
# Commands 5 and 6 report what a command the agent runs can see of the API key: whether it is in the
# command's environment, and how many /proc/*/environ files hold it. They are reported, not judged (the
# scrub that would hide the key needs bubblewrap, which a Fargate task cannot run; see the runbook). They
# print a marker built at run time ("key-$s", "...: $n") so that the agent quoting the command text
# in its answer cannot match the patterns below by accident. They never print the key.
IFS= read -r -d '' ROLE_PROMPT <<'EOF' || true
Read-only: run exactly these six shell commands, one at a time, and for each report its exit code and the first 3 lines of its output, nothing else. The commands are the text between backticks.
1) `aws sts get-caller-identity`
2) `aws s3 ls`
3) `curl -sS -m 8 -o /dev/null -w '%{http_code}' https://api.github.com`
4) `curl -sS -m 8 -o /dev/null -w '%{http_code}' http://example.com`
5) `if [ -n "${ANTHROPIC_API_KEY:-}" ]; then s=VISIBLE; else s=hidden; fi; echo "key-$s"`
6) `n=0; for f in /proc/[0-9]*/environ; do grep -qa ANTHROPIC_API_KEY "$f" 2>/dev/null && n=$((n+1)); done; echo "proc-environ-with-key: $n"`
Do not retry a command and do not try to fix an error. Never print the value of any variable.
EOF
ROLE_PROMPT="${ROLE_PROMPT//$'\n'/ }"
ROLE_PROMPT="${ROLE_PROMPT% }"

# id|group|mode|profile|model|effort|spot|repo|ref|turns|budget|prompt
spec_table() {
    cat <<EOF
G1-cold|G1|seq|core|||0|||1|0.25|$TRIVIAL
G1-warm|G1|seq|core|||0|||1|0.25|$TRIVIAL
G2-sonnet-5-5|G2|seq|core|claude-sonnet-5-5||0|||1|0.25|$TRIVIAL
G2-opus-5-5|G2|seq|core|claude-opus-5-5||0|||1|0.25|$TRIVIAL
G2-sonnet-5|G2|seq|core|claude-sonnet-5||0|||1|0.25|$TRIVIAL
G2-opus-5|G2|seq|core|claude-opus-5||0|||1|0.25|$TRIVIAL
G2-haiku-5-5|G2|seq|core|claude-haiku-5-5||0|||1|0.25|$TRIVIAL
G2-haiku-5-5-max|G2|seq|core|claude-haiku-5-5|max|0|||1|0.25|$TRIVIAL
G3-pyvar-read|G3|seq|pyvar|||0|fibtecltd/pyvar|master|15|1.00|$PYVAR_PROMPT
G4-budget-cap|G4|seq|pyvar|||0|fibtecltd/pyvar|master|10|0.05|$CAP_PROMPT
G4-role-egress|G4|seq|core|||0|||10|0.50|$ROLE_PROMPT
G5-par-1|G5|par|core|||0|||1|0.25|$TRIVIAL
G5-par-2|G5|par|core|||0|||1|0.25|$TRIVIAL
G5-par-3|G5|par|core|||0|||1|0.25|$TRIVIAL
G5-spot|G5|seq|core|||1|||1|0.25|$TRIVIAL
EOF
}

CONFIG="" SELECT="" MAX_TOTAL=5 REPORT="$REPO_DIR/first-runs-report.md" DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --all) SELECT="G1,G2,G3,G4,G5"; shift ;;
        --groups) SELECT="${2:?--groups needs a list like G1,G3}"; shift 2 ;;
        --max-total-usd) MAX_TOTAL="${2:?--max-total-usd needs a number}"; shift 2 ;;
        --report) REPORT="${2:?--report needs a file}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[[ "$MAX_TOTAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--max-total-usd must be a number"
[ -z "$SELECT" ] || [[ "$SELECT" =~ ^G[1-5](,G[1-5])*$ ]] || die "--groups must be a comma-separated list from G1..G5"
if [ -z "$SELECT" ]; then SET_LABEL="the quick set"; else SET_LABEL="groups $SELECT"; fi

QUICK_IDS=" G1-cold G1-warm G3-pyvar-read G4-budget-cap G4-role-egress "
selected() { # selected ID GROUP
    if [ -z "$SELECT" ]; then
        case "$QUICK_IDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
    else
        case ",$SELECT," in *",$2,"*) return 0 ;; *) return 1 ;; esac
    fi
}

# The plan: the selected rows, checked against the controls before anything starts.
PLAN="$(mktemp)"
OUT="$(mktemp -d)"
CLUSTER="" PIDS=""
# shellcheck disable=SC2317,SC2329  # called through the EXIT trap
stop_ours() {
    local arns a
    arns="$(aws ecs list-tasks --cluster "$CLUSTER" --started-by claude-ecs-run-task --desired-status RUNNING \
        --query 'taskArns[]' --output text 2>/dev/null || true)"
    for a in $arns; do
        aws ecs stop-task --cluster "$CLUSTER" --task "$a" --reason "first-runs.sh interrupted" >/dev/null 2>&1 || true
    done
}
# shellcheck disable=SC2317,SC2329  # called through the INT/TERM trap
on_signal() {
    echo; echo "Interrupted: stopping the tasks this script started."
    # shellcheck disable=SC2086
    [ -z "$PIDS" ] || kill $PIDS 2>/dev/null || true
    exit 130   # the EXIT trap stops the tasks
}
# shellcheck disable=SC2317,SC2329  # called through the EXIT trap
cleanup() {
    rm -rf "$PLAN" "$OUT"
    # Whatever happens, no task this script started is left running.
    [ -z "$CLUSTER" ] || stop_ours
}
trap cleanup EXIT
trap on_signal INT TERM
spec_table | while IFS='|' read -r id group rest; do
    if selected "$id" "$group"; then printf '%s|%s|%s\n' "$id" "$group" "$rest"; fi
done > "$PLAN"
[ -s "$PLAN" ] || die "no runs selected"

parallel_max=0 streak=0
while IFS='|' read -r id _group mode profile _model _effort _spot _repo _ref turns budget prompt; do
    case " $ALLOWED_PROFILES " in *" $profile "*) ;; *) die "$id: profile '$profile' is not allowed for the first runs" ;; esac
    [[ "$turns" =~ ^[0-9]+$ && "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$id: missing turn or budget cap"
    case "$prompt" in "Read-only:"*) ;; *) die "$id: the prompt must start with 'Read-only:'" ;; esac
    if [ "$mode" = par ]; then streak=$((streak + 1)); else streak=0; fi
    [ "$streak" -le "$parallel_max" ] || parallel_max=$streak
done < "$PLAN"
[ "$parallel_max" -le "$MAX_PARALLEL" ] || die "more than $MAX_PARALLEL tasks at once"
TOTAL="$(awk -F'|' '{ s += $11 } END { printf "%.2f", s }' "$PLAN")"
COUNT="$(wc -l < "$PLAN" | tr -d ' ')"
awk -v t="$TOTAL" -v m="$MAX_TOTAL" 'BEGIN { exit !(t <= m) }' \
    || die "the budgets add up to USD $TOTAL, over the limit of USD $MAX_TOTAL; nothing started"

[ "$parallel_max" -ge 1 ] || parallel_max=1
echo "Plan ($SET_LABEL): $COUNT run(s), budgets add up to USD $TOTAL (limit $MAX_TOTAL), at most $parallel_max at once."
awk -F'|' '{ printf "  %-18s %-6s %-20s turns %-3s budget %s\n", $1, $4, ($5 == "" ? "default model" : $5), $10, $11 }' "$PLAN"
if [ "$DRY_RUN" -eq 1 ]; then echo "Dry run: nothing started."; exit 0; fi

for tool in aws jq awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || die "no config file $CONFIG"
    # shellcheck disable=SC1090
    . "$CONFIG"
    : "${AWS_REGION:?set AWS_REGION in the config file}"
    export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
fi

stack_output() {
    aws cloudformation describe-stacks --stack-name "$STACK" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}
CLUSTER="$(stack_output ClusterName 2>/dev/null)" || CLUSTER=""
if [ -z "$CLUSTER" ] || [ "$CLUSTER" = "None" ]; then
    CLUSTER=""
    die "cannot read the $STACK stack (deployed? credentials set?)"
fi

running_tasks() { # count of tasks not yet stopped in the cluster
    aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --query 'length(taskArns)' --output text
}
before="$(running_tasks)" || die "cannot list the tasks of cluster $CLUSTER"
[ "$before" = "0" ] || die "$before task(s) already running in cluster $CLUSTER; wait for them or stop them first"


run_one() { # run_one SPEC_ROW -> $OUT/<id>.out (run-task output) and $OUT/<id>.rc
    local id _g _m profile model effort spot repo ref turns budget prompt rc=0
    IFS='|' read -r id _g _m profile model effort spot repo ref turns budget prompt <<<"$1"
    local args=(--profile "$profile" --prompt "$prompt" --max-turns "$turns" --max-budget-usd "$budget" --timeout "$RUN_TIMEOUT"
        --output-format json)   # one result object per run: the answer, the cost, the turns
    [ -z "$model" ] || args+=(--model "$model")
    [ -z "$effort" ] || args+=(--effort "$effort")
    [ "$spot" != 1 ] || args+=(--spot)
    [ -z "$repo" ] || args+=(--repo "$repo")
    [ -z "$ref" ] || args+=(--ref "$ref")
    "$RUN_TASK" "${args[@]}" > "$OUT/$id.out" 2>&1 || rc=$?
    echo "$rc" > "$OUT/$id.rc"
}

# value of the last "<label> ...: Ns" line of a run, or n/a
timing() {
    local v
    v="$(grep -E "^$2" "$OUT/$1.out" 2>/dev/null | tail -n 1 | awk '{ print $NF }')" || v=""
    echo "${v:-n/a}"
}
exit_of() { cat "$OUT/$1.rc" 2>/dev/null || echo "?"; }

# The log lines of a run, at most N.
answer_of() {
    { sed -n '/^--- logs/,/^--- summary/p' "$OUT/$1.out" 2>/dev/null | sed '1d;$d' | head -n "${2:-30}"; } || true
}
# The result object Claude Code printed (--output-format json), or nothing. Log lines may carry a
# timestamp prefix, so everything before the first { is dropped.
result_json() {
    { answer_of "$1" 400 | sed 's/^[^{]*//' | jq -cR 'fromjson? | select(type == "object" and .type == "result")' 2>/dev/null | tail -n 1; } || true
}
# The answer as text: the result field when there is one, else the raw log lines.
result_text() {
    local j
    j="$(result_json "$1")"
    if [ -n "$j" ] && printf '%s' "$j" | jq -e '.result | type == "string"' >/dev/null 2>&1; then
        printf '%s' "$j" | jq -r '.result' | head -n "${2:-30}"
    else
        answer_of "$1" "${2:-30}"
    fi
}
# What the run cost in USD (total_cost_usd), or n/a.
cost_of() {
    local v
    v="$(result_json "$1" | jq -r '.total_cost_usd // empty' 2>/dev/null)" || v=""
    if [ -n "$v" ]; then awk -v v="$v" 'BEGIN { printf "%.4f\n", v }'; else echo "n/a"; fi
}
turns_of() {
    local v
    v="$(result_json "$1" | jq -r '.num_turns // empty' 2>/dev/null)" || v=""
    echo "${v:-n/a}"
}

describe_done() {
    echo "  [$1] exit $(exit_of "$1"), start-up $(timing "$1" 'start-up'), run $(timing "$1" 'run '), cost USD $(cost_of "$1")"
}

await_parallel() {
    local p
    for p in $PIDS; do wait "$p" || true; done
    PIDS=""
}

STARTED_AT="$(date -u +%Y-%m-%dT%H:%MZ)"
ABORTED=""
PAR_IDS=""
while IFS= read -r row <&3; do
    id="${row%%|*}"
    mode="$(printf '%s' "$row" | cut -d'|' -f3)"
    if [ -n "$ABORTED" ]; then continue; fi
    if [ "$mode" = par ]; then
        echo "== $id (parallel) started"
        run_one "$row" &
        PIDS="$PIDS $!"
        PAR_IDS="$PAR_IDS $id"
        continue
    fi
    if [ -n "$PIDS" ]; then
        echo "-- waiting for the parallel tasks:$PAR_IDS"
        await_parallel
        for p in $PAR_IDS; do describe_done "$p"; done
        PAR_IDS=""
    fi
    echo "== $id"
    run_one "$row"
    describe_done "$id"
    if [ "$id" = "G1-cold" ] && [ "$(exit_of "$id")" != "0" ]; then
        ABORTED="G1-cold failed (exit $(exit_of "$id")); the remaining runs were skipped"
        echo "  $ABORTED"
        tail -n 15 "$OUT/$id.out" | sed 's/^/  | /'
    fi
done 3< "$PLAN"
if [ -n "$PIDS" ]; then
    echo "-- waiting for the parallel tasks:$PAR_IDS"
    await_parallel
    for p in $PAR_IDS; do describe_done "$p"; done
fi

# ── controls after the runs ──
LEFT="$(running_tasks || echo '?')"
VERIFY_OUT="$(mktemp)"
VERIFY_RC=0
"$DEPLOY" ${CONFIG:+--config "$CONFIG"} verify > "$VERIFY_OUT" 2>&1 || VERIFY_RC=$?

# ── report ──
has() { grep -qiE -- "$2" <<<"$1"; }   # has TEXT REGEX
rubric_row() { # rubric_row LABEL REGEX: one table row, counts the point
    if has "$G3_ANSWER" "$2"; then echo "| $1 | yes |"; RUBRIC_SCORE=$((RUBRIC_SCORE + 1)); else echo "| $1 | no |"; fi
}
behaved_row() { # behaved_row RUN EXPECTED OBSERVED OK(1|0)
    local mark="NO"
    [ "$4" != 1 ] || mark="yes"
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "$(printf '%s' "$3" | tr '|' '/')" "$mark"
    BEH_TOTAL=$((BEH_TOTAL + 1))
    [ "$4" != 1 ] || BEH_OK=$((BEH_OK + 1))
}
yn() { if has "$1" "$2"; then echo yes; else echo NO; fi; }

# The Quality section: printed last, inside the report block (it counts in that shell).
quality_section() {
    local id ans full rc ok obs ident s3 https blocked keyvis procn
    echo "## Quality"
    if [ -f "$OUT/G3-pyvar-read.rc" ]; then
        G3_ANSWER="$(result_text G3-pyvar-read 200)"
        RUBRIC_SCORE=0
        echo
        echo "### The pyvar answer against facts from engine/montecarlo.py"
        echo
        echo "Six facts from the real file, each looked for in the answer (shown above) by a pattern."
        echo
        echo "| fact | in the answer |"
        echo "|---|---|"
        rubric_row "the draw happens in Python, outside the Numba kernel" 'outside|pre-?draw|before (the |entering |calling )?(njit|jit|numba|kernel|simulat)|pure python|python side|not inside'
        rubric_row "it uses np.random.randn" 'randn'
        rubric_row "it names _draw_random_shocks" '_draw_random_shocks'
        rubric_row "it names the kernel _simulate_paths" '_simulate_paths'
        rubric_row "the shocks reach the kernel as an argument" '(pass(ed|es|ing)?|argument|parameter|input|receives|takes|fed|handed).{0,80}(shock|random)|(shock|random).{0,80}(pass(ed|es|ing)?|argument|parameter|input|fed|handed)'
        rubric_row "the seed is applied with np.random.seed" 'seed'
        echo
        echo "**Rubric score: $RUBRIC_SCORE/6**"
    fi
    BEH_OK=0
    BEH_TOTAL=0
    echo
    echo "### Did each run behave as designed"
    echo
    echo "| run | expected | observed | as designed |"
    echo "|---|---|---|---|"
    while IFS='|' read -r id _r <&4; do
        case "$id" in G1-* | G2-* | G5-*) ;; *) continue ;; esac
        [ -f "$OUT/$id.rc" ] || continue
        rc="$(exit_of "$id")"; ans="$(result_text "$id" 20)"; ok=0
        if [ "$rc" = 0 ] && grep -qiE '(^|[[:space:]])ok[[:space:]]*$' <<<"$ans"; then ok=1; fi
        behaved_row "$id" "exit 0, the answer is ok" "exit $rc, last line: $(printf '%s' "$ans" | tail -n 1 | cut -c1-40)" "$ok"
    done 4< "$PLAN"
    if [ -f "$OUT/G3-pyvar-read.rc" ]; then
        rc="$(exit_of G3-pyvar-read)"; ok=0
        if [ "$rc" = 0 ] && [ -n "$G3_ANSWER" ]; then ok=1; fi
        behaved_row "G3-pyvar-read" "exit 0, a non-empty answer from the cloned repository" "exit $rc, $(printf '%s' "$G3_ANSWER" | grep -c .) log line(s)" "$ok"
    fi
    if [ -f "$OUT/G4-budget-cap.rc" ]; then
        rc="$(exit_of G4-budget-cap)"; full="$(cat "$OUT/G4-budget-cap.out")"; ok=0
        if [ "$rc" != 0 ] || has "$full" 'budget|exceed'; then ok=1; fi
        obs="exit $rc; $(grep -iE 'budget|exceed' <<<"$full" | head -n 1 | cut -c1-60 || true)"
        behaved_row "G4-budget-cap" "the USD 0.05 cap stops the task (non-zero exit or a budget message)" "$obs" "$ok"
    fi
    if [ -f "$OUT/G4-role-egress.rc" ]; then
        full="$(result_text G4-role-egress 400; cat "$OUT/G4-role-egress.out")"
        ident="$(yn "$full" 'assumed-role|arn:aws:sts|task.?role')"
        s3="$(yn "$full" 'AccessDenied|access denied|not authorized|denied|forbidden')"
        https="$(yn "$full" '(^|[^0-9])200([^0-9]|$)')"
        blocked="$(yn "$full" '(^|[^0-9])000([^0-9]|$)|time(d)?[ -]?out|timeout|exit( code)?:? ?(28|7)([^0-9]|$)|could not connect|refused|blocked')"
        # What a command can see of the API key: reported, not part of "as designed".
        keyvis="n/a"
        if has "$full" 'key-VISIBLE'; then keyvis=yes; elif has "$full" 'key-hidden'; then keyvis=no; fi
        procn="$(printf '%s' "$full" | sed -n 's/.*proc-environ-with-key: \([0-9][0-9]*\).*/\1/p' | head -n 1)"
        [ -n "$procn" ] || procn="n/a"
        ok=0
        if [ "$ident$s3$https$blocked" = "yesyesyesyes" ]; then ok=1; fi
        behaved_row "G4-role-egress" "a task role, S3 denied, port 443 reachable, port 80 blocked (what a command sees of the API key is only reported)" "role: $ident, s3 denied: $s3, 443 ok: $https, 80 blocked: $blocked; reported: key in a command's environment: $keyvis, /proc/*/environ files with the key: $procn" "$ok"
    fi
    echo
    echo "**Behaved as designed: $BEH_OK of $BEH_TOTAL**"
}

# The model matrix: the G2 runs side by side, when they were made.
model_matrix() {
    local id model effort n=0 label ans
    while IFS='|' read -r id _g _m _p model effort _r <&4; do
        case "$id" in G2-*) ;; *) continue ;; esac
        [ -f "$OUT/$id.rc" ] || continue
        if [ "$n" = 0 ]; then
            echo
            echo "## Model matrix"
            echo
            echo "The same one-word prompt on each model (core profile, on-demand). Seconds and USD."
            echo
            echo "| model | exit | answer | start-up | run | turns | cost USD |"
            echo "|---|---|---|---|---|---|---|"
        fi
        n=$((n + 1))
        label="$model"; [ -z "$effort" ] || label="$label, effort $effort"
        ans="$(result_text "$id" 5 | tail -n 1 | cut -c1-30 | tr '|' '/')"
        echo "| $label | $(exit_of "$id") | $ans | $(timing "$id" 'start-up') | $(timing "$id" 'run ') | $(turns_of "$id") | $(cost_of "$id") |"
    done 4< "$PLAN"
}

{
    set +e   # a failing grep in the report must never cut the report short
    echo "# claude-ecs first runs"
    echo
    echo "Started $STARTED_AT, stack \`$STACK\`, cluster \`$CLUSTER\`, ${AWS_REGION:-region from the environment}."
    echo "Runs: $SET_LABEL. Budgets add up to USD $TOTAL (caps, not spend)."
    [ -z "$ABORTED" ] || { echo; echo "**$ABORTED**"; }
    echo
    echo "## Timings"
    echo
    echo "Seconds. Provisioning = created to image-pull start; start-up = created to running."
    echo
    echo "| run | profile | model | provider | exit | provisioning | image pull | start-up | run | turns | cost USD |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
    while IFS='|' read -r id _g _m profile model effort spot _r; do
        [ -f "$OUT/$id.rc" ] || continue
        provider="on-demand"; [ "$spot" != 1 ] || provider="spot"
        label="${model:-default}"; [ -z "$effort" ] || label="$label, effort $effort"
        echo "| $id | $profile | $label | $provider | $(exit_of "$id") | $(timing "$id" 'provisioning') | $(timing "$id" 'image pull') | $(timing "$id" 'start-up') | $(timing "$id" 'run ') | $(turns_of "$id") | $(cost_of "$id") |"
    done < "$PLAN"
    echo
    spent="$(while IFS='|' read -r id _r; do [ -f "$OUT/$id.rc" ] && cost_of "$id"; done < "$PLAN" | awk '{ n++ } $1 != "n/a" { s += $1; r++ } END { printf "%.4f|%d|%d", s, r, n }')"
    IFS='|' read -r spent_sum spent_reported spent_runs <<<"$spent"
    echo "**Spend: USD $spent_sum reported by $spent_reported of $spent_runs runs**, against caps that add up to USD $TOTAL. Cost is Claude Code's own \`total_cost_usd\` for each run (the Anthropic API only; Fargate time is billed separately by AWS)."
    model_matrix
    for id in G3-pyvar-read G4-budget-cap G4-role-egress; do
        [ -f "$OUT/$id.rc" ] || continue
        echo
        case "$id" in
            G3-pyvar-read) echo "## G3 - read-only question about pyvar (--ref master)" ;;
            G4-budget-cap) echo "## G4a - spend cap of USD 0.05 on a task that needs more" ;;
            G4-role-egress) echo "## G4b - task role, egress and what a command can see of the API key" ;;
        esac
        echo
        echo "Exit code $(exit_of "$id"); stopped: $(grep -E '^stopped:' "$OUT/$id.out" | head -n 1 | sed 's/^stopped: *//')"
        echo
        echo '```'
        result_text "$id" 40
        echo '```'
    done
    echo
    echo "## Controls"
    echo
    echo "- tasks still running in the cluster: $LEFT"
    echo "- \`ecs-deploy.sh verify\` (exit $VERIFY_RC):"
    echo
    echo '```'
    sed 's/^/ /' "$VERIFY_OUT"
    echo '```'
    echo
    quality_section
} | tee "$REPORT"
rm -f "$VERIFY_OUT"
echo
echo "Report saved to $REPORT"

[ "$LEFT" = "0" ] || { echo "first-runs: $LEFT task(s) still running in $CLUSTER" >&2; exit 1; }
[ "$VERIFY_RC" -eq 0 ] || { echo "first-runs: ecs-deploy.sh verify found a difference (exit $VERIFY_RC), see the report" >&2; exit 1; }
[ -z "$ABORTED" ] || exit 1
exit 0
