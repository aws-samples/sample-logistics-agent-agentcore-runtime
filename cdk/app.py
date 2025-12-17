import os
import aws_cdk as cdk

from logistics_agent_runtime_stack import LogisticsAgentRuntimeStack


app = cdk.App()

# Get account and region from environment variables
account = os.environ.get("CDK_DEFAULT_ACCOUNT")
region = os.environ.get("CDK_DEFAULT_REGION", "us-east-1")

if not account:
    raise ValueError("CDK_DEFAULT_ACCOUNT environment variable must be set")

# Get infrastructure values from environment variables
# These should be set after deploying the RDS CloudFormation stack
vpc_id = os.environ.get("AGENTCORE_VPC_ID")
subnet_1 = os.environ.get("AGENTCORE_SUBNET_1")
subnet_2 = os.environ.get("AGENTCORE_SUBNET_2")
runtime_sg_id = os.environ.get("AGENTCORE_RUNTIME_SG_ID")
db_secret_arn = os.environ.get("AGENTCORE_DB_SECRET_ARN")
openai_secret_arn = os.environ.get("AGENTCORE_OPENAI_SECRET_ARN")

# Validate required environment variables
required_vars = {
    "AGENTCORE_VPC_ID": vpc_id,
    "AGENTCORE_SUBNET_1": subnet_1,
    "AGENTCORE_SUBNET_2": subnet_2,
    "AGENTCORE_RUNTIME_SG_ID": runtime_sg_id,
    "AGENTCORE_DB_SECRET_ARN": db_secret_arn,
    "AGENTCORE_OPENAI_SECRET_ARN": openai_secret_arn,
}

missing_vars = [name for name, value in required_vars.items() if not value]
if missing_vars:
    raise ValueError(
        f"Missing required environment variables: {', '.join(missing_vars)}\n"
        f"Please run the setup script to export these values from your CloudFormation stack."
    )

LogisticsAgentRuntimeStack(
    app,
    "LogisticsAgentRuntimeStack",
    vpc_id=vpc_id,
    private_subnet_ids=[subnet_1, subnet_2],
    runtime_security_group_id=runtime_sg_id,
    db_secret_arn=db_secret_arn,
    openai_secret_arn=openai_secret_arn,
    env=cdk.Environment(
        account=account,
        region=region,
    ),
)

app.synth()
