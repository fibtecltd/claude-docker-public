"""Assertions on the synthesized template: what the network allows, what each task gets."""

from dataclasses import replace

import aws_cdk as cdk
import pytest
from aws_cdk.assertions import Match, Template

from stacks.claude_ecs_stack import ClaudeEcsStack, Settings, parse_tags, profile_names

PROFILES = profile_names()


def synth(**overrides) -> Template:
    settings = replace(Settings(profiles=PROFILES), **overrides)
    app = cdk.App()
    stack = ClaudeEcsStack(app, "test", settings=settings)
    return Template.from_stack(stack)


@pytest.fixture(scope="module")
def public() -> Template:
    return synth()


@pytest.fixture(scope="module")
def nat() -> Template:
    return synth(egress="nat")


def container(template: Template, profile: str) -> dict:
    tasks = template.find_resources(
        "AWS::ECS::TaskDefinition", {"Properties": {"Family": f"claude-ecs-{profile}"}}
    )
    assert len(tasks) == 1
    (task,) = tasks.values()
    (definition,) = task["Properties"]["ContainerDefinitions"]
    return definition


def test_profiles_are_the_files_in_the_profiles_directory():
    assert {"core", "pyvar"} <= set(PROFILES)


def test_one_task_definition_per_profile_selecting_it(public):
    public.resource_count_is("AWS::ECS::TaskDefinition", len(PROFILES))
    for profile in PROFILES:
        env = container(public, profile)["Environment"]
        assert env == [{"Name": "CLAUDE_PROFILE", "Value": profile}]


def test_tasks_are_fargate_with_the_configured_size(public):
    public.has_resource_properties(
        "AWS::ECS::TaskDefinition",
        {
            "RequiresCompatibilities": ["FARGATE"],
            "NetworkMode": "awsvpc",
            "Cpu": "1024",
            "Memory": "4096",
            "EphemeralStorage": {"SizeInGiB": 30},
            "RuntimePlatform": {"CpuArchitecture": "X86_64", "OperatingSystemFamily": "LINUX"},
        },
    )


def test_arm64_can_be_selected():
    synth(cpu_architecture="ARM64").has_resource_properties(
        "AWS::ECS::TaskDefinition", {"RuntimePlatform": {"CpuArchitecture": "ARM64"}}
    )


def test_security_group_has_no_inbound_and_only_https_outbound(public):
    public.resource_count_is("AWS::EC2::SecurityGroup", 1)
    (group,) = public.find_resources("AWS::EC2::SecurityGroup").values()
    properties = group["Properties"]
    assert "SecurityGroupIngress" not in properties
    assert [(r["IpProtocol"], r["FromPort"], r["ToPort"]) for r in properties["SecurityGroupEgress"]] == [
        ("tcp", 443, 443)
    ]
    public.resource_count_is("AWS::EC2::SecurityGroupIngress", 0)


def test_public_egress_has_no_nat_and_only_public_subnets(public):
    public.resource_count_is("AWS::EC2::NatGateway", 0)
    public.resource_count_is("AWS::EC2::VPCEndpoint", 0)
    public.resource_count_is("AWS::EC2::Subnet", 2)
    public.has_resource_properties("AWS::EC2::Subnet", {"MapPublicIpOnLaunch": True})
    public.has_output("AssignPublicIp", {"Value": "ENABLED"})


def test_nat_egress_uses_private_subnets_behind_one_nat_gateway(nat):
    nat.resource_count_is("AWS::EC2::NatGateway", 1)
    nat.resource_count_is("AWS::EC2::Subnet", 4)
    nat.has_resource_properties(
        "AWS::EC2::VPCEndpoint", {"VpcEndpointType": "Gateway"}
    )
    nat.has_output("AssignPublicIp", {"Value": "DISABLED"})
    private = nat.find_resources(
        "AWS::EC2::Subnet", {"Properties": {"MapPublicIpOnLaunch": False}}
    )
    assert len(private) == 2


def test_nat_mode_keeps_the_same_task_definitions(public, nat):
    assert container(public, "core")["Secrets"] == container(nat, "core")["Secrets"]
    nat.resource_count_is("AWS::ECS::TaskDefinition", len(PROFILES))


def test_anthropic_key_comes_from_a_secret_and_github_token_is_off_by_default(public):
    for profile in PROFILES:
        secrets = container(public, profile)["Secrets"]
        assert [s["Name"] for s in secrets] == ["ANTHROPIC_API_KEY"]
    public.resource_count_is("AWS::SecretsManager::Secret", 1)
    public.has_resource_properties(
        "AWS::SecretsManager::Secret", {"Name": "claude-ecs/anthropic-api-key"}
    )


