#!/bin/bash
# Tests for check-scrub-local.sh against a stubbed `docker`: no Docker, no network, no API calls.
# Run:  scripts/run/test-check-scrub-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
BIN="$WORK/bin"
mkdir -p "$REPO/scripts/run" "$BIN"
export WORK

# The script works out its repository from its own location, so test a copy in a scratch tree.
cp "$SCRIPT_DIR/check-scrub-local.sh" "$REPO/scripts/run/"
CHECK="$REPO/scripts/run/check-scrub-local.sh"

# docker stub: logs every call. Which variant a `compose run` is comes from its flags; what it
# prints comes from STUB_A / STUB_B / STUB_C (default: A cannot create a namespace, B works, C sees the key).
cat > "$BIN/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$WORK/docker.log"
case "$1" in
    info)
        [ -z "${STUB_DOWN:-}" ] || exit 1
        [ "${2:-}" != "--format" ] || echo "[name=seccomp,profile=builtin]"
        exit 0 ;;
    version) echo "client 27.0.0, server 27.0.0"; exit 0 ;;
    image) echo "sha256:feedfacefeedface"; exit 0 ;;
    compose)
        case "$2" in
            version) exit 0 ;;
            build) [ -z "${STUB_BUILD_FAIL:-}" ] || { echo "build failed" >&2; exit 1; }; echo "built"; exit 0 ;;
            run)
                all=" $* "
                case "$all" in
                    *"SUBPROCESS_ENV_SCRUB=0"*) printf '%s\n' "${STUB_C:-key-VISIBLE
proc-environ-with-key: 3}" ;;
                    *"--cap-add SYS_ADMIN"*) printf '%s\n' "${STUB_B:-key-hidden
proc-environ-with-key: 0}" ;;
                    *) printf '%s\n' "${STUB_A:-bwrap: No permissions to create new namespace, likely because the kernel does not allow non-privileged user namespaces.
This command requires approval}" ;;
                esac
                exit 0 ;;
        esac ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"
export ANTHROPIC_API_KEY=sk-ant-test-value-not-real

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

reset() { rm -f "$WORK/docker.log" "$REPO"/scrub-check-*.md "$REPO/.env" "$WORK/report.md"; : > "$WORK/docker.log"; unset STUB_A STUB_B STUB_C STUB_DOWN STUB_BUILD_FAIL; }
checkit() { OUT="$("$CHECK" --report "$WORK/report.md" "$@" 2>&1 < /dev/null)" && RC=0 || RC=$?; }
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF -- "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}
logged() { grep -qF -- "$1" "$WORK/docker.log"; }
runs() { grep -c 'compose run' "$WORK/docker.log" || true; }

# ── the default case: A cannot, B can, C sees the key ──
reset; checkit
expect "exit 0 when the report is written" 0 "== summary (paste this back) =="
expect "A could not run: the namespace error is named" 0 "A  scrub on, default flags: COULD NOT RUN: bubblewrap could not create a namespace"
expect "B works: hidden key and 0 /proc files" 0 "B  scrub on, --cap-add SYS_ADMIN: WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it"
expect "the control sees the key" 0 "C  control, scrub off: DOES NOT HOLD: key in a command's environment: yes, /proc/*/environ files with the key: 3"
expect "the conclusion says it works only with the capability, and what that costs" 0 "works here only with --cap-add SYS_ADMIN, which loosens the container's own restrictions"
check "the image is built once" test "$(grep -c 'compose build claude-ecs-base' "$WORK/docker.log")" = 1
check "three runs are made" test "$(runs)" = 3
check "A runs with the scrub on and no extra capability" logged "compose run --rm -T -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 claude-ecs-base -p"
check "B adds --cap-add SYS_ADMIN" logged "compose run --rm -T --cap-add SYS_ADMIN -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 claude-ecs-base -p"
check "C switches the scrub off" logged "compose run --rm -T -e CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 claude-ecs-base -p"
check "every run has a turn and a spend cap" test "$(grep -c -- '--max-turns 6 --max-budget-usd 0.30' "$WORK/docker.log")" = 3
# shellcheck disable=SC2016  # the probe text holds literal $s and $n
check "the probe carries both marker commands" logged 'echo "key-$s"'
# shellcheck disable=SC2016
check "...and the /proc count" logged 'proc-environ-with-key: $n'
check "the report is written where asked" test -s "$WORK/report.md"
check "the report records the host, Docker's settings and the image" grep -q "Docker security options: \[name=seccomp,profile=builtin\]" "$WORK/report.md"
check "...each run's output" grep -q "^## Run B (exit 0)" "$WORK/report.md"
check "...and the summary" grep -qF "conclusion: " "$WORK/report.md"

