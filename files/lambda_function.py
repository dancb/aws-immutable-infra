import json
import requests

def lambda_handler(event, context):
    jenkins_url = "http://<JENKINS_URL>/job/terraform-apply/build"
    jenkins_user = "<JENKINS_USER>"
    jenkins_token = "<JENKINS_API_TOKEN>"
    
    response = requests.post(jenkins_url, auth=(jenkins_user, jenkins_token))
    if response.status_code == 201:
        return {"statusCode": 200, "body": "Pipeline triggered"}
    else:
        return {"statusCode": 500, "body": "Error triggering pipeline"}