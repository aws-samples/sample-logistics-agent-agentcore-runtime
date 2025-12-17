import boto3
import json
import uuid
import os

# Initialize the client
client = boto3.client('bedrock-agentcore', region_name='us-east-1')

# Get runtime ARN from environment variable (set in previous step)
runtime_arn = os.environ.get('AGENT_RUNTIME_ARN') or f"arn:aws:bedrock-agentcore:us-east-1:{os.environ.get('CDK_DEFAULT_ACCOUNT')}:runtime/RUNTIME_ID"

# Create a unique session ID for each invocation (33+ characters required)
session_id = str(uuid.uuid4()) + '-demo-session'

# Prepare the payload
payload = json.dumps({"query": "What shipments are at risk of being delayed?"})

# Invoke the agent
response = client.invoke_agent_runtime(
    agentRuntimeArn=runtime_arn,
    runtimeSessionId=session_id,
    payload=payload,
    qualifier="DEFAULT"  # Optional
)

# Parse and print the response
response_body = response['response'].read()
response_data = json.loads(response_body)
print("Agent Response:", json.dumps(response_data, indent=2))