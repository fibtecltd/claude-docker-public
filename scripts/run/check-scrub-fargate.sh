#!/usr/bin/env bash
# ============================================================
# check-scrub-fargate.sh - can Claude Code's credential scrub run in a Fargate task?
#
#   scripts/run/check-scrub-fargate.sh [--push-image] [--no-control] [--profile NAME] [--report FILE]
#
# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 hides the API key from the commands the agent runs, but it runs
# them through bubblewrap (and Claude Code's sandbox needs socat too). This script starts three tasks
# on the claude-ecs stack and says what each showed:
#   ON       scrub on: the five-command probe that check-scrub-local.sh sends to a Docker host
#   CONTROL  scrub off: the same probe, to show that it can see the key (skipped with --no-control)
#   BWRAP    scrub off: bubblewrap called directly (a user namespace, a PID namespace with a fresh
#            /proc, and one with the existing /proc) and the version of socat
# Because the probe and the reading of its answers are shared with check-scrub-local.sh
# (scrub-verdict.sh), a line here compares with the same line from a Docker host.
#
# --push-image first builds, smoke-tests and pushes the image to ECR as :latest (ecs-in-docker.sh
# image). Without it the tasks run whatever :latest holds already; the BWRAP task and the ON task say
# if that image has no socat. Pushing replaces :latest: the current image only adds packages, and the
# scrub stays off by default, so other runs behave as before.
#
# Everything that talks to AWS goes through scripts/deploy/ecs-in-docker.sh, so the machine needs
# Docker and AWS credentials (exported, or in .env) and nothing else. Account ids in what it prints
# and writes are masked as 123456789012, and anything shaped like an Anthropic key is redacted.
#
# It writes a report (the AWS identity, the image in ECR, the exact commands, each task's output and
# the verdicts) to scrub-check-fargate-<time>.md in the repository (git-ignored) and prints the
# summary to paste back.
#
# Cost: ON and CONTROL are capped at 10 turns and USD 0.30, BWRAP at 10 turns and USD 0.40, so at
# most USD 1.00. Each task takes about 3 to 4 minutes (start-up, the run, the log).
# Exit code: 0 the report was written (the verdicts are results, not failures); 1 the image did not
# build or push; 2 a prerequisite is missing (nothing was started). Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_DIR/scripts/deploy/ecs-in-docker.sh"
# shellcheck source-path=SCRIPTDIR source=scrub-verdict.sh
source "$SCRIPT_DIR/scrub-verdict.sh"
CLUSTER="claude-ecs"
ECR_REPO="claude-ecs"
MAX_TURNS=10

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "check-scrub-fargate: $*" >&2; exit 2; }

PUSH=0 CONTROL=1 PROFILE="core" REPORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --push-image) PUSH=1; shift ;;
        --no-control) CONTROL=0; shift ;;
        --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
        --report) REPORT="${2:?--report needs a file}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[[ "$PROFILE" =~ ^[A-Za-z0-9_-]+$ ]] || die "--profile takes letters, digits, - and _"
[ -n "$REPORT" ] || REPORT="$REPO_DIR/scrub-check-fargate-$(date -u +%Y%m%d-%H%M%S).md"
[ -x "$WRAPPER" ] || die "$WRAPPER is missing or not executable"
cd "$REPO_DIR"

# The direct probe: bubblewrap as the sandbox would call it, and socat. The exit codes are printed by
# the commands themselves ("user-ns exit=1"), so an agent that quotes a command cannot match by accident.
bwrap_prompt() {
    # shellcheck disable=SC2016  # the prompt holds literal backticks and $?, for the agent to run
    printf '%s' 'Read-only: run these commands one at a time and report the exit code and the first 5 lines of output of each, nothing else. 1) `bwrap --version` 2) `bwrap --unshare-user --ro-bind / / true; echo user-ns exit=$?` 3) `bwrap --unshare-pid --ro-bind / / --proc /proc true; echo fresh-proc exit=$?` 4) `bwrap --unshare-pid --ro-bind / / --bind /proc /proc true; echo existing-proc exit=$?` 5) `socat -V | head -2`. If a command prints an error, report the error line exactly. Never print the value of any variable. Report every command separately and copy its output lines exactly, including the line that starts with user-ns, fresh-proc or existing-proc; never merge or summarise commands.'
}

