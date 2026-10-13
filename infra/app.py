#!/usr/bin/env python3
"""CDK app: Claude Code task definitions for ECS Fargate (see infra/README.md)."""

import os

import aws_cdk as cdk

from stacks.claude_ecs_stack import ClaudeEcsStack, Settings, profile_names

app = cdk.App()


def context(key: str, default):
    value = app.node.try_get_context(key)
    return default if value is None else value


def flag(value) -> bool:
    """`-c key=true` arrives as a string, CDK_CONTEXT_JSON as a boolean."""
    return str(value).lower() in ("1", "true", "yes")


defaults = Settings()
settings = Settings(
    egress=str(context("egress", defaults.egress)),
    image_tag=str(context("image_tag", defaults.image_tag)),
    cpu=int(context("cpu", defaults.cpu)),
    memory_mib=int(context("memory_mib", defaults.memory_mib)),
    ephemeral_storage_gib=int(context("ephemeral_storage_gib", defaults.ephemeral_storage_gib)),
    cpu_architecture=str(context("cpu_architecture", defaults.cpu_architecture)),
    github_token=flag(context("github_token", defaults.github_token)),
    profiles=profile_names(),
)

ClaudeEcsStack(
    app,
    "claude-ecs",
    settings=settings,
    env=cdk.Environment(
        account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
        region=os.environ.get("CDK_DEFAULT_REGION"),
    ),
)

app.synth()
