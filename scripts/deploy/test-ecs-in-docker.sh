#!/bin/bash
# Tests for ecs-in-docker.sh against a stubbed `docker`: no Docker, no network, no AWS.
# Run:  scripts/deploy/test-ecs-in-docker.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"
BIN="$WORK/bin"
REPO="$WORK/repo"
mkdir -p "$BIN" "$FIX" "$REPO/scripts/deploy" "$REPO/scripts/private"
export FIX WORK

# The wrapper works out its repository from its own location, so test a copy in a scratch tree.
cp "$SCRIPT_DIR/ecs-in-docker.sh" "$REPO/scripts/deploy/"
WRAP="$REPO/scripts/deploy/ecs-in-docker.sh"
cat > "$REPO/scripts/private/test.env" <<'CFG'
AWS_REGION=eu-west-1
CPU_ARCH=ARM64
CFG
cat > "$WORK/smoke" <<'STUB'
#!/bin/bash
echo "smoke $*" >> "$WORK/docker.log"
STUB
chmod +x "$WORK/smoke"
export SMOKE_TEST="$WORK/smoke"

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

cat > "$BIN/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$WORK/docker.log"
echo "$1 cfg=${DOCKER_CONFIG:-unset} host=${DOCKER_HOST:-unset}" >> "$WORK/docker.env.log"
case "$1" in
    context) [ ! -f "$FIX/no_context" ] || exit 1; echo "unix:///tmp/test.sock"; exit 0 ;;
    info) [ ! -f "$FIX/docker_down" ] || exit 1; exit 0 ;;
    image) [ ! -f "$FIX/no_tools_image" ] || exit 1; exit 0 ;;
    build | tag) exit 0 ;;
    push) cat "$DOCKER_CONFIG/config.json" >> "$WORK/push.config" 2>/dev/null || echo "NO-CONFIG" >> "$WORK/push.config"; exit 0 ;;
    login) cat > "$WORK/login.stdin"; exit 0 ;;
    run)
        all=" $* "
        case "$all" in *" -i "* | *" -it "*) cat >> "$WORK/stdin.log" ;; esac
        case "$all" in
            *RepositoryUri*) echo "123456789012.dkr.ecr.eu-west-1.amazonaws.com/claude-ecs" ;;
            *StackStatus*)
                [ -f "$FIX/stack_status" ] || exit 254
                cat "$FIX/stack_status" ;;
            *get-login-password*) echo "token-xyz" ;;
            *get-secret-value*)
                [ -f "$FIX/secret_value" ] || exit 254
                cat "$FIX/secret_value" ;;
            *get-caller-identity*) echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/alice"}' ;;
            *ecs-deploy.sh*)
                sub="${all% }"; sub="${sub##* }"
                echo "stub ecs-deploy $sub"
                [ ! -f "$FIX/rc_$sub" ] || exit "$(cat "$FIX/rc_$sub")" ;;
            *first-runs.sh*) echo "stub first-runs" ;;
        esac
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

reset() { rm -rf "$FIX" "$WORK/docker.env.log" "$WORK/docker.log" "$WORK/stdin.log" "$WORK/login.stdin" "$WORK/push.config"; mkdir -p "$FIX"; : > "$WORK/docker.log"; }
wrap() { # wrap ARGS...: OUT and RC
    OUT="$(cd "$WORK" && "$WRAP" --config "$REPO/scripts/private/test.env" "$@" 2>&1 < /dev/null)" && RC=0 || RC=$?
}
expect() { # expect "name" EXIT_CODE "text that must be in the output"
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qF -- "$3"; then ok "$1"; else fail "$1 (exit $RC, wanted $2, text '$3')"; echo "$OUT" >&2; fi
}
logged() { grep -qF -- "$1" "$WORK/docker.log"; }
line_of() { grep -nF -- "$1" "$WORK/docker.log" | head -n 1 | cut -d: -f1; }
before() { # before "name" A B: A appears in the docker log before B
    local a b
    a="$(line_of "$2")"; b="$(line_of "$3")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else fail "$1 ('$2' at ${a:-none}, '$3' at ${b:-none})"; cat "$WORK/docker.log" >&2; fi
}

export AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=examplesecret
export ANTHROPIC_API_KEY=sk-ant-test-key

# ── refusals ──
reset; env -u AWS_ACCESS_KEY_ID "$WRAP" --config "$REPO/scripts/private/test.env" deploy > "$WORK/o" 2>&1 < /dev/null && RC=0 || RC=$?
OUT="$(cat "$WORK/o")"
expect "no AWS credentials at all is refused" 1 "no AWS credentials"
if ! logged "docker build"; then ok "...and nothing was built"; else fail "built without credentials"; fi

reset; : > "$FIX/docker_down"; wrap deploy
expect "Docker not running is refused" 1 "Docker is not running"

reset; OUT="$(cd "$WORK" && "$WRAP" --config /etc/hostname deploy 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "a config outside the repository is refused" 1 "must be inside"

reset; wrap
expect "no command prints usage, exit 2" 2 "Commands"

