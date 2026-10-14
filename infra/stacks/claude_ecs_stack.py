"""Claude Code on ECS Fargate: one task definition per profile, no standing services.

Nothing here runs until someone calls `aws ecs run-task`, so the idle cost is the
ECR storage (plus the NAT gateway when egress="nat").
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from aws_cdk import CfnOutput, Duration, RemovalPolicy, Stack, Tags
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_ecr as ecr
from aws_cdk import aws_ecs as ecs
from aws_cdk import aws_logs as logs
from aws_cdk import aws_secretsmanager as secretsmanager
from aws_cdk import SecretValue
from constructs import Construct

EGRESS_MODES = ("public", "nat")
CPU_ARCHITECTURES = {"X86_64": ecs.CpuArchitecture.X86_64, "ARM64": ecs.CpuArchitecture.ARM64}

# One profile = one file in the repository's profiles/ directory.
PROFILES_DIR = Path(__file__).resolve().parents[2] / "profiles"

# Replaced by `aws secretsmanager put-secret-value`; CloudFormation does not
# touch a secret's value again as long as this template value is unchanged.
SECRET_PLACEHOLDER = "replace-me-with-put-secret-value"


DEFAULT_TAGS: tuple[tuple[str, str], ...] = (("Project", "claude-ecs"),)
MAX_TAGS = 50  # CloudFormation's limit per stack


def parse_tags(value) -> tuple[tuple[str, str], ...]:
    """Tags from CDK context: `-c tags='{"Project":"x"}'` arrives as a JSON string,
    CDK_CONTEXT_JSON as an object."""
    mapping = json.loads(value) if isinstance(value, str) else dict(value)
    return tuple((str(key), str(val)) for key, val in mapping.items())


@dataclass(frozen=True)
class Settings:
    """Deployment settings, read from CDK context (see app.py and infra/README.md)."""

    egress: str = "public"
    image_tag: str = "latest"
    cpu: int = 1024
    memory_mib: int = 4096
    ephemeral_storage_gib: int = 30
    cpu_architecture: str = "X86_64"
    github_token: bool = False
    tags: tuple[tuple[str, str], ...] = DEFAULT_TAGS
    profiles: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.egress not in EGRESS_MODES:
            raise ValueError(f"egress must be one of {EGRESS_MODES}, got {self.egress!r}")
        if self.cpu_architecture not in CPU_ARCHITECTURES:
            raise ValueError(
                f"cpu_architecture must be one of {tuple(CPU_ARCHITECTURES)}, "
                f"got {self.cpu_architecture!r}"
            )
        if not 20 <= self.ephemeral_storage_gib <= 200:
            raise ValueError("ephemeral_storage_gib must be between 20 and 200")
        if len(self.tags) > MAX_TAGS:
            raise ValueError(f"at most {MAX_TAGS} tags")
        for key, val in self.tags:
            if not key or key.lower().startswith("aws:") or not val:
                raise ValueError(f"tag {key!r}={val!r}: key and value must be non-empty, key not aws:*")


def profile_names(profiles_dir: Path = PROFILES_DIR) -> tuple[str, ...]:
    """Names of the profiles shipped in the image (profiles/<name>.plugins)."""
    names = tuple(sorted(p.stem for p in profiles_dir.glob("*.plugins")))
    if not names:
        raise ValueError(f"no profiles found in {profiles_dir}")
    return names


class ClaudeEcsStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, settings: Settings, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)
        for key, val in settings.tags:
            Tags.of(self).add(key, val)

        repository = ecr.Repository(
            self,
            "Repository",
            repository_name="claude-ecs",
            image_scan_on_push=True,
            removal_policy=RemovalPolicy.RETAIN,
            lifecycle_rules=[ecr.LifecycleRule(description="Keep the newest 10 images", max_image_count=10)],
        )

        vpc = self._network(settings)

        # No inbound rule at all; outbound is HTTPS only (Anthropic API, GitHub,
        # package indexes, ECR, S3). DNS to the VPC resolver is not filtered by
        # security groups, so it needs no rule.
        security_group = ec2.SecurityGroup(
            self,
            "TaskSecurityGroup",
            vpc=vpc,
            description="Claude Code tasks: no inbound, HTTPS outbound",
            allow_all_outbound=False,
        )
        security_group.add_egress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(443), "HTTPS")

        cluster = ecs.Cluster(
            self,
            "Cluster",
            vpc=vpc,
            cluster_name="claude-ecs",
            enable_fargate_capacity_providers=True,
        )

        log_group = logs.LogGroup(
            self,
            "Logs",
            log_group_name="/claude-ecs",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=RemovalPolicy.DESTROY,
        )

        secrets = self._secrets(settings)
        linux_parameters = ecs.LinuxParameters(self, "LinuxParameters", init_process_enabled=True)

        families = []
        for profile in settings.profiles:
            task_definition = ecs.FargateTaskDefinition(
                self,
                f"Task-{profile}",
                family=f"claude-ecs-{profile}",
                cpu=settings.cpu,
                memory_limit_mib=settings.memory_mib,
                ephemeral_storage_gib=settings.ephemeral_storage_gib,
                runtime_platform=ecs.RuntimePlatform(
                    cpu_architecture=CPU_ARCHITECTURES[settings.cpu_architecture],
                    operating_system_family=ecs.OperatingSystemFamily.LINUX,
                ),
            )
            task_definition.add_container(
                "claude",
                image=ecs.ContainerImage.from_ecr_repository(repository, settings.image_tag),
                environment={"CLAUDE_PROFILE": profile},
                secrets=secrets,
                logging=ecs.LogDrivers.aws_logs(stream_prefix=profile, log_group=log_group),
                linux_parameters=linux_parameters,
                stop_timeout=Duration.seconds(30),
            )
            families.append(task_definition.family)

        subnets = vpc.public_subnets if settings.egress == "public" else vpc.private_subnets
        CfnOutput(self, "RepositoryUri", value=repository.repository_uri)
        CfnOutput(self, "ClusterName", value=cluster.cluster_name)
        CfnOutput(self, "SubnetIds", value=",".join(s.subnet_id for s in subnets))
        CfnOutput(self, "SecurityGroupId", value=security_group.security_group_id)
        CfnOutput(self, "AssignPublicIp", value="ENABLED" if settings.egress == "public" else "DISABLED")
        CfnOutput(self, "TaskDefinitionFamilies", value=",".join(families))

    def _network(self, settings: Settings) -> ec2.Vpc:
        """Public subnets only (no NAT), or private subnets behind one NAT gateway."""
        if settings.egress == "public":
            return ec2.Vpc(
                self,
                "Vpc",
                max_azs=2,
                nat_gateways=0,
                subnet_configuration=[
                    ec2.SubnetConfiguration(
                        name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24
                    )
                ],
            )
        vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=2,
            nat_gateways=1,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=28
                ),
                ec2.SubnetConfiguration(
                    name="private", subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS, cidr_mask=24
                ),
            ],
        )
        # ECR serves image layers from S3; this keeps that traffic off the NAT
        # gateway's per-GB charge.
        vpc.add_gateway_endpoint("S3", service=ec2.GatewayVpcEndpointAwsService.S3)
        return vpc

    def _secrets(self, settings: Settings) -> dict[str, ecs.Secret]:
        """Secrets the stack owns but whose values are set out of band."""
        anthropic = secretsmanager.Secret(
            self,
            "AnthropicApiKey",
            secret_name="claude-ecs/anthropic-api-key",
            description="ANTHROPIC_API_KEY for Claude Code tasks",
            secret_string_value=SecretValue.unsafe_plain_text(SECRET_PLACEHOLDER),
            removal_policy=RemovalPolicy.RETAIN,
        )
        secrets = {"ANTHROPIC_API_KEY": ecs.Secret.from_secrets_manager(anthropic)}
        if settings.github_token:
            github = secretsmanager.Secret(
                self,
                "GithubToken",
                secret_name="claude-ecs/github-token",
                description="GitHub token for the github plugin and the gh CLI",
                secret_string_value=SecretValue.unsafe_plain_text(SECRET_PLACEHOLDER),
                removal_policy=RemovalPolicy.RETAIN,
            )
            github_secret = ecs.Secret.from_secrets_manager(github)
            secrets["GITHUB_PERSONAL_ACCESS_TOKEN"] = github_secret
            secrets["GITHUB_TOKEN"] = github_secret
        return secrets
