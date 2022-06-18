import redis
import sys
import json
import hashlib
import boto3
import urllib.request

JOB_QUEUE = 'queue:jobs'
COMPLETED_JOB_QUEUE= 'queue:completed-jobs'
REDIS_PORT = 6379

def get_redis_ssm(region):
    ssm = boto3.client("ssm", region_name=region)
    return ssm.get_parameter(
        Name="/cloudcomputing/redis",
        WithDecryption=True).get("Parameter").get("Value")

def get_s3_ssm(region):
    ssm = boto3.client("ssm", region_name=region)
    return ssm.get_parameter(
        Name="/cloudcomputing/s3/bucket",
        WithDecryption=True).get("Parameter").get("Value")


def process(payload, iterations):
    output = hashlib.sha512(payload).digest()
    for i in range(iterations - 1):
        output = hashlib.sha512(output).digest()
    return output

def write_s3(job_id, content, region):
    bucket_name =  get_s3_ssm(region)
    s3 = boto3.resource('s3')
    object = s3.Object(bucket_name, job_id)
    object.put(Body=content)



region = urllib.request.urlopen('http://169.254.169.254/latest/meta-data/placement/availability-zone').read().decode()[:-1]

redis_server_ip = get_redis_ssm(region)
print(redis_server_ip)
redis_conn = redis.Redis(host=redis_server_ip, port=REDIS_PORT, db=0)

while True:
    jobs = redis_conn.lpop(JOB_QUEUE)
    if jobs is not None:
        parsed_jobs = json.loads(jobs)
        print(parsed_jobs)
        job_id = parsed_jobs['job_id']
        print(job_id)
        iterations = parsed_jobs['iterations']
        payload = parsed_jobs['payload']
        processed_payload = process(bytes(payload, 'utf-8'), iterations)
        write_s3(job_id, processed_payload, region)
        print(processed_payload)
        redis_conn.rpush(COMPLETED_JOB_QUEUE, json.dumps({'job_id': job_id, 'processed_payload': str(processed_payload)}))


