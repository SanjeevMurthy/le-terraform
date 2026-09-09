variable "project_id" {
  type = string
}

variable "project_number" {
  description = "Numeric project number (NOT the project ID). Needed to build the provider resource name GitHub Actions references."
  type        = string
}

variable "pool_id" {
  type    = string
  default = "github-pool"
}

variable "provider_id" {
  type    = string
  default = "github-provider"
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo, e.g. \"SanjeevMurthy\"."
  type        = string
}

variable "github_repo" {
  description = "Repository name only, e.g. \"le-terraform\"."
  type        = string
}

variable "app_sa_roles" {
  description = "Roles for the DEPLOY pipeline SA. Deliberately narrow: push images, talk to the cluster."
  type        = list(string)
  default = [
    "roles/container.developer",
  ]
}

variable "infra_sa_roles" {
  description = <<-EOT
    Roles for the INFRASTRUCTURE pipeline SA. These are broad on purpose for a
    lab -- this SA creates VPCs, clusters, service accounts and IAM bindings.
    In production you would replace roles/editor with a curated list, or run
    infra applies from a separate, tightly controlled project.
  EOT
  type        = list(string)
  default = [
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/storage.admin",
    "roles/container.admin",
  ]
}
