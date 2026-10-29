#!/bin/bash
# ============================================================
# ecs-in-docker.sh - deploy and exercise the claude-ecs stack from containers.
#
#   scripts/deploy/ecs-in-docker.sh [--config FILE] [--use-env-key] COMMAND [args]
#
# For a machine that has Docker but no AWS CLI, CDK or Node. Everything that talks
# to AWS runs in the `ecs-deploy` image built from this repository; only image
# building, the smoke test and `docker push` run on the host.
#
# Commands
#   deploy      build, smoke-test, preflight, stack, secret, image, verify: all of it
#   runs        the first runs (first-runs.sh): 5 by default, --all for all 15; extra args go to it
#   preflight   read-only checks of the account              (ecs-deploy.sh preflight)
#   stack       preflight, cdk diff, confirm, cdk deploy      (ecs-deploy.sh stack)
#   secret      store the Anthropic API key in Secrets Manager
#   image       build, smoke-test and push the image
#   verify      compare the account with the preflight baseline
#   identity    show who the AWS credentials belong to
#   shell       a shell in the tools container
#   exec CMD..  run CMD in the tools container, without a TTY (aws, jq and the repository at /work),
#               e.g.  exec aws ecr describe-images --repository-name claude-ecs
#
# Options
#   --config FILE   settings file inside this repository (default scripts/private/fibtec.env)
#   --env-file FILE read the keys from FILE (KEY=value lines) when they are not exported
#   --use-env-key   secret/deploy: store $ANTHROPIC_API_KEY instead of asking for a key.
#                   Give that key its own spend limit in the Anthropic console.
#   --yes, -y       ask nothing: no typed account id, no CDK y/n on IAM changes. The account is
#                   still pinned by EXPECTED_ACCOUNT in the settings file (a NO-GO otherwise), and
#                   the create-only diff gate still applies. ASSUME_YES=1 in the settings file does
#                   the same for good.
#   --strict        stop on UNKNOWN preflight checks too. By default they are listed and the
#                   deploy goes on (a check that cannot be read is not a finding); a NO-GO
#                   always stops it.
#
# Needs on the host: Docker (running), and AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (plus AWS_SESSION_TOKEN for temporary credentials), either exported in this shell or
# present in an env file (--env-file FILE, else .env in this repository). Only those
# three names and ANTHROPIC_API_KEY are read from the file, never executed or printed;
# a variable already exported wins.
# deploy asks twice unless --yes: the account id (ecs-deploy.sh) and y/n on IAM changes (CDK).
# It can be run again: a deployed stack and a stored key are skipped.
# Bash 3.2 compatible (macOS).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_NAME="claude-ecs"
SECRET_ID="claude-ecs/anthropic-api-key"
SECRET_PLACEHOLDER="replace-me-with-put-secret-value"
BASE_IMAGE="claude-ecs-base:local"
TOOLS_IMAGE="claude-ecs-deploy:local"
SMOKE_TEST="${SMOKE_TEST:-$REPO_DIR/scripts/ci/smoke-ecs.sh}"   # overridden by the tests

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "ecs-in-docker: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

CONFIG="" ENV_FILE="" USE_ENV_KEY=0 ALLOW_UNKNOWN=1 ASSUME_YES=""