reset; wrap exec aws ecr describe-images --repository-name claude-ecs
check "exec runs the command in the tools container, repository at /work" logged "-v $REPO:/work -w /work"
check "...with the command and its options as given" logged "claude-ecs-deploy:local aws ecr describe-images --repository-name claude-ecs"
reset; wrap exec
expect "exec without a command is refused" 1 "exec needs a command"

# ── keys from an env file ──
printf '%s\n' '# comment' 'AWS_ACCESS_KEY_ID=AKIAFROMFILE' "AWS_SECRET_ACCESS_KEY='file secret'" \
    'export ANTHROPIC_API_KEY="sk-ant-from-file"' 'OTHER=not-read' > "$WORK/keys.env"
reset; OUT="$(cd "$WORK" && env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u ANTHROPIC_API_KEY "$WRAP" \
    --config "$REPO/scripts/private/test.env" --env-file "$WORK/keys.env" --use-env-key deploy 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "keys come from --env-file when not exported" 0 "Read from $WORK/keys.env: AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY ANTHROPIC_API_KEY"
check "...and the quoted key reaches the container on stdin" grep -q "^sk-ant-from-file$" "$WORK/stdin.log"
if ! grep -qE "AKIAFROMFILE|file secret|sk-ant-from-file" "$WORK/docker.log"; then ok "...and no value is on a command line"; else fail "env-file value in argv"; fi
if ! printf '%s' "$OUT" | grep -qE "AKIAFROMFILE|file secret|sk-ant-from-file"; then ok "...or in the output"; else fail "env-file value printed"; fi
reset; printf 'AWS_ACCESS_KEY_ID=AKIAFROMFILE\r\nAWS_SECRET_ACCESS_KEY=x\r\n' > "$WORK/crlf.env"
OUT="$(cd "$WORK" && env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY "$WRAP" --config "$REPO/scripts/private/test.env" \
    --env-file "$WORK/crlf.env" identity 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "a file with Windows line endings works" 0 "alice"
reset; printf 'AWS_ACCESS_KEY_ID=AKIAFROMFILE\nAWS_SECRET_ACCESS_KEY=x\n' > "$REPO/.env"
OUT="$(cd "$WORK" && env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY "$WRAP" --config "$REPO/scripts/private/test.env" identity 2>&1 < /dev/null)" && RC=0 || RC=$?
expect ".env in the repository is read by default" 0 "Read from $REPO/.env"
reset; OUT="$(cd "$WORK" && AWS_ACCESS_KEY_ID=AKIAEXPORTED "$WRAP" --config "$REPO/scripts/private/test.env" identity 2>&1 < /dev/null)" && RC=0 || RC=$?
if ! printf '%s' "$OUT" | grep -q "AWS_ACCESS_KEY_ID"; then ok "an exported variable wins over the file"; else fail "file overrode the environment"; echo "$OUT" >&2; fi
rm -f "$REPO/.env"
reset; OUT="$(cd "$WORK" && "$WRAP" --config "$REPO/scripts/private/test.env" --env-file /nonexistent identity 2>&1 < /dev/null)" && RC=0 || RC=$?
expect "a missing --env-file is refused" 1 "no env file"

# ── a fresh deploy ──
reset; wrap deploy --use-env-key
expect "fresh deploy completes" 0 "Deployed. Next:"
check "base image built for arm64" logged "--platform linux/arm64 --target ecs-base -t claude-ecs-base:local"
check "tools image built for arm64" logged "--platform linux/arm64 --target ecs-deploy -t claude-ecs-deploy:local"
before "smoke test runs before any AWS change" "smoke claude-ecs-base:local base" "ecs-deploy.sh --config /work/scripts/private/test.env stack"
before "stack comes before the image push" "ecs-deploy.sh --config /work/scripts/private/test.env stack" "docker push"
before "image push comes before verify" "docker push" "ecs-deploy.sh --config /work/scripts/private/test.env verify"
check "latest is pushed" logged "docker push 123456789012.dkr.ecr.eu-west-1.amazonaws.com/claude-ecs:latest"
check "the commit tag is pushed" logged "docker push 123456789012.dkr.ecr.eu-west-1.amazonaws.com/claude-ecs:local"
expected_auth="$(printf 'AWS:token-xyz' | base64 | tr -d '\n')"
check "the push config holds the ECR login made from the container's token" grep -qF "\"auth\":\"$expected_auth\"" "$WORK/push.config"
check "...for the registry host" grep -qF '"123456789012.dkr.ecr.eu-west-1.amazonaws.com"' "$WORK/push.config"
check "there is no docker login at all (it would reach for the keychain)" test ! -e "$WORK/login.stdin"
check "the key reaches the container on stdin" grep -q "sk-ant-test-key" "$WORK/stdin.log"
if ! grep -q "sk-ant-test-key" "$WORK/docker.log"; then ok "the key is never on a command line"; else fail "key leaked into argv"; fi
check "AWS credentials are passed by name, not value" logged "-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN"
if ! grep -q "examplesecret" "$WORK/docker.log"; then ok "credential values are not on a command line"; else fail "credentials in argv"; fi
check "the repository is mounted" logged "-v $REPO:/work"
check "the image's own venv is used" logged "-e ECS_DEPLOY_VENV=/opt/venv"