# ── the other conclusions ──
reset; export STUB_A="key-hidden
proc-environ-with-key: 0"; checkit
expect "A works: default flags are enough" 0 "works in this Docker with its default flags"
reset; export STUB_B="This command requires approval"; checkit
expect "neither works: the scrub cannot run in this Docker" 0 "cannot run in this Docker"
expect "...and the control shows it is the sandbox, not the setup" 0 "so the cause is the sandbox, not the setup"
reset; export STUB_B="This command requires approval" STUB_C="This command requires approval"; checkit
expect "a control that cannot run either says to read the log" 0 "The control could not run its commands either"
reset; export STUB_C="key-hidden
proc-environ-with-key: 0"; checkit
expect "a control that hides the key too is flagged" 0 "the probe cannot tell the two settings apart here"
reset; export STUB_A="key-VISIBLE
proc-environ-with-key: 2"; checkit
expect "a key still visible with the scrub on is reported as such" 0 "A  scrub on, default flags: DOES NOT HOLD: key in a command's environment: yes, /proc/*/environ files with the key: 2"
reset; export STUB_A="key-hidden
proc-environ-with-key: 4"; checkit
expect "a hidden key with files still holding it does not count as working" 0 "A  scrub on, default flags: DOES NOT HOLD: key in a command's environment: no, /proc/*/environ files with the key: 4"

# ── options ──
reset; checkit --no-build
check "--no-build builds nothing" test -z "$(grep 'compose build' "$WORK/docker.log" || true)"
reset; checkit --no-control
check "--no-control makes two runs" test "$(runs)" = 2
check "...and has no control line" test -z "$(printf '%s' "$OUT" | grep -F 'C  control' || true)"
# The look-alike key is assembled here so that no secret-shaped string sits in this file (the export scans for them).
digit=3; LOOKALIKE="sk-ant-api0${digit}-REALLOOKINGSECRET123"
reset; export STUB_A="$LOOKALIKE key-hidden"; checkit
check "anything shaped like an Anthropic key is redacted in the report" test -z "$(grep -F 'REALLOOKINGSECRET123' "$WORK/report.md" || true)"
check "...and on screen" test -z "$(printf '%s' "$OUT" | grep -F 'REALLOOKINGSECRET123' || true)"
check "...and replaced by a marker" grep -qF 'sk-ant-REDACTED' "$WORK/report.md"
reset; OUT="$("$CHECK" 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "without --report the report goes to scrub-check-<time>.md in the repository" 0 "report: $REPO/scrub-check-"
check "...and the file exists" test -n "$(ls "$REPO"/scrub-check-*.md 2>/dev/null)"
reset; checkit --help
expect "--help prints the three variants" 0 "scrub on, Docker's default flags"

# ── refusals ──
reset; export STUB_DOWN=1; checkit
expect "Docker not running is refused, exit 2" 2 "Docker is not running"
check "...and nothing was run" test "$(runs)" = 0
reset; OUT="$(env -u ANTHROPIC_API_KEY "$CHECK" --report "$WORK/report.md" 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "no API key anywhere is refused, exit 2" 2 "no ANTHROPIC_API_KEY"
check "...and nothing was run" test "$(runs)" = 0
reset; printf 'ANTHROPIC_API_KEY=sk-ant-from-file\n' > "$REPO/.env"
OUT="$(env -u ANTHROPIC_API_KEY "$CHECK" --report "$WORK/report.md" 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "a key in .env is enough" 0 "== summary (paste this back) =="
reset; export STUB_BUILD_FAIL=1; checkit
expect "a failed build stops with exit 1" 1 "the image did not build"
check "...before any run" test "$(runs)" = 0
reset; checkit --bogus
expect "an unknown option is refused, exit 2" 2 "unknown option"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
