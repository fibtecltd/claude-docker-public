#!/bin/bash
# Tests for verify-scrub.sh against a stubbed ecs-in-docker.sh: no Docker, no network, no AWS.
# Run:  scripts/deploy/test-verify-scrub.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/deploy" "$REPO/scripts/private"
export WORK REPO

# The script works out its repository from its own location, so test a copy in a scratch tree.
cp "$SCRIPT_DIR/verify-scrub.sh" "$REPO/scripts/deploy/"
VERIFY="$REPO/scripts/deploy/verify-scrub.sh"
printf 'AWS_REGION=eu-west-1\nEXPECTED_ACCOUNT=123456789012\n' > "$REPO/scripts/private/test.env"
printf 'AWS_REGION=eu-west-1\n' > "$REPO/scripts/private/no-account.env"

# The wrapper stub logs every call. STUB_KEY / STUB_PROC / STUB_ROLE set the G4b answers (default
# yes); STUB_NOROW leaves no G4b row in the report; STUB_ACCOUNT is the account the credentials
# belong to. `latest` changes once `image` has been called.
cat > "$WORK/ecs-in-docker.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$WORK/calls.log"
args=" $* "
case "$args" in
    *" identity "*) echo "{\"Account\": \"${STUB_ACCOUNT:-123456789012}\", \"Arn\": \"arn:aws:iam::${STUB_ACCOUNT:-123456789012}:user/alice\"}" ;;
    *" exec aws ecr describe-images "*)
        if [ -f "$WORK/image.done" ]; then echo "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        else echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi ;;
    *" image "*) echo "stub: build, smoke-test, push"; : > "$WORK/image.done" ;;
    *" runs --groups G4 "*)
        echo "stub: first-runs G4"
        [ -z "${STUB_NORUN:-}" ] || exit 0
        {
            echo "# claude-ecs first runs"
            echo "| G4-role-egress | core | default | on-demand | 0 | 12s | 5s | 20s | 30s | 6 | 0.0803 |"
            if [ -z "${STUB_NOROW:-}" ]; then
                echo "| run | expected | observed | as designed |"
                echo "| G4-role-egress | a task role, ... | role: ${STUB_ROLE:-yes}, s3 denied: yes, 443 ok: yes, 80 blocked: yes, key hidden: ${STUB_KEY:-yes}, proc clean: ${STUB_PROC:-yes} | yes |"
            fi
            echo "**Behaved as designed: 2 of 2**"
            echo "- tasks still running in the cluster: 0"
            echo '- `ecs-deploy.sh verify` (exit 0):'
        } > "$REPO/first-runs-report.md" ;;
    *" exec scripts/run/run-task.sh "*) echo "stub: diagnostic task, exit=1" ;;
esac
exit 0
STUB
chmod +x "$WORK/ecs-in-docker.sh"
export ECS_IN_DOCKER="$WORK/ecs-in-docker.sh"

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

reset() { rm -f "$WORK/calls.log" "$WORK/image.done" "$REPO/first-runs-report.md"; : > "$WORK/calls.log"; unset STUB_KEY STUB_PROC STUB_ROLE STUB_NOROW STUB_NORUN STUB_ACCOUNT; }
verify() { OUT="$("$VERIFY" --config "$REPO/scripts/private/test.env" "$@" 2>&1 < /dev/null)" && RC=0 || RC=$?; }
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF -- "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}
called() { grep -qF -- "$1" "$WORK/calls.log"; }
line_of() { grep -nF -- "$1" "$WORK/calls.log" | head -n 1 | cut -d: -f1; }
before() { # before "name" A B: A is called before B
    local a b
    a="$(line_of "$2")"; b="$(line_of "$3")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else fail "$1 ('$2' at ${a:-none}, '$3' at ${b:-none})"; cat "$WORK/calls.log" >&2; fi
}

# ── a pass ──
reset; verify
expect "a hidden key and a clean /proc is a pass, exit 0" 0 "verdict: PASS"
before "the account is checked before the image is built" "test.env identity" "test.env image"
before "the image is pushed before the runs" "test.env image" "test.env runs --groups G4"
check "the runs are the guardrail group only" called "runs --groups G4"
check "no diagnostic task when it passes" test -z "$(grep -F 'exec scripts/run/run-task.sh' "$WORK/calls.log" || true)"
expect "the summary shows the image digest before and after" 0 "before sha256:aaaaaaaaaaaa, after sha256:bbbbbbbbbbbb"
expect "the summary carries the report's controls" 0 "tasks still running in the cluster: 0"

# ── the scrub does not hold ──
reset; export STUB_KEY=NO; verify
expect "a key visible to a command is a failure, exit 1" 1 "verdict: FAIL"
check "...and the diagnostic task runs, with the scrub off" called "--env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0"
expect "...and its output is shown with how to read it" 1 "non-zero means bubblewrap cannot create its namespaces"
reset; export STUB_PROC=NO; verify
expect "a /proc that still holds the key is a failure" 1 "no /proc/*/environ has it:   NO"
reset; export STUB_NOROW=1; verify
expect "no G4b row in the report is a failure" 1 "no G4b row"
check "...and the diagnostic task runs" called "exec scripts/run/run-task.sh"
reset; export STUB_NORUN=1; verify
expect "no report at all is a failure" 1 "no G4b row"

# ── a pass with a note ──
reset; export STUB_ROLE=NO; verify
expect "a hidden key with no task role from sts is still a pass" 0 "verdict: PASS"
expect "...with the note about the container credentials" 0 "sts no longer shows the task role"

# ── options and refusals ──
reset; verify --skip-image
expect "--skip-image passes" 0 "skipped (--skip-image)"
check "...and builds nothing" test -z "$(grep -E 'test.env image' "$WORK/calls.log" || true)"
reset; export STUB_ACCOUNT=999999999999; verify
expect "credentials of another account are refused, exit 2" 2 "another account"
check "...before anything is built or run" test -z "$(grep -E 'test.env (image|runs)' "$WORK/calls.log" || true)"
reset; OUT="$("$VERIFY" --config "$REPO/scripts/private/no-account.env" 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "a settings file without EXPECTED_ACCOUNT is refused" 2 "EXPECTED_ACCOUNT is not set"
reset; verify --bogus
expect "an unknown option is refused" 2 "unknown option"
reset; verify --help
expect "--help prints the steps" 0 "does the credential scrub work"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
