data "aws_ami" "latest" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
}  

resource "aws_instance" "this" {
    ami           = data.aws_ami.latest.id
    instance_type = var.instance_type
    key_name      = var.key_name
    subnet_id     = var.subnet_id
    
    security_groups = var.security_group_ids
    
    associate_public_ip_address = var.enable_public_ip
    
    tags = {
        Name = var.instance_name
    }
  
}