check "UNKNOWN checks do not stop a deploy by default" logged "-e ALLOW_UNKNOWN=1"
reset; wrap deploy --use-env-key --strict
check "--strict turns that off" logged "-e ALLOW_UNKNOWN=0"

# the push must not touch the keychain: a throwaway config that already holds the login
cfgdir="$(grep '^push ' "$WORK/docker.env.log" | head -n 1 | sed 's/^push cfg=\([^ ]*\) .*/\1/')"
check "the push uses a throwaway Docker config, not the user's" test -n "$cfgdir" -a "$cfgdir" != unset
check "...with the current daemon passed explicitly" grep -q '^push .* host=unix:///tmp/test.sock$' "$WORK/docker.env.log"
check "...the same one for both tags" test "$(grep -c "^push cfg=$cfgdir host=unix:///tmp/test.sock\$" "$WORK/docker.env.log")" = 2
check "...which is removed afterwards" test ! -d "$cfgdir"
reset; : > "$FIX/no_context"; wrap deploy --use-env-key
expect "without a readable docker context the push still works" 0 "Deployed. Next:"
check "...and no daemon is forced" grep -q '^push cfg=[^ ]* host=unset$' "$WORK/docker.env.log"
reset; wrap deploy --use-env-key --yes
check "--yes passes ASSUME_YES=1 to the container" logged "-e ASSUME_YES=1"
reset; wrap deploy --use-env-key
check "without --yes the container is told nothing" logged "-e ASSUME_YES= "

# ── resume: nothing to redo ──
reset; echo CREATE_COMPLETE > "$FIX/stack_status"; echo "sk-ant-real" > "$FIX/secret_value"; wrap deploy --use-env-key
expect "a deployed stack and a stored key are skipped" 0 "already deployed"
if ! logged "ecs-deploy.sh --config /work/scripts/private/test.env stack"; then ok "stack step not repeated"; else fail "stack repeated"; fi
if ! logged "ecs-deploy.sh --config /work/scripts/private/test.env secret"; then ok "secret step not repeated"; else fail "secret repeated"; fi
check "the image is still pushed" logged "docker push"

reset; echo CREATE_COMPLETE > "$FIX/stack_status"; echo "replace-me-with-put-secret-value" > "$FIX/secret_value"; wrap deploy --use-env-key
expect "the placeholder secret is replaced" 0 "Deployed. Next:"
check "secret step ran" logged "ecs-deploy.sh --config /work/scripts/private/test.env secret"

# ── stops ──
reset; echo 1 > "$FIX/rc_stack"; wrap deploy --use-env-key
expect "a NO-GO from the stack step stops everything" 1 "the stack step stopped"
if ! logged "docker push"; then ok "...and nothing is pushed"; else fail "pushed after NO-GO"; fi
if ! logged "ecs-deploy.sh --config /work/scripts/private/test.env secret"; then ok "...and no key is stored"; else fail "key stored after NO-GO"; fi

reset; echo ROLLBACK_COMPLETE > "$FIX/stack_status"; wrap deploy --use-env-key
expect "a stack in a failed state stops" 1 "ROLLBACK_COMPLETE"

reset; env -u ANTHROPIC_API_KEY "$WRAP" --config "$REPO/scripts/private/test.env" --use-env-key deploy > "$WORK/o" 2>&1 < /dev/null && RC=0 || RC=$?
OUT="$(cat "$WORK/o")"
expect "--use-env-key without the variable stops" 1 "ANTHROPIC_API_KEY is not exported"
if ! logged "docker push"; then ok "...before anything is pushed"; else fail "pushed without a key"; fi

# ── single steps ──
reset; wrap runs --groups G1 --dry-run
expect "runs forwards its arguments to first-runs.sh" 0 "stub first-runs"
check "...with the container path of the config" logged "scripts/run/first-runs.sh --config /work/scripts/private/test.env --groups G1 --dry-run"
if ! logged "docker build"; then ok "runs reuses the tools image"; else fail "runs rebuilt"; fi

reset; : > "$FIX/no_tools_image"; wrap verify
expect "a missing tools image is built on first use" 0 "stub ecs-deploy verify"
check "...for the stack's platform" logged "--target ecs-deploy -t claude-ecs-deploy:local"

reset; sed 's/ARM64/X86_64/' "$REPO/scripts/private/test.env" > "$REPO/scripts/private/x86.env"
OUT="$(cd "$WORK" && "$WRAP" --config "$REPO/scripts/private/x86.env" image 2>&1 < /dev/null)" && RC=0 || RC=$?
check "X86_64 builds for linux/amd64" logged "--platform linux/amd64 --target ecs-base"
expect "the image command builds, tests and pushes" 0 "Pushed 123456789012.dkr.ecr.eu-west-1.amazonaws.com/claude-ecs:latest"

if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "all checks passed"
