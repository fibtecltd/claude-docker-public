#!/usr/bin/env bash
# Smoke tests for a built ecs-base or ecs-deploy image. No API key is needed:
# the checks only exercise what is baked into the image.
#
# Used by .github/workflows/build-ecs.yml; also runnable locally:
#   docker compose build claude-ecs-base
#   scripts/ci/smoke-ecs.sh claude-ecs-base:latest base
#
# Usage: smoke-ecs.sh IMAGE [base|deploy]   (default mode: base)
#   base    ecs-base checks
#   deploy  ecs-base checks plus CDK, Stripe CLI and the SSM plugin
set -euo pipefail

IMG="${1:?usage: smoke-ecs.sh IMAGE [base|deploy]}"
MODE="${2:-base}"
LOCK="$(dirname "$0")/../../plugins.lock"
case "$MODE" in
    base | deploy) ;;
    *) echo "mode must be 'base' or 'deploy', got: $MODE" >&2; exit 2 ;;
esac

TOOLS="claude node npm git gh jq uv pip ruff pytest aws"
if [[ "$MODE" == deploy ]]; then
    TOOLS="$TOOLS cdk stripe session-manager-plugin"
fi

echo "--- [$MODE] entrypoint passes container args to claude"
docker run --rm "$IMG" --version

echo "--- [$MODE] an unknown CLAUDE_PROFILE is refused (exit 2)"
rc=0
docker run --rm -e CLAUDE_PROFILE=no-such-profile "$IMG" --version || rc=$?
test "$rc" = 2 || { echo "expected exit 2, got $rc"; exit 1; }

echo "--- [$MODE] a malformed CLAUDE_REPO is refused before any clone (exit 2)"
rc=0
docker run --rm -e CLAUDE_REPO="not a repo" "$IMG" --version || rc=$?
test "$rc" = 2 || { echo "expected exit 2, got $rc"; exit 1; }

echo "--- [$MODE] user, Python version, toolchain"
# The script below runs inside the container, so $-expressions must stay literal.
# shellcheck disable=SC2016
docker run --rm -e TOOLS="$TOOLS" --entrypoint bash "$IMG" -c '
  set -euo pipefail
  test "$(id -u)" = 1001 || { echo "expected uid 1001, got $(id -u)"; exit 1; }
  python --version | grep -q "^Python 3\.12\." || { echo "expected Python 3.12"; python --version; exit 1; }
  for t in $TOOLS; do
    command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
  done
  python -c "import boto3; print(\"boto3\", boto3.__version__)"
'

echo "--- [$MODE] user-level config carries settings only"
# shellcheck disable=SC2016
docker run --rm --entrypoint bash "$IMG" -c '
  set -euo pipefail
  test -s "$HOME/.claude/settings.json"
  for d in agents commands skills hooks plugins; do
    test ! -e "$HOME/.claude/$d" || { echo "unexpected ~/.claude/$d"; exit 1; }
  done
'

echo "--- [$MODE] the subprocess scrub is off by default and can be switched on (bubblewrap and socat are installed)"
# shellcheck disable=SC2016
docker run --rm --entrypoint bash "$IMG" -c '
  test "${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-0}" = 0 || { echo "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is on by default in the image"; exit 1; }
  command -v bwrap >/dev/null || { echo "bubblewrap is missing: Claude Code will not start with the scrub switched on"; exit 1; }
  command -v socat >/dev/null || { echo "socat is missing: Claude Code refuses every command with the scrub switched on"; exit 1; }
'

echo "--- [$MODE] plugins match plugins.lock, validate, and are read-only for claude"
expected=$(grep -Evc '^[[:space:]]*(#|$)' "$LOCK")
# shellcheck disable=SC2016
docker run --rm -e EXPECTED="$expected" --entrypoint bash "$IMG" -c '
  set -euo pipefail
  installed=$(find /opt/claude/plugins -mindepth 3 -maxdepth 3 -path "*/.claude-plugin/plugin.json" | wc -l)
  echo "plugins installed: $installed (lock lists $EXPECTED)"
  test "$installed" = "$EXPECTED" || { echo "installed plugins differ from plugins.lock"; exit 1; }
  for d in /opt/claude/plugins/*/; do
    claude plugin validate "$d" >/dev/null || { echo "plugin failed validation: $d"; claude plugin validate "$d"; exit 1; }
  done
  test ! -w /opt/claude/plugins || { echo "/opt/claude/plugins is writable by claude"; exit 1; }
  find /opt/claude/plugins -name .git | grep -q . && { echo "git metadata left in a plugin"; exit 1; }
  test -d /opt/claude/profiles
  for f in /opt/claude/profiles/*.plugins; do
    echo "profile $(basename "$f" .plugins):"
    n=0
    while read -r plugin; do
      case "$plugin" in "" | \#*) continue ;; esac
      test -d "/opt/claude/plugins/$plugin" || { echo "  $plugin is listed but not installed"; exit 1; }
      n=$((n + 1))
    done < "$f"
    echo "  $n plugins, all installed"
    test "$n" -gt 0
  done
'

if [[ "$MODE" == deploy ]]; then
    echo "--- [deploy] CDK CLI, CDK Python library (runs on Node via jsii), Stripe CLI"
    # shellcheck disable=SC2016
    docker run --rm --entrypoint bash "$IMG" -c '
      set -euo pipefail
      cdk --version
      python -c "import aws_cdk, constructs; aws_cdk.App(); print(\"aws-cdk-lib ok\")"
      stripe --version
    '
fi

echo "--- [$MODE] no git credentials left in the image"
# shellcheck disable=SC2016
docker run --rm --entrypoint bash "$IMG" -c '
  if [ -e "$HOME/.gitconfig" ]; then echo "~/.gitconfig present"; cat "$HOME/.gitconfig"; exit 1; fi
'
if docker history --no-trunc "$IMG" | grep -Eqi "ghp_|github_pat_|gho_|ghs_|sk-ant-"; then
    echo "credential-like string found in image history" >&2
    exit 1
fi

echo "--- [$MODE] all smoke checks passed"
