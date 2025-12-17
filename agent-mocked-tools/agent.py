import json
import boto3
import logging
from datetime import datetime, timedelta
from strands import Agent, tool
from strands.models.openai import OpenAIModel
from bedrock_agentcore import BedrockAgentCoreApp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
AWS_REGION = 'us-east-1'
OPENAI_SECRET_NAME = 'openai-api-key'

app = BedrockAgentCoreApp()

# Mock data for shipments
MOCK_SHIPMENTS = {
    "SHIP-REF-1001": {
        "reference_no": "SHIP-REF-1001",
        "status": "IN_TRANSIT",
        "event": "DEPARTED",
        "current_location": "Port of Los Angeles",
        "unlocode": "USLAX",
        "occurred_at": (datetime.now() - timedelta(days=2)).isoformat(),
        "details": "Container loaded on vessel MSC MAYA"
    },
    "SHIP-REF-1002": {
        "reference_no": "SHIP-REF-1002",
        "status": "DELIVERED",
        "event": "DELIVERED",
        "current_location": "Shanghai Distribution Center",
        "unlocode": "CNSHA",
        "occurred_at": (datetime.now() - timedelta(hours=6)).isoformat(),
        "details": "Delivered to consignee"
    },
    "SHIP-REF-1003": {
        "reference_no": "SHIP-REF-1003",
        "status": "AT_RISK",
        "event": "DELAYED",
        "current_location": "Port of Singapore",
        "unlocode": "SGSIN",
        "occurred_at": (datetime.now() - timedelta(hours=12)).isoformat(),
        "details": "Vessel delayed due to weather conditions"
    }
}

@tool
def get_shipment_status(reference_no: str) -> str:
    """
    Get the current status and latest event for a shipment.
    
    Args:
        reference_no: Shipment reference number (e.g., 'SHIP-REF-1001')
    
    Returns:
        Current status, location, and latest event details
    """
    try:
        if reference_no in MOCK_SHIPMENTS:
            return json.dumps(MOCK_SHIPMENTS[reference_no], indent=2)
        else:
            return f"Shipment {reference_no} not found"
            
    except Exception as e:
        logger.error(f"Error in get_shipment_status: {type(e).__name__}: {str(e)}", exc_info=True)
        return f"Error retrieving shipment status: {str(e)}"


@tool
def find_delayed_shipments() -> str:
    """
    Find all shipments that are at risk of being delayed based on ETA.
    
    Returns:
        List of shipments with at-risk status
    """
    try:
        # Filter shipments from MOCK_SHIPMENTS that have AT_RISK status
        delayed = []
        for ref_no, shipment in MOCK_SHIPMENTS.items():
            if shipment.get("status") == "AT_RISK":
                delayed.append({
                    "reference_no": ref_no,
                    "status": shipment["status"],
                    "current_location": shipment["current_location"],
                    "event": shipment["event"],
                    "occurred_at": shipment["occurred_at"],
                    "details": shipment["details"]
                })
        
        if not delayed:
            return "No delayed shipments found"
        
        return json.dumps(delayed, indent=2)
            
    except Exception as e:
        logger.error(f"Error in find_delayed_shipments: {type(e).__name__}: {str(e)}", exc_info=True)
        return f"Error finding delayed shipments: {str(e)}"

_openai_model = None

def _get_openai_model():
    """Get OpenAI model with API key from Secrets Manager"""
    global _openai_model
    
    if _openai_model is not None:
        return _openai_model
    
    try:
        # Get OpenAI API key from Secrets Manager
        secrets_client = boto3.client('secretsmanager', region_name=AWS_REGION)
        secret_response = secrets_client.get_secret_value(SecretId=OPENAI_SECRET_NAME)

        secret_data = json.loads(secret_response['SecretString'])
        api_key = secret_data.get('openai-api-key', 'Not found')
        
        # Create OpenAI model
        _openai_model = OpenAIModel(
            client_args={"api_key": api_key},
            model_id="gpt-4o-mini",
            params={
                "max_tokens": 2000,
                "temperature": 0.7,
            }
        )
        logger.info("OpenAI model initialized successfully")
        return _openai_model
        
    except Exception as e:
        logger.error(f"Failed to initialize OpenAI model: {e}", exc_info=True)
        raise


SYSTEM_PROMPT = """You are a logistics tracking assistant with access to a shipment tracking system.

You can help users:
- Track shipment status and location
- View complete shipment routes
- Identify delayed shipments
- Check container history
- Monitor customs holds

When answering questions:
- Be concise and focus on the most relevant information
- Include reference numbers, locations, and timestamps
- Explain any issues or delays clearly
- Suggest next steps when appropriate
"""

_agent = None

def _initialize_agent():
    """Initialize the agent with OpenAI and mocked tools."""
    global _agent
    if _agent is None:
        # Get OpenAI model
        openai_model = _get_openai_model()
        
        # Create agent with OpenAI model
        _agent = Agent(
            name="logistics_agent",
            model=openai_model,
            tools=[
                get_shipment_status,
                find_delayed_shipments
            ],
            system_prompt=SYSTEM_PROMPT,
            callback_handler=None
        )
    return _agent

@app.entrypoint
def logistics_query(payload):
    """Handle logistics queries"""
    
    user_query = payload.get("query")
    
    if not user_query:
        return "Please provide a query in the format: {\"query\": \"your question here\"}"
    
    try:
        # Initialize agent lazily on first request
        agent = _initialize_agent()
        
        # Execute the agent
        result = agent(user_query)
        
        # Return the response
        return result.message['content'][0]['text']
    except Exception as e:
        logger.error(f"Query failed: {type(e).__name__}: {str(e)}", exc_info=True)
        return f"Query failed: {str(e)}"

if __name__ == "__main__":
    app.run()
