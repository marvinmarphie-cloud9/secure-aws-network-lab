from pathlib import Path

import yaml


TEMPLATE_PATH = Path(__file__).parents[1] / "infrastructure" / "network.yaml"


class CloudFormationLoader(yaml.SafeLoader):
    """Parse CloudFormation tags while preserving their underlying values."""


def cloudformation_tag(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return {node.tag[1:]: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {node.tag[1:]: loader.construct_sequence(node)}
    return {node.tag[1:]: loader.construct_mapping(node)}


for tag in ("!Ref", "!Sub", "!GetAtt", "!Select", "!GetAZs", "!Cidr"):
    CloudFormationLoader.add_constructor(tag, cloudformation_tag)


def template():
    with TEMPLATE_PATH.open(encoding="utf-8") as stream:
        return yaml.load(stream, Loader=CloudFormationLoader)


def test_template_has_expected_network_shape():
    document = template()
    resources = document["Resources"]
    types = {name: resource["Type"] for name, resource in resources.items()}

    assert types["NetworkVpc"] == "AWS::EC2::VPC"
    assert len([name for name in types if "Subnet" in name and types[name] == "AWS::EC2::Subnet"]) == 6
    assert "AWS::EC2::NatGateway" not in types.values()
    assert "AWS::EC2::Instance" not in types.values()
    assert "AWS::EC2::EIP" not in types.values()
    assert not any(resource_type.startswith("AWS::KMS::") for resource_type in types.values())


def test_routes_and_endpoint_are_private_by_design():
    document = template()
    resources = document["Resources"]

    assert resources["PublicInternetRoute"]["Properties"]["GatewayId"] == {"Ref": "InternetGateway"}
    assert "ApplicationRoute" not in resources
    assert "DatabaseRoute" not in resources
    assert resources["S3GatewayEndpoint"]["Properties"]["RouteTableIds"] == [{"Ref": "ApplicationRouteTable"}]


def test_security_groups_form_the_intended_chain():
    resources = template()["Resources"]
    load_balancer_ingress = resources["LoadBalancerSecurityGroup"]["Properties"]["SecurityGroupIngress"][0]
    application_ingress = resources["ApplicationSecurityGroup"]["Properties"]["SecurityGroupIngress"][0]
    database_ingress = resources["DatabaseSecurityGroup"]["Properties"]["SecurityGroupIngress"][0]

    assert load_balancer_ingress["FromPort"] == 443
    assert load_balancer_ingress["CidrIp"] == "0.0.0.0/0"
    assert application_ingress["SourceSecurityGroupId"] == {"Ref": "LoadBalancerSecurityGroup"}
    assert database_ingress["FromPort"] == 5432
    assert database_ingress["ToPort"] == 5432
    assert database_ingress["SourceSecurityGroupId"] == {"Ref": "ApplicationSecurityGroup"}


def test_flow_logs_use_default_encryption_and_are_retained_for_seven_days():
    resources = template()["Resources"]

    log_group = resources["FlowLogsLogGroup"]["Properties"]
    assert log_group["RetentionInDays"] == 7
    assert "KmsKeyId" not in log_group
    role_policy = resources["FlowLogsRole"]["Properties"]["Policies"][0]["PolicyDocument"]
    statement = role_policy["Statement"][0]
    assert statement["Action"] == ["logs:CreateLogStream", "logs:PutLogEvents"]
    assert statement["Resource"][1] == {"Sub": "${FlowLogsLogGroup.Arn}:*"}


def test_cloudwatch_flow_logs_omit_destination_options():
    flow_log = template()["Resources"]["VpcFlowLog"]
    properties = flow_log["Properties"]

    assert properties["LogDestinationType"] == "cloud-watch-logs"
    assert "DestinationOptions" not in properties
    assert properties["LogFormat"]
