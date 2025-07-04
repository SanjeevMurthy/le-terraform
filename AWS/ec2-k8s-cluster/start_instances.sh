#!/bin/zsh
# Start all EC2 instances from Terraform output

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
  exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo "AWS CLI is not installed. Please install it first."
  exit 1
fi

# Get the list of instance IDs from terraform output
instance_ids=$(terraform output -json | jq -r '.[] | select(.value.instance_id != null) | .value.instance_id')

if [ -z "$instance_ids" ]; then
  echo "No EC2 instance IDs found in terraform output."
  exit 0
fi

# Start the instances
echo "Starting the following EC2 instances: ${instance_ids[@]}"
aws ec2 start-instances --instance-ids  $instance_ids
if [ $? -eq 0 ]; then
  echo "Successfully started the instances."
  echo "Waiting 2 minutes for instances to initialize and get public IPs..."
  sleep 120
  echo "Refreshing Terraform state to get updated public IPs..."
  terraform apply -refresh-only -auto-approve
else
  echo "Failed to start the instances. Please check your AWS CLI configuration and permissions."
  exit 1
fi