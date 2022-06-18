aws ec2 create-launch-template \
  --launch-template-name worker-lc \
  --launch-template-data '{"IamInstanceProfile":{"Name":"ec2access-profile"} ,"ImageId":"ami-0ce4b8a18a8605eff","InstanceType":"t3.micro"}'
  
