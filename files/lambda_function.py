import json
from datetime import datetime

def lambda_handler(event, context):
    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"Se invocará a Jenkins - {current_time}")
    
    return {
        "statusCode": 200,
        "body": json.dumps("Print executed")
    }