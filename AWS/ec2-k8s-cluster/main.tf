provider "aws" {
    region     = var.aws_region
}

resource "aws_key_pair" "deployer" {
    key_name   = var.key_name
    public_key = file(var.public_key_path)
}

resource "aws_security_group" "ssh" {
    name        = "ssh-access"
    description = "Allow SSH access"
    # vpc_id      = var.vpc_id

    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = [var.allowed_ssh_cidr]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        Name = "ssh-access"
    }
  
}

module "ec2_instance_1" {
    source              = "../modules/ec2-instance"
    instance_name      = "k8s-control-node"
    instance_type      = var.instance_type
    subnet_id          = var.subnet_id
    security_group_ids = [aws_security_group.ssh.id]
    key_name           = aws_key_pair.deployer.key_name
    ami_name_filter    = "amzn2-ami-hvm-*-x86_64-gp2"
    enable_public_ip   = true
}

module "ec2_instance_2" {
    source              = "../modules/ec2-instance"
    instance_name      = "k8s-worker-node-1"
    instance_type      = var.instance_type
    subnet_id          = var.subnet_id
    security_group_ids = [aws_security_group.ssh.id]
    key_name           = aws_key_pair.deployer.key_name
    ami_name_filter    = "amzn2-ami-hvm-*-x86_64-gp2"
    enable_public_ip   = true
  
}
