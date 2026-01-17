"""
OpenRAG Wake Lambda Function

This Lambda function starts the EC2 Spot instance when a request comes in.
It acts as a "wake-on-demand" trigger for the serverless architecture.

Deploy behind API Gateway for HTTP trigger.
"""

import json
import os
import time
import boto3
import urllib.request
import urllib.error

# Configuration from environment variables
EC2_INSTANCE_ID = os.environ.get('EC2_INSTANCE_ID')
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
OPENRAG_PORT = os.environ.get('OPENRAG_PORT', '8080')
MAX_WAIT_SECONDS = int(os.environ.get('MAX_WAIT_SECONDS', '300'))
HEALTH_CHECK_INTERVAL = int(os.environ.get('HEALTH_CHECK_INTERVAL', '10'))

ec2 = boto3.client('ec2', region_name=AWS_REGION)


def get_instance_state():
    """Get current EC2 instance state."""
    response = ec2.describe_instances(InstanceIds=[EC2_INSTANCE_ID])
    return response['Reservations'][0]['Instances'][0]['State']['Name']


def get_instance_ip():
    """Get EC2 instance public IP."""
    response = ec2.describe_instances(InstanceIds=[EC2_INSTANCE_ID])
    return response['Reservations'][0]['Instances'][0].get('PublicIpAddress')


def start_instance():
    """Start the EC2 instance."""
    ec2.start_instances(InstanceIds=[EC2_INSTANCE_ID])


def wait_for_instance_running():
    """Wait for instance to be in running state."""
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(
        InstanceIds=[EC2_INSTANCE_ID],
        WaiterConfig={'Delay': 5, 'MaxAttempts': 60}
    )


def check_openrag_health(ip):
    """Check if OpenRAG API is responding."""
    url = f"http://{ip}:{OPENRAG_PORT}/health"
    try:
        req = urllib.request.Request(url, method='GET')
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status == 200
    except (urllib.error.URLError, TimeoutError):
        return False


def wait_for_openrag_ready(ip):
    """Wait for OpenRAG to be ready to serve requests."""
    start_time = time.time()
    while time.time() - start_time < MAX_WAIT_SECONDS:
        if check_openrag_health(ip):
            return True
        time.sleep(HEALTH_CHECK_INTERVAL)
    return False


def lambda_handler(event, context):
    """
    Main Lambda handler.

    Can be triggered by:
    - API Gateway (HTTP request)
    - EventBridge (scheduled)
    - SNS (notification)
    """

    if not EC2_INSTANCE_ID:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'EC2_INSTANCE_ID not configured'})
        }

    # Get current instance state
    state = get_instance_state()
    print(f"Instance {EC2_INSTANCE_ID} state: {state}")

    if state == 'running':
        # Already running, get IP and check health
        ip = get_instance_ip()
        if ip and check_openrag_health(ip):
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'status': 'ready',
                    'instance_id': EC2_INSTANCE_ID,
                    'ip': ip,
                    'message': 'OpenRAG is running and healthy'
                })
            }
        elif ip:
            # Running but not healthy yet, wait
            if wait_for_openrag_ready(ip):
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'status': 'ready',
                        'instance_id': EC2_INSTANCE_ID,
                        'ip': ip,
                        'message': 'OpenRAG is now ready'
                    })
                }

    elif state in ['stopped', 'stopping']:
        # Need to start the instance
        print(f"Starting instance {EC2_INSTANCE_ID}...")
        start_instance()
        wait_for_instance_running()

        ip = get_instance_ip()
        print(f"Instance running at {ip}, waiting for OpenRAG...")

        if wait_for_openrag_ready(ip):
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'status': 'ready',
                    'instance_id': EC2_INSTANCE_ID,
                    'ip': ip,
                    'message': 'OpenRAG started and ready',
                    'startup_time': 'cold_start'
                })
            }
        else:
            return {
                'statusCode': 503,
                'body': json.dumps({
                    'status': 'starting',
                    'instance_id': EC2_INSTANCE_ID,
                    'ip': ip,
                    'message': 'Instance started but OpenRAG not ready yet'
                })
            }

    elif state == 'pending':
        # Already starting, wait for it
        wait_for_instance_running()
        ip = get_instance_ip()

        if wait_for_openrag_ready(ip):
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'status': 'ready',
                    'instance_id': EC2_INSTANCE_ID,
                    'ip': ip,
                    'message': 'OpenRAG is ready'
                })
            }

    return {
        'statusCode': 503,
        'body': json.dumps({
            'status': 'unavailable',
            'instance_state': state,
            'message': 'Could not start OpenRAG'
        })
    }


def proxy_request(event, ip):
    """
    Proxy the incoming request to OpenRAG.
    Use this if you want Lambda to act as a full proxy.
    """
    path = event.get('path', '/')
    method = event.get('httpMethod', 'GET')
    headers = event.get('headers', {})
    body = event.get('body', '')

    url = f"http://{ip}:{OPENRAG_PORT}{path}"

    try:
        req = urllib.request.Request(
            url,
            data=body.encode() if body else None,
            headers=headers,
            method=method
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            return {
                'statusCode': response.status,
                'body': response.read().decode(),
                'headers': dict(response.headers)
            }
    except urllib.error.HTTPError as e:
        return {
            'statusCode': e.code,
            'body': e.read().decode()
        }
