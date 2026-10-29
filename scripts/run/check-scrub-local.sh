#!/usr/bin/env bash
# ============================================================
# check-scrub-local.sh - can Claude Code's credential scrub run in YOUR Docker?
#
#   scripts/run/check-scrub-local.sh [--no-build] [--no-control] [--report FILE]
#
# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 hides the API key from the commands the agent runs, but it runs
# them through bubblewrap, which needs permission to create namespaces. A container may not have it
# (a Fargate task does not). This script runs a two-command probe against the image of the
# claude-ecs-base service in docker-compose.yml, three ways, and says what it saw:
#   A  scrub on, Docker's default flags
#   B  scrub on, --cap-add SYS_ADMIN (what bubblewrap usually needs in a container; it loosens
#      the container's own restrictions, so weigh that before relying on it)
#   C  control: scrub off, to show the probe can see the key (skipped with --no-control)
# The probe asks the agent to run two shell commands that print a marker, never the key: whether
# ANTHROPIC_API_KEY is in the command's environment, and how many /proc/*/environ files hold it.
#
# It writes a report (the host, the Docker settings, the exact commands, each run's output with
# anything shaped like an Anthropic key redacted, and the verdicts) to scrub-check-<time>.md in
# the repository (git-ignored) and prints the summary to paste back.
#
# Cost: each run is capped at 6 turns and USD 0.30, so at most USD 0.90 (about USD 0.05-0.15
# in practice). Needs: Docker with Compose, and ANTHROPIC_API_KEY exported or in .env.
# Exit code: 0 the report was written (the verdicts are results, not failures); 1 the image did
# not build; 2 a prerequisite is missing (nothing was started). Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICE="claude-ecs-base"

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

# The probe. The markers are built at run time ("key-$s", "...: $n"), so an agent that quotes the
# command in its answer cannot match them by accident.
IFS= read -r -d '' PROMPT <<'EOF' || true
Run these two shell commands, one at a time, and report each output, nothing else. The commands are the text between backticks.
1) `if [ -n "${ANTHROPIC_API_KEY:-}" ]; then s=VISIBLE; else s=hidden; fi; echo "key-$s"`
2) `n=0; for f in /proc/[0-9]*/environ; do grep -qa ANTHROPIC_API_KEY "$f" 2>/dev/null && n=$((n+1)); done; echo "proc-environ-with-key: $n"`
If a command is blocked or prints an error, report the message exactly. Never print the value of any variable.
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
        -p "$PROMPT" --max-turns 6 --max-budget-usd 0.30 > "$TMP/$label.raw" 2>&1 || rc=$?
    redact < "$TMP/$label.raw" > "$TMP/$label.out"
    echo "$rc" > "$TMP/$label.rc"
    tail -n 12 "$TMP/$label.out"
}

run_variant A 1
run_variant B 1 --cap-add SYS_ADMIN
[ "$CONTROL" = 0 ] || run_variant C 0

# What a run showed: KEYVIS (yes/no/n/a), PROCN (a number or n/a), NOTE (why it could not run, if so).
classify() {
    local f="$TMP/$1.out"
    KEYVIS="n/a" PROCN="n/a" NOTE=""
    if grep -q 'key-VISIBLE' "$f"; then KEYVIS=yes; elif grep -q 'key-hidden' "$f"; then KEYVIS=no; fi
    PROCN="$(sed -n 's/.*proc-environ-with-key: \([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)"
    [ -n "$PROCN" ] || PROCN="n/a"
    if [ "$KEYVIS" = "n/a" ]; then
        if grep -qi 'No permissions to create new namespace\|bwrap:' "$f"; then
            NOTE="bubblewrap could not create a namespace"
        elif grep -qi 'requires approval\|blocked\|can.t be checked' "$f"; then
            NOTE="the agent's commands were blocked"
        else
            NOTE="no marker in the output (see the log)"
        fi
    fi
}
works() { [ "$KEYVIS" = "no" ] && [ "$PROCN" = "0" ]; } # the key is hidden and no /proc/*/environ holds it

verdict_line() { # verdict_line LABEL TEXT -> "A  scrub on, default flags: ..."
    classify "$1"
    local what
    if works; then what="WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it"
    elif [ "$KEYVIS" != "n/a" ]; then what="DOES NOT HOLD: key in a command's environment: $KEYVIS, /proc/*/environ files with the key: $PROCN"
    else what="COULD NOT RUN: $NOTE"; fi
    printf '%s  %s: %s (exit %s)\n' "$1" "$2" "$what" "$(cat "$TMP/$1.rc")"
}

LINE_A="$(verdict_line A 'scrub on, default flags')"; classify A; A_WORKS=0; ! works || A_WORKS=1
LINE_B="$(verdict_line B 'scrub on, --cap-add SYS_ADMIN')"; classify B; B_WORKS=0; ! works || B_WORKS=1
LINE_C=""; C_RAN="n/a"
if [ "$CONTROL" = 1 ]; then
    LINE_C="$(verdict_line C 'control, scrub off')"; classify C; C_RAN="$KEYVIS"
fi

if [ "$A_WORKS" = 1 ]; then
    CONCLUSION="Claude Code's scrub works in this Docker with its default flags."
elif [ "$B_WORKS" = 1 ]; then
    CONCLUSION="The scrub works here only with --cap-add SYS_ADMIN, which loosens the container's own restrictions: weigh that before relying on it."
else
    CONCLUSION="The scrub cannot run in this Docker: neither with its default flags nor with --cap-add SYS_ADMIN."
    if [ "$CONTROL" = 1 ]; then
        if [ "$C_RAN" = "yes" ]; then CONCLUSION="$CONCLUSION The control ran its commands with the scrub off, so the cause is the sandbox, not the setup."
        elif [ "$C_RAN" = "no" ]; then CONCLUSION="$CONCLUSION The control showed no key even with the scrub off, which is unexpected: read its log."
        else CONCLUSION="$CONCLUSION The control could not run its commands either: read the log before drawing a conclusion."; fi
    fi
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
        echo "\`$cmd -p <the probe> --max-turns 6 --max-budget-usd 0.30\`"
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
