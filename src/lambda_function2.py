# ./lambda_function2.py

import json

def lambda_handler(event, context):
    for record in event['Records']:
        body = record['body']
        try:
            number = int(body)  
            
            if number % 2 == 0:
                raise ValueError(f'Error: {number} is an even number')
            else:
                print(f"Message Body: {body}")
        except ValueError as e:
            print(e)
            raise  
    return {
        'statusCode': 200,
        'body': json.dumps('Processed successfully')
    }