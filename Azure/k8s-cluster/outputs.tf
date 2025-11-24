output "master_public_ip" {
  value = module.master_nic.public_ip
}

output "worker_private_ips" {
  value = [
    for nic in module.worker_nics : nic.private_ip
  ]
}
