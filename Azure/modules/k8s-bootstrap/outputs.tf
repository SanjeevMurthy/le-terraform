output "join_command" {
  value       = try(data.external.join_command[0].result.command, "")
  description = "The kubeadm join command generated on the master (e.g. kubeadm join ...)"
  depends_on  = [null_resource.master_init_runner]
}

# Also expose the base64 cloud-init (common) so callers can use it for creating VMs
output "cloud_init_base_b64" {
  value = base64encode(local.common_setup_script)
}

output "cloud_init_master_b64" {
  value = base64encode(local.master_setup_script)
}

output "common_setup_script" {
  value = local.common_setup_script
}