# Account ids masked, anything shaped like an Anthropic key redacted.
clean() { sed -E 's/[0-9]{12}/123456789012/g; s/sk-ant-[A-Za-z0-9_-]+/sk-ant-REDACTED/g'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== who am I =="
ID_OUT="$("$WRAPPER" identity 2>&1)" || {
    printf '%s\n' "$ID_OUT" | clean | head -n 5 >&2
    die "Docker or the AWS credentials are not usable (ecs-in-docker.sh identity failed)"
}
ID_OUT="$(printf '%s\n' "$ID_OUT" | clean)"
printf '%s\n' "$ID_OUT"

if [ "$PUSH" = 1 ]; then
    echo "== push the image =="
    "$WRAPPER" image 2>&1 | clean || { echo "check-scrub-fargate: the image did not build or push (see above)" >&2; exit 1; }
fi

ecr_latest() { # the digest and push time of :latest, or n/a
    local out
    # The wrapper prints a line of its own first (where it read the credentials from): the answer is the last line.
    out="$("$WRAPPER" exec aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag=latest \
        --query 'imageDetails[0].[imageDigest,imagePushedAt]' --output text 2>/dev/null | clean | tail -n 1)" || out=""
    case "$out" in sha256:*) printf '%s' "$out" | tr '\t' ' ' ;; *) printf 'n/a' ;; esac
}
IMAGE_INFO="$(ecr_latest)"
echo "ECR $ECR_REPO:latest: $IMAGE_INFO"

# fargate_task LABEL BUDGET PROMPT [EXTRA run-task.sh args...]: output in $TMP/LABEL.out, run-task's exit code in $TMP/LABEL.rc
fargate_task() {
    local label="$1" budget="$2" prompt="$3" rc=0
    shift 3
    echo "== task $label =="
    "$WRAPPER" exec scripts/run/run-task.sh --profile "$PROFILE" ${1+"$@"} \
        --max-turns "$MAX_TURNS" --max-budget-usd "$budget" --prompt "$prompt" > "$TMP/$label.raw" 2>&1 || rc=$?
    clean < "$TMP/$label.raw" > "$TMP/$label.out"
    echo "$rc" > "$TMP/$label.rc"
    tail -n 24 "$TMP/$label.out"
}

PROBE="$(scrub_probe_prompt)"
BWRAP_PROMPT="$(bwrap_prompt)"
fargate_task ON 0.30 "$PROBE" --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
[ "$CONTROL" = 0 ] || fargate_task CONTROL 0.30 "$PROBE" --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0
fargate_task BWRAP 0.40 "$BWRAP_PROMPT"

echo "== tasks still running =="
RUNNING="$("$WRAPPER" exec aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING \
    --query 'length(taskArns)' --output text 2>/dev/null | tail -n 1)" || RUNNING="n/a"
case "$RUNNING" in "" | *[!0-9]*) RUNNING="n/a" ;; esac
echo "$RUNNING"

# ── reading the three tasks ──

finished() { grep -q '^--- summary' "$TMP/$1.out"; } # run-task.sh prints it once the task has stopped

unfinished_line() { # unfinished_line LABEL TEXT: the task never produced a result
    local why
    why="$(grep -m1 '^run-task:' "$TMP/$1.out" 2>/dev/null | sed 's/^run-task: //' | cut -c1-160)" || why=""
    [ -n "$why" ] || why="no summary in the output; see the log"
    printf '%s  %s: COULD NOT RUN: the task did not finish (%s) (exit %s)\n' "$1" "$2" "$why" "$(cat "$TMP/$1.rc")"
}

probe_line() { # probe_line LABEL TEXT
    if finished "$1"; then verdict_line "$1" "$2"; else unfinished_line "$1" "$2"; fi
}

first_match() { grep -m1 -o -E "$1" "$2" || true; } # the first match of an extended regex, or nothing