def test_github_token_secret_feeds_both_variables_when_enabled():
    template = synth(github_token=True)
    template.resource_count_is("AWS::SecretsManager::Secret", 2)
    secrets = {s["Name"]: s["ValueFrom"] for s in container(template, "core")["Secrets"]}
    assert set(secrets) == {"ANTHROPIC_API_KEY", "GITHUB_PERSONAL_ACCESS_TOKEN", "GITHUB_TOKEN"}
    assert secrets["GITHUB_PERSONAL_ACCESS_TOKEN"] == secrets["GITHUB_TOKEN"]


def test_secrets_are_retained_and_hold_only_a_placeholder(public):
    (secret,) = public.find_resources("AWS::SecretsManager::Secret").values()
    assert secret["DeletionPolicy"] == "Retain"
    assert secret["Properties"]["SecretString"].startswith("replace-me")


def test_task_roles_have_no_permissions(public):
    """The task role is what the code in the container can do; it starts empty."""
    roles = public.find_resources("AWS::IAM::Role")
    task_roles = {
        name
        for name, role in roles.items()
        if "TaskRole" in name or "ExecutionRole" not in name
    }
    assert len(task_roles) == len(PROFILES)
    for name in task_roles:
        assert "ManagedPolicyArns" not in roles[name]["Properties"]
    for policy in public.find_resources("AWS::IAM::Policy").values():
        for ref in policy["Properties"]["Roles"]:
            assert "ExecutionRole" in ref["Ref"], "only execution roles carry policies"


def test_execution_role_reads_only_the_stack_secrets():
    template = synth(github_token=True)
    for policy in template.find_resources("AWS::IAM::Policy").values():
        for statement in policy["Properties"]["PolicyDocument"]["Statement"]:
            if "secretsmanager:GetSecretValue" in statement["Action"]:
                assert statement["Resource"] != "*"


def test_repository_scans_on_push_expires_old_images_and_is_retained(public):
    public.has_resource_properties(
        "AWS::ECR::Repository",
        {
            "RepositoryName": "claude-ecs",
            "ImageScanningConfiguration": {"ScanOnPush": True},
            "LifecyclePolicy": Match.object_like({"LifecyclePolicyText": Match.string_like_regexp("countNumber")}),
        },
    )
    (repository,) = public.find_resources("AWS::ECR::Repository").values()
    assert repository["DeletionPolicy"] == "Retain"


def test_logs_expire_and_cluster_offers_fargate_spot(public):
    public.has_resource_properties(
        "AWS::Logs::LogGroup", {"LogGroupName": "/claude-ecs", "RetentionInDays": 30}
    )
    public.has_resource_properties(
        "AWS::ECS::ClusterCapacityProviderAssociations",
        {"CapacityProviders": ["FARGATE", "FARGATE_SPOT"]},
    )


def test_image_tag_is_configurable():
    image = container(synth(image_tag="abc1234"), "core")["Image"]
    assert image["Fn::Join"][1][-1] == ":abc1234"


def test_default_tag_is_the_project_name(public):
    public.has_resource_properties(
        "AWS::ECR::Repository", {"Tags": [{"Key": "Project", "Value": "claude-ecs"}]}
    )


def test_tags_are_configurable_and_reach_the_resources():
    tags = (("Project", "common"), ("Owner", "example-org"), ("ManagedBy", "cdk"))
    template = synth(tags=tags)
    expected = [{"Key": k, "Value": v} for k, v in sorted(tags)]  # CloudFormation sorts by key
    template.has_resource_properties("AWS::ECR::Repository", {"Tags": Match.array_with(expected)})
    template.has_resource_properties("AWS::ECS::Cluster", {"Tags": Match.array_with(expected)})


def test_tags_parse_from_a_json_string_or_an_object():
    assert parse_tags('{"Project": "common", "Owner": "o"}') == (("Project", "common"), ("Owner", "o"))
    assert parse_tags({"Project": "common"}) == (("Project", "common"),)


@pytest.mark.parametrize(
    "overrides",
    [
        {"egress": "tailscale"},
        {"tags": (("", "x"),)},
        {"tags": (("aws:reserved", "x"),)},
        {"tags": (("Project", ""),)},
        {"tags": tuple((f"k{i}", "v") for i in range(51))},
        {"cpu_architecture": "ppc64"},
        {"ephemeral_storage_gib": 10},
        {"ephemeral_storage_gib": 500},
    ],
)
def test_invalid_settings_are_rejected(overrides):
    with pytest.raises(ValueError):
        Settings(**overrides)