resolve_config() {
    if [ -z "$CONFIG" ] && [ -f "$REPO_DIR/scripts/private/fibtec.env" ]; then
        CONFIG="$REPO_DIR/scripts/private/fibtec.env"
    fi
    [ -n "$CONFIG" ] || die "no settings file: pass --config FILE (settings are listed in ecs-deploy.sh --help)"
    [ -f "$CONFIG" ] || die "no config file $CONFIG"
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
    case "$CONFIG" in
        "$REPO_DIR"/*) CONFIG_IN="/work/${CONFIG#"$REPO_DIR"/}" ;;
        *) die "the config file must be inside $REPO_DIR: the repository is what the container sees" ;;
    esac
    # The file is a shell file; read the two values the host needs from a subshell.
    # shellcheck disable=SC1090
    eval "$(. "$CONFIG"; printf 'REGION=%q\nARCH=%q\n' "${AWS_REGION:-}" "${CPU_ARCH:-ARM64}")"
    [ -n "$REGION" ] || die "AWS_REGION is not set in $CONFIG"
    case "$ARCH" in
        ARM64) PLATFORM=linux/arm64 ;;
        X86_64) PLATFORM=linux/amd64 ;;
        *) die "CPU_ARCH in $CONFIG must be ARM64 or X86_64, got '$ARCH'" ;;
    esac
}

need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker info >/dev/null 2>&1 || die "Docker is not running (start Docker Desktop and try again)"
}

# env_file_value FILE NAME: the value of the last NAME=value (or export NAME=value) line,
# without surrounding quotes. The file is parsed, not sourced.
env_file_value() {
    local line v=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            "$2="* | "export $2="*) v="${line#*=}" ;;
        esac
    done < "$1"
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "$v"
}

load_env_file() {
    local f="$ENV_FILE" name v loaded=""
    if [ -z "$f" ] && [ -f "$REPO_DIR/.env" ]; then f="$REPO_DIR/.env"; fi
    [ -n "$f" ] || return 0
    [ -f "$f" ] || die "no env file $f"
    for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ANTHROPIC_API_KEY; do
        [ -z "${!name:-}" ] || continue
        v="$(env_file_value "$f" "$name")"
        if [ -n "$v" ]; then export "$name=$v"; loaded="$loaded $name"; fi
    done
    [ -z "$loaded" ] || echo "Read from $f:$loaded"
}

need_credentials() {
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        die "no AWS credentials: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are neither exported in this shell nor in an env file (pass --env-file FILE, or put them in $REPO_DIR/.env)"
    fi
}

warn_on_arch_mismatch() {
    local host
    case "$(uname -m)" in
        arm64 | aarch64) host=linux/arm64 ;;
        x86_64 | amd64) host=linux/amd64 ;;
        *) host="" ;;
    esac
    if [ -n "$host" ] && [ "$host" != "$PLATFORM" ]; then
        echo "WARNING: this machine is $host but the stack runs $ARCH: the images are built under emulation (slow, but they work)."
    fi
}

# tools_run MODE CMD...   run CMD in the tools container with the repository mounted at /work.
#   batch  no stdin     pipe  stdin is forwarded     tty  interactive when a terminal is attached
tools_run() {
    local mode="$1"; shift
    local flags=() user=()
    case "$mode" in
        batch) ;;
        pipe) flags=(-i) ;;
        tty) if [ -t 0 ] && [ -t 1 ]; then flags=(-it); else flags=(-i); fi ;;
    esac
    # On Linux the bind mount keeps host ownership; run as the caller so files can be written.
    if [ "$(uname -s)" = "Linux" ]; then user=(--user "$(id -u):$(id -g)" -e HOME=/tmp); fi
    docker run --rm ${flags[@]+"${flags[@]}"} ${user[@]+"${user[@]}"} \
        -v "$REPO_DIR:/work" -w /work \
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
        -e "AWS_REGION=$REGION" -e "AWS_DEFAULT_REGION=$REGION" \
        -e ECS_DEPLOY_VENV=/opt/venv -e npm_config_yes=true -e "ALLOW_UNKNOWN=$ALLOW_UNKNOWN" -e "ASSUME_YES=$ASSUME_YES" \
        --entrypoint "" "$TOOLS_IMAGE" "$@"
}

deploy_script() { # deploy_script MODE COMMAND: one ecs-deploy.sh command in the container
    local mode="$1" cmd="$2"
    tools_run "$mode" scripts/deploy/ecs-deploy.sh --config "$CONFIG_IN" "$cmd"
}

build_images() {
    step "Build the images for $ARCH (the second build reuses the first one's layers)"
    GIT_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
    DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --target ecs-base -t "$BASE_IMAGE" "$REPO_DIR"
    DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --target ecs-deploy -t "$TOOLS_IMAGE" "$REPO_DIR"
}

ensure_tools_image() {
    if ! docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
        step "Build the tools image (first use)"
        DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --target ecs-deploy -t "$TOOLS_IMAGE" "$REPO_DIR"
    fi
}

smoke_test() {
    step "Smoke-test the image that will be pushed"
    "$SMOKE_TEST" "$BASE_IMAGE" base
}

stack_status() { # CREATE_COMPLETE, ..., or ABSENT
    tools_run batch aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo ABSENT
}

secret_is_set() {
    local v
    v="$(tools_run batch aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
        --query SecretString --output text 2>/dev/null)" || return 1
    [ -n "$v" ] && [ "$v" != "None" ] && [ "$v" != "$SECRET_PLACEHOLDER" ]
}

store_secret() {
    if [ "$USE_ENV_KEY" -eq 1 ]; then
        [ -n "${ANTHROPIC_API_KEY:-}" ] || die "--use-env-key: ANTHROPIC_API_KEY is not exported in this shell"
        echo "Storing ANTHROPIC_API_KEY from this shell (--use-env-key); give it its own spend limit in the Anthropic console."
        printf '%s\n' "$ANTHROPIC_API_KEY" | tools_run pipe scripts/deploy/ecs-deploy.sh --config "$CONFIG_IN" secret
    else
        deploy_script tty secret
    fi
}

push_image() {
    local uri host cfg denv token auth
    step "Push the image"
    uri="$(tools_run batch aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue | [0]" --output text)" \
        || die "cannot read the $STACK_NAME stack outputs"
    case "$uri" in "" | None) die "the $STACK_NAME stack has no RepositoryUri output (deploy it first)" ;; esac
    GIT_SHA="${GIT_SHA:-$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo local)}"
    # Push with a throwaway Docker config that already holds the login, and no `docker login`.
    # The ECR token lasts 12 hours. `docker login` saves it with the platform's credential helper,
    # and a config with no login in it makes the CLI pick the macOS keychain helper by default,
    # which fails in a session without a screen ("User interaction is not allowed"). With a login
    # already in the file the CLI reads and writes that file and never asks the keychain.
    # A fresh config has no contexts, so the current daemon is passed explicitly.
    cfg="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$cfg'" EXIT
    token="$(tools_run batch aws ecr get-login-password)" || die "cannot get an ECR login token"
    auth="$(printf 'AWS:%s' "$token" | base64 | tr -d '\n')"
    token=""
    (umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${uri%%/*}" "$auth" > "$cfg/config.json")
    auth=""
    host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || host=""
    denv=(DOCKER_CONFIG="$cfg")
    if [ -n "$host" ]; then denv+=(DOCKER_HOST="$host"); fi
    docker tag "$BASE_IMAGE" "$uri:latest"
    docker tag "$BASE_IMAGE" "$uri:$GIT_SHA"
    env "${denv[@]}" docker push "$uri:latest"
    env "${denv[@]}" docker push "$uri:$GIT_SHA"
    rm -rf "$cfg"
    trap - EXIT
    echo "Pushed $uri:latest and :$GIT_SHA"
}

cmd_deploy() {
    local status
    build_images
    smoke_test
    step "Who the credentials belong to"
    tools_run batch aws sts get-caller-identity --output json || die "the AWS credentials do not work"
    status="$(stack_status)"
    case "$status" in
        ABSENT)
            step "Stack: preflight, diff, confirm, deploy"
            deploy_script tty stack || die "the stack step stopped (see above); nothing was pushed"
            ;;
        CREATE_COMPLETE | UPDATE_COMPLETE)
            step "Stack"; echo "$STACK_NAME is already deployed ($status): skipped" ;;
        *)
            die "the $STACK_NAME stack is in state $status; look at it in CloudFormation before running again" ;;
    esac
    step "Anthropic API key"
    if secret_is_set; then
        echo "$SECRET_ID already holds a key: skipped (run the secret command to replace it)"
    else
        store_secret || die "the key was not stored"
    fi
    push_image
    step "Verify against the baseline"
    deploy_script batch verify || die "verify reported a difference (see above)"
    printf '\nDeployed. Next:  scripts/deploy/ecs-in-docker.sh runs\n'
}

main() {
    local cmd="" extra=()
    # --config and --use-env-key are ours wherever they stand; the rest after the
    # command belongs to the command (e.g. runs --groups G1).
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
            --env-file) ENV_FILE="${2:?--env-file needs a file}"; shift 2 ;;
            --use-env-key) USE_ENV_KEY=1; shift ;;
            --yes | -y) ASSUME_YES=1; shift ;;
            --strict) ALLOW_UNKNOWN=0; shift ;;
            -h | --help) usage; return 0 ;;
            *) if [ -z "$cmd" ]; then cmd="$1"; else extra+=("$1"); fi; shift ;;
        esac
    done
    case "$cmd" in
        deploy | runs | preflight | stack | secret | image | verify | identity | shell | exec) ;;
        *) usage >&2; return 2 ;;
    esac
    resolve_config
    need_docker
    load_env_file
    need_credentials
    warn_on_arch_mismatch
    case "$cmd" in
        deploy) cmd_deploy ;;
        runs) ensure_tools_image; tools_run batch scripts/run/first-runs.sh --config "$CONFIG_IN" ${extra[@]+"${extra[@]}"} ;;
        preflight) ensure_tools_image; deploy_script batch preflight ;;
        stack) ensure_tools_image; deploy_script tty stack ;;
        secret) ensure_tools_image; store_secret ;;
        verify) ensure_tools_image; deploy_script batch verify ;;
        identity) ensure_tools_image; tools_run batch aws sts get-caller-identity --output json ;;
        shell) ensure_tools_image; tools_run tty bash ;;
        exec) [ ${#extra[@]} -gt 0 ] || die "exec needs a command, e.g.  exec aws sts get-caller-identity"
              ensure_tools_image; tools_run batch "${extra[@]}" ;;
        image) build_images; smoke_test; push_image ;;
    esac
}

main "$@"
