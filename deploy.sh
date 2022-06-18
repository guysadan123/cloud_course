# Region, AWS keys are configured by aws-configure prior to running this script

NOW=$(date "+%s")
AVAILABILITY_ZONE=$(aws ec2 describe-availability-zones | jq -r ".AvailabilityZones | .[0].ZoneName")
REGION=$(echo $AVAILABILITY_ZONE | sed 's#.$##')
SSH_KEY_NAME="endpoint-$NOW"
SSH_KEY_FILE="$SSH_KEY_NAME.pem"
UBUNTU_20_04_AMI=$(aws ssm get-parameters \
    --names /aws/service/canonical/ubuntu/server/20.04/stable/current/amd64/hvm/ebs-gp2/ami-id | jq -r ".Parameters | .[].Value")
AVAILABILITY_ZONE2="eu-central-1c"
REDIS_SEC_GRP="redis-sg"
ENDPOINT_SERVER_SEC_GRP="endpointserver-sg"
BUCKET_NAME=endpoint-cloud-$NOW

# Create key pair
echo "create key pair $SSH_KEY_NAME and save pem file locally"
aws ec2 create-key-pair --key-name $SSH_KEY_NAME | jq -r ".KeyMaterial" > $SSH_KEY_FILE
  # secure the key pair
chmod 600 $SSH_KEY_FILE

# Create S3 Bucket to store output
echo "Creating bucket $BUCKET_NAME to store output..."
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION

# registring the name of the bucket created on SSM parameter store
aws ssm put-parameter \
    --name "/cloudcomputing/s3/bucket" \
    --value "${BUCKET_NAME}" \
    --type "String" --overwrite

# registering the region of the bucket on SSM
aws ssm put-parameter \
    --name "/cloudcomputing/s3/region" \
    --value "${REGION}" \
    --type "String" --overwrite


# SETUP OF REDIS SERVER

echo "Configuring security group for Redis server..."
aws ec2 create-security-group   \
    --group-name $REDIS_SEC_GRP       \
    --description "Redis security group"

# enable SSH to connect to server
aws ec2 authorize-security-group-ingress        \
    --group-name $REDIS_SEC_GRP --port 22 --protocol tcp \
    --cidr 0.0.0.0/0

# enable redis traffic to the server
aws ec2 authorize-security-group-ingress        \
    --group-name $REDIS_SEC_GRP --port 6379 --protocol tcp \
    --cidr 0.0.0.0/0

