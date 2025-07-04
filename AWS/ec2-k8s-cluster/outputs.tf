output "ec2_instance_1_info" {
  description = "Instance ID and Public IP of the first EC2 instance (k8s-control-node)"
  value = {
    instance_id = module.ec2_instance_1.instance_id
    public_ip   = module.ec2_instance_1.public_ip
  }
}

output "ec2_instance_2_info" {
  description = "Instance ID and Public IP of the second EC2 instance (k8s-worker-node-1)"
  value = {
    instance_id = module.ec2_instance_2.instance_id
    public_ip   = module.ec2_instance_2.public_ip
  }
}