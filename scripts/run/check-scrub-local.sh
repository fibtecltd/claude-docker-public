#!/usr/bin/env bash
# ============================================================
# check-scrub-local.sh - can Claude Code's credential scrub run in YOUR Docker?
#
#   scripts/run/check-scrub-local.sh [--no-build] [--no-control] [--report FILE]
#
# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 hides the API key from the commands the agent runs, but it runs
# them through bubblewrap, which needs permission to create namespaces. A container may not have it
# (a Fargate task does not). This script runs a five-command probe against the image of the
# claude-ecs-base service in docker-compose.yml, three ways, and says what it saw:
#   A  scrub on, Docker's default flags
#   B  scrub on, --cap-add SYS_ADMIN (what bubblewrap usually needs in a container; it loosens
#      the container's own restrictions, so weigh that before relying on it)
#   C  control: scrub off, to show the probe can see the key (skipped with --no-control)
# The probe asks the agent to run five shell commands that print a marker, never the key. Three are
# plain: a trivial one, whether ANTHROPIC_API_KEY is in the command's environment, and how many
# /proc/*/environ files hold it. Two make the same two checks with a ${} expansion and a for loop,
# the forms scripts/run/first-runs.sh uses (G4b, commands 5 and 6). In the first Docker-on-a-Mac run
# Claude Code answered those two with "can't be checked before it runs" and nothing else was tried,
# so the plain commands now tell a sandbox that cannot start (nothing runs) from a refusal of the
# form of a command (the plain ones run, the last two do not).
#
# It writes a report (the host, the Docker settings, the exact commands, each run's output with
# anything shaped like an Anthropic key redacted, and the verdicts) to scrub-check-<time>.md in
# the repository (git-ignored) and prints the summary to paste back.
#
# Cost: each run is capped at 10 turns and USD 0.30, so at most USD 0.90.
# Needs: Docker with Compose, and ANTHROPIC_API_KEY exported or in .env.
# Exit code: 0 the report was written (the verdicts are results, not failures); 1 the image did
# not build; 2 a prerequisite is missing (nothing was started). Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICE="claude-ecs-base"
MAX_TURNS=10 MAX_BUDGET=0.30 # per run; five commands one at a time need five turns and the answer

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "check-scrub-local: $*" >&2; exit 2; }

BUILD=1 CONTROL=1 REPORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --no-control) CONTROL=0; shift ;;
        --report) REPORT="${2:?--report needs a file}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[ -n "$REPORT" ] || REPORT="$REPO_DIR/scrub-check-$(date -u +%Y%m%d-%H%M%S).md"

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "Docker is not running"
docker compose version >/dev/null 2>&1 || die "docker compose is not available"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    { [ -f "$REPO_DIR/.env" ] && grep -q '^ANTHROPIC_API_KEY=.' "$REPO_DIR/.env"; } \
        || die "no ANTHROPIC_API_KEY: export it, or put it in $REPO_DIR/.env (cp .env.example .env)"
fi
cd "$REPO_DIR"

# The probe. The markers are built at run time ("plain-%s", "key-$s", "...: $n"), so an agent that
# quotes a command in its answer cannot match them by accident. Commands 1-3 use no ${}, loop or
# command substitution; 4 and 5 are the forms first-runs.sh uses.
IFS= read -r -d '' PROMPT <<'EOF' || true
Run these five shell commands, one at a time, and report each output, nothing else. The commands are the text between backticks.
1) `printf 'plain-%s\n' ok`
2) `printenv ANTHROPIC_API_KEY >/dev/null && printf 'plain-key=%s\n' VISIBLE || printf 'plain-key=%s\n' hidden`
3) `grep -la ANTHROPIC_API_KEY /proc/[0-9]*/environ 2>/dev/null | wc -l | sed 's/^/plain-proc=/'`
4) `if [ -n "${ANTHROPIC_API_KEY:-}" ]; then s=VISIBLE; else s=hidden; fi; echo "key-$s"`
5) `n=0; for f in /proc/[0-9]*/environ; do grep -qa ANTHROPIC_API_KEY "$f" 2>/dev/null && n=$((n+1)); done; echo "proc-environ-with-key: $n"`
If a command is blocked or prints an error, report the message exactly and go on with the next one. Never print the value of any variable.
EOF
PROMPT="${PROMPT//$'\n'/ }"
PROMPT="${PROMPT% }"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$BUILD" = 1 ]; then
    echo "== build $SERVICE =="
    docker compose build "$SERVICE" || { echo "check-scrub-local: the image did not build (see above)" >&2; exit 1; }
fi

