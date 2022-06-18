# CS Exercise

The script creates endpoint API server,  which gets jobs and enqueue them to redis queue
The jobs are pulled from the queue and processed by worker nodes.
When the job queue is loaded with more than 5 jobs, scale-up procedure is triggered to launch more workers

The output of each process/job is written to S3 bucket. Each job creates its own file on the bucket, with the same name as the job ID. 
Each file contains the job output.

When the proccessed job is completed, the job ID is enqueued to completed job queue.

### Prerequisite

1. install aws cli and jq package
2. configure aws cli using ```aws configure```
3. make sure region is configured

### Running the solution

Run  bash script called ./deploy.sh from directory

