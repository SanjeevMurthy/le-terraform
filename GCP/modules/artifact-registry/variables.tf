variable "repository_id" {
  description = "Name of the Docker repository, e.g. \"linkforge\"."
  type        = string
}

variable "region" {
  description = "Region that hosts the repository. Keep it equal to your cluster region so image pulls stay in-region and free."
  type        = string
}

variable "keep_recent_versions" {
  description = "How many recent image versions to keep. Keeps you inside the 0.5 GB Artifact Registry free tier."
  type        = number
  default     = 10
}

variable "reader_members" {
  description = "IAM members granted read (pull) access, e.g. the GKE node service account."
  type        = list(string)
  default     = []
}

variable "writer_members" {
  description = "IAM members granted write (push) access, e.g. the GitHub Actions service account."
  type        = list(string)
  default     = []
}