redact() { sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-REDACTED/g'; }

# run_variant LABEL SCRUB [EXTRA docker compose run FLAGS...]: output in $TMP/LABEL.out, exit code in $TMP/LABEL.rc
run_variant() {
    local label="$1" scrub="$2" rc=0
    shift 2
    echo "== run $label (scrub=$scrub${1:+, $*}) =="
    docker compose run --rm -T "$@" -e "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=$scrub" "$SERVICE" \
        -p "$PROMPT" --max-turns "$MAX_TURNS" --max-budget-usd "$MAX_BUDGET" > "$TMP/$label.raw" 2>&1 || rc=$?
    redact < "$TMP/$label.raw" > "$TMP/$label.out"
    echo "$rc" > "$TMP/$label.rc"
    tail -n 16 "$TMP/$label.out"
}

run_variant A 1
run_variant B 1 --cap-add SYS_ADMIN
[ "$CONTROL" = 0 ] || run_variant C 0

# What a run showed. KEYVIS (yes/no/n/a) and PROCN (a number or n/a) come from the plain commands,
# or from the ${}/loop commands where the plain ones gave no answer. PLAIN: a plain command ran.
# FORMS: how the two ${}/loop commands fared (ran, only one ran, refused, gave no output); set only
# when a plain command ran. NOTE: why nothing ran, or why the key check gave no answer.
classify() {
    local f="$TMP/$1.out" p_key="n/a" p_proc c_key="n/a" c_proc seen=0
    KEYVIS="n/a" PROCN="n/a" PLAIN="no" FORMS="n/a" NOTE="" REASON=""
    if grep -q 'plain-key=VISIBLE' "$f"; then p_key=yes; elif grep -q 'plain-key=hidden' "$f"; then p_key=no; fi
    p_proc="$(sed -n 's/.*plain-proc=\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)"
    [ -n "$p_proc" ] || p_proc="n/a"
    if grep -q 'key-VISIBLE' "$f"; then c_key=yes; elif grep -q 'key-hidden' "$f"; then c_key=no; fi
    c_proc="$(sed -n 's/.*proc-environ-with-key: \([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)"
    [ -n "$c_proc" ] || c_proc="n/a"
    if grep -q 'plain-ok' "$f" || [ "$p_key" != "n/a" ] || [ "$p_proc" != "n/a" ]; then PLAIN=yes; fi
    KEYVIS="$p_key"; [ "$KEYVIS" != "n/a" ] || KEYVIS="$c_key"
    PROCN="$p_proc"; [ "$PROCN" != "n/a" ] || PROCN="$c_proc"
    [ "$c_key" = "n/a" ] || seen=$((seen + 1))
    [ "$c_proc" = "n/a" ] || seen=$((seen + 1))
    if [ "$PLAIN" = "yes" ]; then
        if [ "$seen" = 2 ]; then FORMS="ran"
        elif [ "$seen" = 1 ]; then FORMS="only one ran"
        elif grep -qi 'requires approval\|blocked\|can.t be checked' "$f"; then FORMS="refused"
        else FORMS="gave no output"; fi
    fi
    if [ "$KEYVIS" = "n/a" ]; then
        if [ "$PLAIN" = "yes" ]; then
            NOTE="a plain command ran, but the key check gave no answer"
        elif grep -qi 'No permissions to create new namespace' "$f"; then
            NOTE="bubblewrap could not create a namespace"
        elif grep -qi 'bwrap:' "$f"; then
            NOTE="bubblewrap failed"
        elif grep -qi 'Sandbox is required\|requires approval\|blocked\|can.t be checked' "$f"; then
            NOTE="every command was blocked, even a trivial one"
        else
            NOTE="no marker in the output (see the log)"
        fi
        # The agent's words for why: the first line that says so, from "bwrap:" on if it has one, without list
        # numbers, backticks or the agent's own markdown around the message; cut at 200 characters.
        REASON="$(grep -m1 -i 'Sandbox is required\|bwrap:\|requires approval\|can.t be checked' "$f")" || REASON=""
        case "$REASON" in *bwrap:*) REASON="bwrap:${REASON#*bwrap:}" ;; esac
        # shellcheck disable=SC2016  # the backticks are characters for sed to strip, not a command substitution
        REASON="$(printf '%s' "$REASON" \
            | sed 's/^[[:space:]]*[0-9]*[.)]*[[:space:]]*//; s/^[`[:space:]]*//; s/[`[:space:]]*$//; s/`\.$//' | cut -c1-200)"
    fi
}
works() { [ "$KEYVIS" = "no" ] && [ "$PROCN" = "0" ]; } # the key is hidden and no /proc/*/environ holds it
state() { # the class of the run just classified: works, visible (key still seen), partly (plain commands ran only) or blocked
    if works; then echo works
    elif [ "$KEYVIS" != "n/a" ]; then echo visible
    elif [ "$PLAIN" = "yes" ]; then echo partly
    else echo blocked; fi
}
forms_failed() { [ "$1" = "refused" ] || [ "$1" = "gave no output" ]; } # a FORMS value

