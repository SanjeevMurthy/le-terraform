# ---------------------------------------------------------------------------
# Artifact Registry: where our container images live
# ---------------------------------------------------------------------------
# Artifact Registry replaced Container Registry (gcr.io). Images are addressed
# as:  REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY_ID/IMAGE:TAG
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Container images for the LinkForge 3-tier lab"

  # Cleanup policies are how you stay inside the 0.5 GB/month free tier.
  # Every push adds ~200 MB, so without this you would blow past it in a week.
  # KEEP rules always win over DELETE rules, so the two below mean:
  # "delete anything older than 30 days, UNLESS it is one of the 10 newest".
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_recent_versions
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }
}

# Least privilege: readers can only pull, writers can only push+pull.
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each   = toset(var.reader_members)
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each   = toset(var.writer_members)
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
