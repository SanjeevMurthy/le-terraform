#!/bin/zsh
# Stop all EC2 instances in the specified region
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
  exit 1
fi
# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo "AWS CLI is not installed. Please install it first."
  exit 1
fi  
# Get the list of all running EC2 instances in the specified region
#instance_ids=$(aws ec2 describe-instances --query "Reservations[*].Instances[?State.Name=='running'].InstanceId" --output text)
instance_ids=$(terraform output -json | jq -r '.[] | select(.value.instance_id != null) | .value.instance_id')
if [ -z "$instance_ids" ]; then
  echo "No running EC2 instances found."
  exit 0
fi
# Stop the instances
echo "Stopping the following EC2 instances: $instance_ids"
aws ec2 stop-instances --instance-ids $instance_ids
if [ $? -eq 0 ]; then
  echo "Successfully stopped the instances."
else
  echo "Failed to stop the instances. Please check your AWS CLI configuration and permissions."
  exit 1
fi