# What the BWRAP task showed: BW_USER, BW_FRESH, BW_EXISTING (an exit code or n/a), BW_ERR (1 if a bwrap: error
# line was reported, whatever the agent did with the exit codes), BW_SOCAT (yes/no/n/a).
bwrap_line() { # bwrap_line LABEL TEXT
    local f="$TMP/$1.out" ver err so bt
    BW_USER="n/a" BW_FRESH="n/a" BW_EXISTING="n/a" BW_ERR=0 BW_SOCAT="n/a"
    if ! finished "$1"; then unfinished_line "$1" "$2"; return 0; fi
    ver="$(first_match 'bubblewrap [0-9][0-9.]*' "$f")"
    BW_USER="$(first_match 'user-ns exit=[0-9]+' "$f")"; BW_USER="${BW_USER#*=}"; [ -n "$BW_USER" ] || BW_USER="n/a"
    BW_FRESH="$(first_match 'fresh-proc exit=[0-9]+' "$f")"; BW_FRESH="${BW_FRESH#*=}"; [ -n "$BW_FRESH" ] || BW_FRESH="n/a"
    BW_EXISTING="$(first_match 'existing-proc exit=[0-9]+' "$f")"; BW_EXISTING="${BW_EXISTING#*=}"; [ -n "$BW_EXISTING" ] || BW_EXISTING="n/a"
    err="$(grep -m1 'bwrap:' "$f" || true)"
    # The message ends at the closing backtick the agent put around it; what follows is its own commentary.
    bt=$'\x60' # a backtick, kept in a variable so the pattern below needs no quoting tricks (bash 3.2)
    case "$err" in *bwrap:*) err="bwrap:${err#*bwrap:}"; err="${err%%"$bt"*}" ;; *) err="" ;; esac
    # shellcheck disable=SC2016  # the backticks are characters for sed to strip, not a command substitution
    err="$(printf '%s' "$err" | sed 's/[`[:space:]]*$//; s/`\.$//' | cut -c1-240)"
    [ -z "$err" ] || BW_ERR=1
    so="$(first_match 'socat version [0-9][0-9.]*' "$f")"
    if [ -n "$so" ]; then BW_SOCAT="yes"
    elif grep -qiE 'socat: (command )?not found|socat.*(not found|not installed)' "$f"; then BW_SOCAT="no"; so="NOT INSTALLED"
    else so="n/a"; fi
    if [ -z "$ver" ] && [ "$BW_USER" = "n/a" ] && [ "$BW_FRESH" = "n/a" ] && [ "$BW_EXISTING" = "n/a" ] && [ "$so" = "n/a" ]; then
        printf '%s  %s: COULD NOT RUN: no marker in the output (see the log) (exit %s)\n' "$1" "$2" "$(cat "$TMP/$1.rc")"
        return 0
    fi
    printf '%s  %s: %s; --unshare-user exit=%s, fresh /proc exit=%s, existing /proc exit=%s' \
        "$1" "$2" "${ver:-bubblewrap version n/a}" "$BW_USER" "$BW_FRESH" "$BW_EXISTING"
    [ -z "$err" ] || printf '; the agent reported: "%s"' "$err"
    printf '; socat: %s (exit %s)\n' "$so" "$(cat "$TMP/$1.rc")"
}

LINE_ON="$(probe_line ON 'scrub on, Fargate task')"
classify ON; ON_STATE="$(state)"; ON_REASON="$REASON"; ON_FORMS="$FORMS"; ON_DONE=0; ! finished ON || ON_DONE=1
LINE_CTRL=""; CTRL_KEY="n/a"; CTRL_DONE=0
if [ "$CONTROL" = 1 ]; then
    LINE_CTRL="$(probe_line CONTROL 'scrub off, same probe')"
    classify CONTROL; CTRL_KEY="$KEYVIS"; ! finished CONTROL || CTRL_DONE=1
fi
bwrap_line BWRAP 'scrub off, bubblewrap called directly' > "$TMP/BWRAP.line" # not in $(...): it sets BW_* for the conclusion
LINE_BW="$(cat "$TMP/BWRAP.line")"

BW_FAIL=$BW_ERR
for code in "$BW_USER" "$BW_FRESH" "$BW_EXISTING"; do
    case "$code" in n/a | 0) ;; *) BW_FAIL=1 ;; esac
done

# ── the conclusion ──
case "$ON_REASON" in *"socat not installed"*) ON_NO_SOCAT=1 ;; *) ON_NO_SOCAT=0 ;; esac
if [ "$BW_SOCAT" = "no" ] || [ "$ON_NO_SOCAT" = 1 ]; then
    CONCLUSION="socat is missing from the image these tasks ran, so this says nothing about bubblewrap yet: run again with --push-image, which puts the current image in ECR."
