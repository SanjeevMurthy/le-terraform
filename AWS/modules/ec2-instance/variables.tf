variable "instance_name" {
  type        = string
  description = "Name tag for the EC2 instance"
}

variable "instance_type" {
  type        = string
  default     = "t2.micro"
  description = "EC2 instance type"
}

variable "key_name" {
  type        = string
  description = "Name of the AWS Key Pair for SSH"
}

variable "security_group_ids" {
  type        = list(string)
  description = "List of security group IDs to attach"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for the instance (optional)"
}

variable "ami_name_filter" {
  type        = string
  default     = "amzn2-ami-hvm-*-x86_64-gp2"
  description = "AMI name filter (defaults to Amazon Linux 2)"
}

variable "enable_public_ip" {
  type        = bool
  default     = true
  description = "Whether to assign a public IP"
}