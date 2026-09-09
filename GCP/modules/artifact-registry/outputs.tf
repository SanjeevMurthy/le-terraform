output "repository_name" {
  description = "Short name of the repository."
  value       = google_artifact_registry_repository.docker.repository_id
}

output "registry_host" {
  description = "Docker registry hostname, e.g. us-central1-docker.pkg.dev."
  value       = "${var.region}-docker.pkg.dev"
}

output "repository_url" {
  description = "Prefix you tag images with, e.g. us-central1-docker.pkg.dev/my-project/linkforge."
  value       = "${var.region}-docker.pkg.dev/${google_artifact_registry_repository.docker.project}/${google_artifact_registry_repository.docker.repository_id}"
}
