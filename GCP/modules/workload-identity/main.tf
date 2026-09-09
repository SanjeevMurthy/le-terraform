# ---------------------------------------------------------------------------
# Workload Identity: give a Kubernetes Pod a real Google identity
# ---------------------------------------------------------------------------
# The chain is:
#
#   Pod  --uses-->  KubernetesServiceAccount (KSA)
#                     |  annotated with the Google SA's email
#                     v
#                   GoogleServiceAccount (GSA)
#                     |  granted roles/datastore.user
#                     v
#                   Firestore
#
# Two halves have to line up or it silently fails with a 403:
#   1. HERE (Terraform): the GSA trusts the KSA via roles/iam.workloadIdentityUser
#   2. IN KUBERNETES: the KSA is annotated with iam.gke.io/gcp-service-account
#
# Result: no JSON key is ever created, downloaded, committed, or rotated.

resource "google_service_account" "this" {
  account_id   = var.account_id
  display_name = var.display_name != "" ? var.display_name : var.account_id
  description  = "Runtime identity for Pods using KSA ${var.kubernetes_namespace}/${var.kubernetes_service_account}"
}

resource "google_project_iam_member" "roles" {
  for_each = toset(var.project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.this.email}"
}

# The trust half. The member string format is exact and unforgiving:
#   serviceAccount:PROJECT_ID.svc.id.goog[NAMESPACE/KSA_NAME]
resource "google_service_account_iam_member" "workload_identity_user" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.kubernetes_namespace}/${var.kubernetes_service_account}]"
}
