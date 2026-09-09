output "service_account_email" {
  description = "Put this in the KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.this.email
}

output "ksa_annotation" {
  description = "The exact annotation line your Kubernetes ServiceAccount needs."
  value       = "iam.gke.io/gcp-service-account: ${google_service_account.this.email}"
}
