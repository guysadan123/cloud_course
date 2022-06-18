from flask import Flask, Response, request
import json
import redis
import uuid
import re
import sys
from apscheduler.schedulers.background import BackgroundScheduler
import boto3
import argparse
from datetime import datetime, date, time, timedelta
import urllib.request
import time



JOB_QUEUE = 'queue:jobs'
COMPLETED_JOB_QUEUE = 'queue:completed-jobs'
REDIS_PORT = 6379
cooldown = 20 # Cooldown period in seconds
ASG = "workers-asg"
TIME = datetime.now() + timedelta(0, 60) # starts after 3 minutes
app = Flask(__name__)


def get_redis_conn(redis_server_ip):
    return redis.Redis(host=redis_server_ip, port=REDIS_PORT, db=0)


@app.route('/enqueue', methods=['PUT'])
def execute_enqueue():
    job_id = str(uuid.uuid1())
    iterations_arg = request.args.get('iterations')
    iterations = int(re.findall('\d+', iterations_arg)[0])
    file = request.files['file']
    file_content = file.read()
    redis_conn = get_redis_conn(app.config.get('redis_server_ip'))
    redis_conn.rpush(JOB_QUEUE, json.dumps({'job_id': job_id, 'iterations': iterations, 'payload': str(file_content)}))
    scale_job_queue_len(redis_server_ip, region)
    return Response(mimetype='application/json',
                    response=json.dumps({'job_id': job_id}),
                    status=200)


@app.route('/pullCompleted', methods=['POST'])
def execute_pull_completed():
    top_arg = request.args.get('top')
    top = int(re.findall('\d+', top_arg)[0])
    redis_conn = get_redis_conn(app.config.get('redis_server_ip'))
    # The default redis version does not support atomic pop operation of multiple items.
    completed_job = []
    for i in range(top):
        item = redis_conn.lpop(COMPLETED_JOB_QUEUE)
        if item is not None:
            completed_job.append(json.loads(item))
    if len(completed_job) == 0:
        return Response(mimetype='application/json',
                        response='Work completed queue is empty.',
                        status=200)
    return Response(mimetype='application/json',
                    response=json.dumps({'completed_job': completed_job}),
                    status=200)



def get_redis_ssm(region):
    # Read from SSM the IP of REDIS 
    ssm = boto3.client("ssm", region_name=region)

    return ssm.get_parameter(
        Name="/cloudcomputing/redis",
        WithDecryption=True).get("Parameter").get("Value")

def scale_up(region):
    global TIME
    global ASG
    global cooldown
    difference = (datetime.now() - TIME)
    difference_seconds = difference.total_seconds()
    print(difference_seconds)
    if ( difference_seconds < cooldown):
        print("No Scale")
        return 1

    print("Scaling")
    asg_client = boto3.client('autoscaling',region_name=region)

    current_desired_capacity = asg_client.describe_auto_scaling_groups (AutoScalingGroupNames=[ASG])\
        ["AutoScalingGroups"][0]["DesiredCapacity"]
    max_capacity = asg_client.describe_auto_scaling_groups (AutoScalingGroupNames=[ASG])\
        ["AutoScalingGroups"][0]["MaxSize"]

    desired_new_capacity = current_desired_capacity + 1 

    if max_capacity <= desired_new_capacity:
      desired_new_capacity = max_capacity

    asg_response = asg_client.update_auto_scaling_group (AutoScalingGroupName=ASG, MaxSize=max_capacity ,DesiredCapacity=desired_new_capacity)
    TIME = datetime.now() + timedelta(0, cooldown) # COOL Down Timer For Autoscale to stable

def scale_job_queue_len(redis_server_ip, region):
    redis_conn = get_redis_conn(redis_server_ip)
    queueLength = redis_conn.llen(JOB_QUEUE)
    if (queueLength > 5):
        print(queueLength)
        print(region)
        scale_up(region)
    


if __name__ == '__main__':

    region = urllib.request.urlopen('http://169.254.169.254/latest/meta-data/placement/availability-zone').read().decode()[:-1]

    print(region)


    parser = argparse.ArgumentParser(description="This script configures netjobing.")

    parser.add_argument('-r', '--redis', required=False, default=False,
                    help="Redis IP")
    parser.add_argument('-p', '--primary',  required=False, default=False, action='store_true',
                    help="Primary Endpoint")

    args = parser.parse_args()
    
    redis_server_ip = get_redis_ssm(region)
    print (f"Redis IP is on %s" % redis_server_ip)
    is_primary = args.primary
    if is_primary:
        scheduler = BackgroundScheduler()
        scheduler.add_job(func=report_job_queue_len, args=[redis_server_ip], trigger="interval", seconds=60)
        scheduler.start()
    app.config['redis_server_ip'] = redis_server_ip
    app.run(host="0.0.0.0")