verdict_line() { # verdict_line LABEL TEXT -> "A  scrub on, default flags: ..."
    classify "$1"
    local what
    case "$(state)" in
        works) what="WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it" ;;
        visible) what="DOES NOT HOLD: key in a command's environment: $KEYVIS, /proc/*/environ files with the key: $PROCN" ;;
        partly) what="PARTLY RAN: $NOTE" ;;
        *) what="COULD NOT RUN: $NOTE" ;;
    esac
    [ -z "$REASON" ] || what="$what; the agent reported: \"$REASON\""
    [ "$PLAIN" != "yes" ] || what="$what; the commands with \${} and a loop: $FORMS"
    printf '%s  %s: %s (exit %s)\n' "$1" "$2" "$what" "$(cat "$TMP/$1.rc")"
}

LINE_A="$(verdict_line A 'scrub on, default flags')"; classify A; STATE_A="$(state)"; FORMS_A="$FORMS"
LINE_B="$(verdict_line B 'scrub on, --cap-add SYS_ADMIN')"; classify B; STATE_B="$(state)"; FORMS_B="$FORMS"
LINE_C=""; C_RAN="n/a"
if [ "$CONTROL" = 1 ]; then
    LINE_C="$(verdict_line C 'control, scrub off')"; classify C; C_RAN="$KEYVIS"
fi

if [ "$STATE_A" = works ]; then
    CONCLUSION="Claude Code's scrub works in this Docker with its default flags."
elif [ "$STATE_B" = works ]; then
    CONCLUSION="The scrub works here only with --cap-add SYS_ADMIN, which loosens the container's own restrictions: weigh that before relying on it."
elif [ "$STATE_A" = visible ] || [ "$STATE_B" = visible ]; then
    CONCLUSION="The scrub starts here, but the key is still visible to a command or to /proc/*/environ: see the lines above."
elif [ "$STATE_A" = partly ] || [ "$STATE_B" = partly ]; then
    CONCLUSION="Plain commands run with the scrub on here, but the key and /proc checks gave no answer: read the log."
else
    CONCLUSION="The scrub cannot run in this Docker: neither with its default flags nor with --cap-add SYS_ADMIN, and not even a plain command ran."
    if [ "$CONTROL" = 1 ]; then
        if [ "$C_RAN" = "yes" ]; then CONCLUSION="$CONCLUSION The control ran its commands with the scrub off, so what stops them is the scrub-on sandbox: the lines above quote what the agent reported, and a missing package in the image shows up there."
        elif [ "$C_RAN" = "no" ]; then CONCLUSION="$CONCLUSION The control showed no key even with the scrub off, which is unexpected: read its log."
        else CONCLUSION="$CONCLUSION The control could not run its commands either: read the log before drawing a conclusion."; fi
    fi
fi
if forms_failed "$FORMS_A" || forms_failed "$FORMS_B"; then
    CONCLUSION="$CONCLUSION With the scrub on, plain commands ran but the commands with \${} and a loop were refused or gave no output; scripts/run/first-runs.sh checks the key and /proc/*/environ (G4b, commands 5 and 6) with that kind of command."
fi
if [ "$CONTROL" = 1 ] && [ "$C_RAN" = "no" ]; then
    CONCLUSION="$CONCLUSION (Control note: the key was hidden with the scrub off, so the probe cannot tell the two settings apart here.)"
fi

SUMMARY="$(
    echo "$LINE_A"
    echo "$LINE_B"
    [ -z "$LINE_C" ] || echo "$LINE_C"
    echo "conclusion: $CONCLUSION"
)"

{
    echo "# check-scrub-local report"
    echo
    echo "- Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Repository commit: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "- Host: $(uname -sm)"
    echo "- Docker: $(docker version --format 'client {{.Client.Version}}, server {{.Server.Version}}' 2>/dev/null || echo n/a)"
    echo "- Docker security options: $(docker info --format '{{.SecurityOptions}}' 2>/dev/null || echo n/a)"
    echo "- Image: $(docker image inspect "$SERVICE:latest" --format '{{.Id}}' 2>/dev/null || echo n/a)"
    echo
    echo "## Summary"
    echo
    echo '```'
    echo "$SUMMARY"
    echo '```'
    echo
    echo "## The probe"
    echo
    echo '```'
    echo "$PROMPT"
    echo '```'
    for v in A B C; do
        [ -f "$TMP/$v.out" ] || continue
        case "$v" in
            A) cmd='docker compose run --rm -T -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 '"$SERVICE" ;;
            B) cmd='docker compose run --rm -T --cap-add SYS_ADMIN -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 '"$SERVICE" ;;
            C) cmd='docker compose run --rm -T -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 '"$SERVICE" ;;
        esac
        echo
        echo "## Run $v (exit $(cat "$TMP/$v.rc"))"
        echo
        echo "\`$cmd -p <the probe> --max-turns $MAX_TURNS --max-budget-usd $MAX_BUDGET\`"
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
