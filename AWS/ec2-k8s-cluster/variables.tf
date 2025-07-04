variable "aws_region" {
  description = "AWS region to deploy into"
  default     = "us-east-1"
}

variable "key_name" {
  description = "Key pair name to create/use"
  default     = "deployer_key"
}

variable "public_key_path" {
  description = "Path to your SSH public key"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "CIDR range allowed to SSH"
  default     = "0.0.0.0/0"
}

variable "subnet_id" {
  description = "Subnet ID for EC2 instances"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.medium"
}