import json
import boto3
import logging
import pg8000.native
from strands import Agent, tool
from strands.models.openai import OpenAIModel
from bedrock_agentcore import BedrockAgentCoreApp


# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
AWS_REGION = 'us-east-1'
OPENAI_SECRET_NAME = 'openai-api-key'  

app = BedrockAgentCoreApp()

# Database configuration - cached after first load within a session
_db_config = None
_db_credentials = None
_db_connection = None

def _load_db_config():
    """Load database configuration from SSM Parameter Store"""
    global _db_config, _db_credentials
    
    if _db_config is not None:
        return _db_config, _db_credentials
    
    try:
        # Load configuration from SSM Parameter Store
        ssm_client = boto3.client('ssm', region_name=AWS_REGION)
        response = ssm_client.get_parameters(
            Names=[
                '/agentcore/rds/endpoint',
                '/agentcore/rds/database',
                '/agentcore/rds/secret-arn'
            ]
        )
        
        params = {p['Name']: p['Value'] for p in response['Parameters']}
        _db_config = {
            'endpoint': params['/agentcore/rds/endpoint'],
            'database': params['/agentcore/rds/database'],
            'secret_arn': params['/agentcore/rds/secret-arn']
        }
        
        # Load credentials from Secrets Manager
        secrets_client = boto3.client('secretsmanager', region_name=AWS_REGION)
        secret_response = secrets_client.get_secret_value(SecretId=_db_config['secret_arn'])
        _db_credentials = json.loads(secret_response['SecretString'])
        
        return _db_config, _db_credentials
        
    except Exception as e:
        logger.error(f"Failed to load database configuration: {e}", exc_info=True) 
        raise

def get_db_connection():
    """Get or create a cached database connection"""    
    global _db_connection
    
    # Check if we have a cached connection and if it's still alive
    if _db_connection is not None:
            return _db_connection
    
    # Create new connection
    try:
        config, credentials = _load_db_config()
        
        _db_connection = pg8000.native.Connection(
            host=config['endpoint'],
            database=config['database'],
            user=credentials['username'],
            password=credentials['password'],
            timeout=30  
        )
        return _db_connection
    except Exception as e:
        logger.error(f"Database connection failed: {type(e).__name__}: {str(e)}")  # noqa: TRY400
        raise

@tool
def get_shipment_status(reference_no: str) -> str:
    """
    Get the current status and latest event for a shipment.
    
    Args:
        reference_no: Shipment reference number (e.g., 'ACME-REF-1001')
    
    Returns:
        Current status, location, and latest event details
    """
    try:
        conn = get_db_connection()
        
        query = """
        SELECT 
            s.reference_no,
            s.status,
            le.event,
            loc.name AS current_location,
            loc.unlocode,
            le.occurred_at,
            le.details
        FROM logistics.shipments s
        JOIN logistics.v_shipment_latest_event le ON le.shipment_id = s.shipment_id
        LEFT JOIN logistics.locations loc ON loc.location_id = le.location_id
        WHERE s.reference_no = :reference_no
        """
        
        result = conn.run(query, reference_no=reference_no)
        
        if result:
            return json.dumps(result[0], default=str, indent=2)
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
        conn = get_db_connection()
        
        query = """
        SELECT 
            r.reference_no,
            r.eta,
            r.eta_final,
            r.eta_status
        FROM logistics.mv_eta_risk r
        WHERE r.eta_status = 'AT_RISK'
        ORDER BY r.eta DESC NULLS LAST
        """
        
        results = conn.run(query)
        
        if results:
            return json.dumps(results, default=str, indent=2)
        else:
            return "No delayed shipments found"
            
    except Exception as e:
        logger.error(f"Error in find_delayed_shipments: {type(e).__name__}: {str(e)}", exc_info=True)
        return f"Error finding delayed shipments: {str(e)}"

SYSTEM_PROMPT = """You are a logistics tracking assistant with access to a real-time shipment database.

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
- Suggest next steps when appropriate"""

_agent = None

_openai_model = None
def _get_openai_model():
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
            model_id="gpt-4o",
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
 
def _initialize_agent():
    """Initialize the agent with database tools."""
    global _agent
    if _agent is None:
        # Get OpenAI model
        openai_model = _get_openai_model()
        
        # Tools are passed directly as Python functions
        _agent = Agent(
            name="logistics_agent",
            model=openai_model,
            tools=[
                get_shipment_status,
                find_delayed_shipments
            ],
            system_prompt=SYSTEM_PROMPT,
            callback_handler=None,
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
