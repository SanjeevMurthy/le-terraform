output "workload_identity_provider" {
  description = "Paste this into the workload_identity_provider input of google-github-actions/auth."
  value       = "projects/${var.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "app_service_account_email" {
  description = "Service account the application deploy workflow impersonates."
  value       = google_service_account.app.email
}

output "infra_service_account_email" {
  description = "Service account the Terraform workflow impersonates."
  value       = google_service_account.infra.email
}
