output "join_command" {
  value       = try(chomp(data.local_file.join_command_file[0].content), "")
  description = "The kubeadm join command generated on the master (e.g. kubeadm join ...)"
  depends_on  = [null_resource.master_init_runner]
}

# Also expose the base64 cloud-init (common) so callers can use it for creating VMs
output "cloud_init_base_b64" {
  value = base64encode(local.common_setup_script)
}

output "common_setup_script" {
  value = local.common_setup_script
}
