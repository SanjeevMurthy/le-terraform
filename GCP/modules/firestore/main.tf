# ---------------------------------------------------------------------------
# Firestore in Native mode -- our Tier 3 (data tier)
# ---------------------------------------------------------------------------
# Why Firestore instead of Cloud SQL for this lab:
#   * Always Free tier: 1 GiB stored, 50k reads/day, 20k writes/day. LinkForge
#     will never come close, so the data tier costs $0.
#   * Serverless: no VPC peering, no private IP, no Cloud SQL Auth Proxy
#     sidecar, no database password to store and rotate.
#   * Access is pure IAM, which lets us demonstrate GKE Workload Identity
#     cleanly: the Pod gets a Google identity, no keys anywhere.
#
# Every project gets exactly one database named "(default)". The parentheses
# are part of the literal name -- that is not a typo.
resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.location_id
  type        = "FIRESTORE_NATIVE"

  # Without this, "terraform destroy" leaves the database behind and fails.
  deletion_policy = var.deletion_policy
}
