from typing import Sequence
import os

from aws_cdk import (
    Stack,
    aws_iam as iam,
    aws_s3_assets as s3_assets,
    aws_ec2 as ec2,
    BundlingOptions,
    DockerImage,
    CfnResource,
    CfnOutput,
)
from constructs import Construct


class LogisticsAgentRuntimeStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        vpc_id: str,
        private_subnet_ids: Sequence[str],
        runtime_security_group_id: str,
        db_secret_arn: str,
        openai_secret_arn: str,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Import existing VPC 
        vpc = ec2.Vpc.from_vpc_attributes(
            self,
            "ExistingVpc",
            vpc_id=vpc_id,
            availability_zones=["us-east-1a", "us-east-1b"],  
            private_subnet_ids=list(private_subnet_ids),
        )

        # Import the existing runtime security group 
        runtime_sg = ec2.SecurityGroup.from_security_group_id(
            self,
            "RuntimeSecurityGroup",
            security_group_id=runtime_security_group_id,
        )

        #
        # Package the agent code and dependencies as a direct-code zip
        #

        # Calculate paths
        agent_dir_path = os.path.join(os.path.dirname(__file__), "..", "agent")
        agent_dir_path = os.path.abspath(agent_dir_path)

        if not os.path.exists(agent_dir_path):
            raise FileNotFoundError(
                f"Agent directory not found: {agent_dir_path}. "
                "Please ensure the agent directory exists with your agent code."
            )

        scripts_dir_path = os.path.join(os.path.dirname(__file__), "scripts")
        scripts_dir_path = os.path.abspath(scripts_dir_path)

        create_zip_script_path = os.path.join(scripts_dir_path, "create_zip.py")
        if not os.path.exists(create_zip_script_path):
            raise FileNotFoundError(
                f"Required script not found: {create_zip_script_path}. "
                "Please ensure the scripts directory exists and contains create_zip.py"
            )

        with open(create_zip_script_path, "r", encoding="utf-8") as f:
            create_zip_script = f.read()

        # Create asset that packages the agent code with dependencies
        # Note: Docker must be running during cdk deploy
        agent_asset = s3_assets.Asset(
            self,
            "AgentCodeAsset",
            path=agent_dir_path,
            bundling=BundlingOptions(
                image=DockerImage.from_registry("python:3.12-slim"),
                platform="linux/arm64", 
                command=[
                    "bash",
                    "-c",
                    f"""
                    set -e
                    # Install required tools
                    apt-get update -qq && apt-get install -y -qq curl > /dev/null 2>&1

                    # Create bundle directory and copy agent code
                    mkdir -p /tmp/agent-bundle
                    cp -r /asset-input/* /tmp/agent-bundle/ 2>/dev/null || true
                    cd /tmp/agent-bundle

                    # Install dependencies directly with platform targeting
                    echo "Installing dependencies for ARM64..."
                    pip install --target /tmp/agent-bundle --upgrade \
                        --platform manylinux2014_aarch64 \
                        --only-binary=:all: \
                        --python-version 312 \
                        --implementation cp \
                        -r requirements.txt

                    # Step 3: Create zip file with everything at root level using external script
                    cd /tmp
                    cat > /tmp/create_zip.py << 'PYEOF'
{create_zip_script}
PYEOF
                    python3 /tmp/create_zip.py
                    """,
                ],
            ),
        )

        #
        # IAM role for the AgentCore Runtime
        #

        runtime_role = iam.Role(
            self,
            "AgentCoreRuntimeRole",
            assumed_by=iam.ServicePrincipal("bedrock-agentcore.amazonaws.com").with_conditions(
                {
                    "StringEquals": {
                        "aws:SourceAccount": self.account,
                    },
                    "ArnLike": {
                        "aws:SourceArn": f"arn:aws:bedrock-agentcore:{self.region}:{self.account}:*",
                    },
                }
            ),
            description="Role for Bedrock AgentCore Runtime to access RDS config, and write logs",
        )

        # CloudWatch Logs
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "logs:DescribeLogStreams",
                    "logs:CreateLogGroup",
                ],
                resources=[
                    f"arn:aws:logs:{self.region}:{self.account}:log-group:/aws/bedrock-agentcore/runtimes/*",
                ],
            )
        )
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=["logs:DescribeLogGroups"],
                resources=[f"arn:aws:logs:{self.region}:{self.account}:log-group:/aws/bedrock-agentcore/*"],
            )
        )
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "logs:CreateLogStream",
                    "logs:PutLogEvents",
                ],
                resources=[
                    f"arn:aws:logs:{self.region}:{self.account}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
                ],
            )
        )

        # X-Ray tracing
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "xray:PutTraceSegments",
                    "xray:PutTelemetryRecords",
                    "xray:GetSamplingRules",
                    "xray:GetSamplingTargets",
                ],
                resources=[f"arn:aws:xray:{self.region}:{self.account}:*"],
            )
        )

        # CloudWatch metrics for AgentCore
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=["cloudwatch:PutMetricData"],
                resources=["*"],
                conditions={
                    "StringEquals": {
                        "cloudwatch:namespace": "bedrock-agentcore",
                    },
                },
            )
        )

        # SSM Parameter Store for DB config under /agentcore/rds/*
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "ssm:GetParameter",
                    "ssm:GetParameters",
                ],
                resources=[
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter/agentcore/rds/endpoint",
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter/agentcore/rds/database",
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter/agentcore/rds/secret-arn",
                ],
            )
        )

        # Secrets Manager for DB credentials and OpenAI API key
        runtime_role.add_to_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=["secretsmanager:GetSecretValue"],
                resources=[
                    db_secret_arn,
                    openai_secret_arn,
                ],
            )
        )

        #
        # Bedrock AgentCore Runtime (L1 CFN resource) using VPC network mode
        #

        asset_bucket_name = agent_asset.s3_bucket_name
        asset_object_key = agent_asset.s3_object_key

        runtime = CfnResource(
            self,
            "AgentCoreRuntime",
            type="AWS::BedrockAgentCore::Runtime",
            properties={
                "AgentRuntimeName": "logistics_agent_cdk",
                "Description": "Runtime for logistics Strands agent with RDS backed tools",
                "RoleArn": runtime_role.role_arn,
                "NetworkConfiguration": {
                    "NetworkMode": "VPC",
                    "NetworkModeConfig": {
                        "Subnets": list(private_subnet_ids),
                        "SecurityGroups": [runtime_sg.security_group_id],
                    },
                },
                "AgentRuntimeArtifact": {
                    "CodeConfiguration": {
                        "Code": {
                            "S3": {
                                "Bucket": asset_bucket_name,
                                "Prefix": asset_object_key,
                            }
                        },
                        "EntryPoint": ["agent.py"],
                        "Runtime": "PYTHON_3_12",
                    }
                },
            },
        )

        # Output the runtime ARN
        CfnOutput(
            self,
            "RuntimeArn",
            value=runtime.get_att("AgentRuntimeArn").to_string(),
            description="ARN of the Bedrock AgentCore Runtime for the logistics agent",
        )
