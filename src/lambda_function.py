# ./src/lambda_function.py

import json

def lambda_handler(event, context):
    for record in event['Records']:
        print(f"Message Body: {record['body']}")

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }