output "network_id" {
  description = "Full resource ID of the VPC, consumed by the GKE module."
  value       = google_compute_network.vpc.id
}

output "network_name" {
  description = "Short name of the VPC."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "Full resource ID of the node subnet."
  value       = google_compute_subnetwork.nodes.id
}

output "subnet_name" {
  description = "Short name of the node subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the secondary range GKE will use for Pod IPs."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range GKE will use for Service ClusterIPs."
  value       = "services"
}

output "cloud_nat_enabled" {
  description = "Whether the (billable) Cloud NAT gateway is currently deployed."
  value       = var.enable_cloud_nat
}
