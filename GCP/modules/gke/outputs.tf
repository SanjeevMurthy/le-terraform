output "cluster_name" {
  value       = google_container_cluster.this.name
  description = "Cluster name, used by \"gcloud container clusters get-credentials\"."
}

output "cluster_location" {
  value       = google_container_cluster.this.location
  description = "Zone the cluster lives in."
}

output "cluster_endpoint" {
  value       = google_container_cluster.this.endpoint
  description = "Public IP of the Kubernetes API server."
  sensitive   = true
}

output "workload_identity_pool" {
  value       = "${var.project_id}.svc.id.goog"
  description = "The Workload Identity pool, used when binding KSAs to GSAs."
}

output "get_credentials_command" {
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${google_container_cluster.this.location} --project ${var.project_id}"
  description = "Copy-paste this to point kubectl at the cluster."
}