elif [ "$ON_DONE" = 0 ]; then
    CONCLUSION="The scrub-on task did not finish: read the log."
elif [ "$ON_STATE" = works ]; then
    CONCLUSION="Claude Code's scrub works in a Fargate task: the key is hidden from a command and no /proc/*/environ file holds it."
elif [ "$ON_STATE" = visible ]; then
    CONCLUSION="The scrub starts in a Fargate task, but the key is still visible to a command or to /proc/*/environ: see the ON line."
elif [ "$BW_FAIL" = 1 ]; then
    CONCLUSION="The scrub cannot run in a Fargate task with socat installed: bubblewrap cannot create what it needs (the BWRAP line), and Claude Code does not give the agent a working shell (the ON line)."
else
    CONCLUSION="No clear answer: the ON line shows no working scrub, and the BWRAP line shows no bubblewrap failure or has no marker. Read the log."
fi
if forms_failed "$ON_FORMS"; then
    CONCLUSION="$CONCLUSION With the scrub on, plain commands ran but the commands with \${} and a loop were refused or gave no output; scripts/run/first-runs.sh checks the key and /proc/*/environ (G4b, commands 5 and 6) with that kind of command."
fi
if [ "$CONTROL" = 1 ]; then
    if [ "$CTRL_DONE" = 0 ] || [ "$CTRL_KEY" = "n/a" ]; then
        CONCLUSION="$CONCLUSION (Control note: the control did not run its commands: read its log.)"
    elif [ "$CTRL_KEY" = "no" ]; then
        CONCLUSION="$CONCLUSION (Control note: the key was hidden with the scrub off, so the probe cannot tell the two settings apart here.)"
    fi
fi
case "$RUNNING" in
    0 | n/a | "") ;;
    *) CONCLUSION="$CONCLUSION (Tasks still running on the cluster: $RUNNING. Check: scripts/deploy/ecs-in-docker.sh exec aws ecs list-tasks --cluster $CLUSTER --desired-status RUNNING)" ;;
esac

SUMMARY="$(
    echo "$LINE_ON"
    [ -z "$LINE_CTRL" ] || echo "$LINE_CTRL"
    echo "$LINE_BW"
    echo "conclusion: $CONCLUSION"
)"

{
    echo "# check-scrub-fargate report"
    echo
    echo "- Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Repository commit: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "- Host: $(uname -sm)"
    echo "- Profile: $PROFILE"
    echo "- Image pushed by this run: $([ "$PUSH" = 1 ] && echo yes || echo no)"
    echo "- ECR $ECR_REPO:latest (digest, pushed at): $IMAGE_INFO"
    echo "- Tasks still running afterwards: $RUNNING"
    echo "- AWS identity (account masked):"
    echo
    echo '```'
    echo "$ID_OUT"
    echo '```'
    echo
    echo "## Summary"
    echo
    echo '```'
    echo "$SUMMARY"
    echo '```'
    echo
    echo "## The probe (ON and CONTROL)"
    echo
    echo '```'
    echo "$PROBE"
    echo '```'
    echo
    echo "## The direct probe (BWRAP)"
    echo
    echo '```'
    echo "$BWRAP_PROMPT"
    echo '```'
    for v in ON CONTROL BWRAP; do
        [ -f "$TMP/$v.out" ] || continue
        case "$v" in
            ON) cmd="scripts/run/run-task.sh --profile $PROFILE --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 --max-turns $MAX_TURNS --max-budget-usd 0.30 --prompt <the probe>" ;;
            CONTROL) cmd="scripts/run/run-task.sh --profile $PROFILE --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 --max-turns $MAX_TURNS --max-budget-usd 0.30 --prompt <the probe>" ;;
            BWRAP) cmd="scripts/run/run-task.sh --profile $PROFILE --max-turns $MAX_TURNS --max-budget-usd 0.40 --prompt <the direct probe>" ;;
        esac
        echo
        echo "## Task $v (exit $(cat "$TMP/$v.rc"))"
        echo
        echo "\`$cmd\`"
        echo
        echo '```'
        cat "$TMP/$v.out"
        echo '```'
    done
} > "$REPORT"

echo
echo "== summary (paste this back) =="
echo "$SUMMARY"
echo "report: $REPORT"