echo "Launching Redis server..."
RUN_REDIS_SERVER=$(aws ec2 run-instances   \
    --image-id $UBUNTU_20_04_AMI        \
    --instance-type t3.micro            \
    --key-name $SSH_KEY_NAME              \
    --security-groups $REDIS_SEC_GRP   \
    --user-data file://redis_user_data.txt)

REDIS_SERVER_INSTANCE_ID=$(echo $RUN_REDIS_SERVER | jq -r '.Instances[0].InstanceId')

# Waiting redis server to be ready
aws ec2 wait instance-running --instance-ids $REDIS_SERVER_INSTANCE_ID

# Tag server as Redis

aws ec2 create-tags --resources $REDIS_SERVER_INSTANCE_ID  --tags \
Key=Name,Value=Redis

REDIS_SERVER_IP=$(aws ec2 describe-instances  --instance-ids $REDIS_SERVER_INSTANCE_ID |
    jq -r '.Reservations[0].Instances[0].PublicIpAddress'
)

# registring redis IP on SSM parameter-store
aws ssm put-parameter \
    --name "/cloudcomputing/redis" \
    --value "$REDIS_SERVER_IP" \
    --type "String" --overwrite

echo "Redis server $REDIS_SERVER_INSTANCE_ID at IP $REDIS_SERVER_IP"

# IAM role and ec2 assignment

echo "Creating IAM Role and assigning to ec2"

aws iam create-role \
    --role-name cw_access_$NOW \
    --assume-role-policy-document file://ec2-role.json

aws iam put-role-policy \
    --role-name cw_access_$NOW \
    --policy-name CW-Permissions \
    --policy-document file://ec2-policy.json

aws iam create-instance-profile --instance-profile-name ec2access-profile

aws iam add-role-to-instance-profile \
    --instance-profile-name ec2access-profile \
    --role-name cw_access_$NOW

# SETUP OF ENDPOINT SERVERS


echo "setup security group for endpoint server..."
aws ec2 create-security-group   \
    --group-name $ENDPOINT_SERVER_SEC_GRP      \
    --description "Endpoint server security group"

aws ec2 authorize-security-group-ingress        \
    --group-name $ENDPOINT_SERVER_SEC_GRP --port 22 --protocol tcp \
    --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress        \
    --group-name $ENDPOINT_SERVER_SEC_GRP --port 5000 --protocol tcp \
    --cidr 0.0.0.0/0

echo "creating primary endpoint server..."
RUN_PRIMARY_ENDPOINT_SERVER=$(aws ec2 run-instances   \
    --image-id $UBUNTU_20_04_AMI        \
    --instance-type t3.micro            \
    --iam-instance-profile Name="ec2access-profile" \
    --key-name $SSH_KEY_NAME              \
    --security-groups $ENDPOINT_SERVER_SEC_GRP \
    --user-data file://primary_endpoint.txt)


PRIMARY_ENDPOINT_SERVER_INSTANCE_ID=$(echo $RUN_PRIMARY_ENDPOINT_SERVER | jq -r '.Instances[0].InstanceId')

aws ec2 wait instance-running --instance-ids $PRIMARY_ENDPOINT_SERVER_INSTANCE_ID


# Tag server as Endpoint
aws ec2 create-tags --resources $PRIMARY_ENDPOINT_SERVER_INSTANCE_ID  --tags \
Key=Name,Value=Primary_Endpoint



PRIMARY_ENDPOINT_SERVER_IP=$(aws ec2 describe-instances  --instance-ids $PRIMARY_ENDPOINT_SERVER_INSTANCE_ID |
    jq -r '.Reservations[0].Instances[0].PublicIpAddress'
)

echo "Primary endpoint server $PRIMARY_ENDPOINT_SERVER_INSTANCE_ID at IP $PRIMARY_ENDPOINT_SERVER_IP"

# Secondary endpoint server

echo "creating secondary endpoint server..."
RUN_SECONDARY_ENDPOINT_SERVER=$(aws ec2 run-instances   \
    --image-id $UBUNTU_20_04_AMI        \
    --instance-type t3.micro            \
    --iam-instance-profile Name="ec2access-profile" \
    --key-name $SSH_KEY_NAME              \
    --security-groups $ENDPOINT_SERVER_SEC_GRP \
    --user-data file://primary_endpoint.txt)


SECONDARY_ENDPOINT_SERVER_INSTANCE_ID=$(echo $RUN_SECONDARY_ENDPOINT_SERVER | jq -r '.Instances[0].InstanceId')

echo "waiting for secondary endpoint server creation..."
aws ec2 wait instance-running --instance-ids $SECONDARY_ENDPOINT_SERVER_INSTANCE_ID

SECONDARY_ENDPOINT_SERVER_IP=$(aws ec2 describe-instances  --instance-ids $SECONDARY_ENDPOINT_SERVER_INSTANCE_ID |
    jq -r '.Reservations[0].Instances[0].PublicIpAddress'
)

echo "secondary endpoint server $SECONDARY_ENDPOINT_SERVER_INSTANCE_ID at IP $SECONDARY_ENDPOINT_SERVER_IP"

# Worker setup using ASG

echo "creating launch configuration for worker nodes..."
aws autoscaling create-launch-configuration \
    --launch-configuration-name worker-lc-$NOW \
    --image-id $UBUNTU_20_04_AMI \
    --instance-type t3.micro \
    --iam-instance-profile "ec2access-profile" \
    --key-name $SSH_KEY_NAME \
    --security-groups $ENDPOINT_SERVER_SEC_GRP \
    --user-data file://worker_user_data.txt

# Autoscaling group - workers (Max size configure the maximum number of worker, can be changed)
echo "creating auto scaling group for worker nodes..."
aws autoscaling create-auto-scaling-group --auto-scaling-group-name workers-asg \
	--launch-configuration-name worker-lc-$NOW \
  --availability-zones $AVAILABILITY_ZONE \
  --max-size 20 --min-size 1 --desired-capacity 1

