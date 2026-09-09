# ---------------------------------------------------------------------------
# Workload Identity Federation: GitHub Actions -> GCP, with no stored key
# ---------------------------------------------------------------------------
# This is the GCP equivalent of the Azure OIDC setup already in this repo.
#
# How it works:
#   1. GitHub Actions mints a short-lived OIDC token describing the run
#      (which repo, which branch, which workflow).
#   2. GCP's Security Token Service validates that token against GitHub's
#      public keys, checks our attribute_condition, and swaps it for a
#      federated token.
#   3. That federated token is used to impersonate a Google service account.
#
# Nothing secret is stored in GitHub. There is no JSON key to leak, and
# tokens expire in minutes.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "Federated identities for GitHub Actions workflows"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"

  # THE MOST IMPORTANT LINE IN THIS FILE.
  # Without an attribute_condition, ANY GitHub repository on the planet could
  # mint a token and assume your service account. Google now refuses to create
  # a provider without one. We pin it to exactly one repo.
  attribute_condition = "assertion.repository == '${var.github_owner}/${var.github_repo}'"

  # Map claims from GitHub's token into attributes we can write IAM conditions
  # against. attribute.repository is the one we bind on below.
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.workflow"         = "assertion.workflow"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------------------
# Two service accounts, because the two pipelines need very different power
# ---------------------------------------------------------------------------
# Splitting these means a compromised app-deploy workflow cannot delete your
# VPC. This is the single highest-value security decision in the whole lab.

resource "google_service_account" "app" {
  account_id   = "github-app-deployer"
  display_name = "GitHub Actions - application deploys"
  description  = "Builds images and rolls out Deployments. Cannot change infrastructure."
}

resource "google_service_account" "infra" {
  account_id   = "github-infra"
  display_name = "GitHub Actions - Terraform infrastructure"
  description  = "Runs terraform plan/apply/destroy."
}

resource "google_project_iam_member" "app_roles" {
  for_each = toset(var.app_sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "infra_roles" {
  for_each = toset(var.infra_sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.infra.email}"
}

# ---------------------------------------------------------------------------
# The trust bindings: which federated principals may impersonate which SA
# ---------------------------------------------------------------------------
# principalSet://.../attribute.repository/OWNER/REPO means
# "any workflow run in this repository". You can tighten further to a single
# branch with attribute.ref -- see the commented example below.

locals {
  repo_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_owner}/${var.github_repo}"
}

resource "google_service_account_iam_member" "app_wif" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.repo_principal
}

resource "google_service_account_iam_member" "infra_wif" {
  service_account_id = google_service_account.infra.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.repo_principal

  # Tighter alternative -- only runs on the main branch may impersonate the
  # infrastructure SA. Requires attribute.ref in attribute_mapping (it is).
  #
  #   member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.ref/refs/heads/main"
}
