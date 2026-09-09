# ---------------------------------------------------------------------------
# Everything you need to copy into the next chapter, in one place.
# Run "terraform output" any time you lose your place.
# ---------------------------------------------------------------------------

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

# --- Chapter 04: point kubectl at the cluster ------------------------------
output "get_credentials_command" {
  description = "Run this to configure kubectl."
  value       = module.gke.get_credentials_command
}

output "cluster_name" {
  value = module.gke.cluster_name
}

# --- Chapter 05/06: build and push images ----------------------------------
output "registry_host" {
  description = "Use with: gcloud auth configure-docker <this> --quiet"
  value       = module.artifact_registry.registry_host
}

output "image_repo" {
  description = "Tag images as <this>/api:TAG and <this>/web:TAG"
  value       = module.artifact_registry.repository_url
}

# --- Chapter 06: annotate the Kubernetes ServiceAccount --------------------
output "api_google_service_account" {
  description = "Goes in the KSA's iam.gke.io/gcp-service-account annotation."
  value       = module.api_workload_identity.service_account_email
}

# --- Chapter 08/09: GitHub repository variables ----------------------------
output "github_workload_identity_provider" {
  description = "GitHub repo variable: GCP_WORKLOAD_IDENTITY_PROVIDER"
  value       = module.github_oidc.workload_identity_provider
}

output "github_app_service_account" {
  description = "GitHub repo variable: GCP_APP_SERVICE_ACCOUNT"
  value       = module.github_oidc.app_service_account_email
}

output "github_infra_service_account" {
  description = "GitHub repo variable: GCP_INFRA_SERVICE_ACCOUNT"
  value       = module.github_oidc.infra_service_account_email
}

# --- A single block you can paste straight into GitHub ---------------------
output "github_variables_summary" {
  description = "All the GitHub repository variables you need, formatted for copy-paste."
  value       = <<-EOT

    Set these as GitHub repository VARIABLES (Settings > Secrets and variables
    > Actions > Variables). None of them are secret -- that is the whole point
    of Workload Identity Federation.

      GCP_PROJECT_ID                   = ${var.project_id}
      GCP_REGION                       = ${var.region}
      GCP_ZONE                         = ${var.zone}
      GKE_CLUSTER                      = ${module.gke.cluster_name}
      AR_REPOSITORY                    = ${var.artifact_repo_id}
      GCP_WORKLOAD_IDENTITY_PROVIDER   = ${module.github_oidc.workload_identity_provider}
      GCP_APP_SERVICE_ACCOUNT          = ${module.github_oidc.app_service_account_email}
      GCP_INFRA_SERVICE_ACCOUNT        = ${module.github_oidc.infra_service_account_email}
      TF_STATE_BUCKET                  = <the bucket you made in Chapter 02>

  EOT
}
