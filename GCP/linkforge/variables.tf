# ---------------------------------------------------------------------------
# Identity of the project
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Your GCP project ID, e.g. linkforge-lab-1234."
  type        = string
}

variable "region" {
  description = "Region for the subnet, Artifact Registry and Firestore."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the GKE cluster. Must be inside var.region. A zonal cluster is what the GKE free tier covers."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Prefix for resource names, so everything is easy to spot and easy to delete."
  type        = string
  default     = "linkforge"
}

# ---------------------------------------------------------------------------
# Cluster sizing (this is where your bill is decided)
# ---------------------------------------------------------------------------
variable "node_count" {
  type    = number
  default = 2
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "use_spot_nodes" {
  description = "Spot nodes are ~70% cheaper. True is the right answer for a lab."
  type        = bool
  default     = true
}

variable "enable_cloud_nat" {
  description = "Leave false. See GCP/modules/network/variables.tf for why."
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "Empty list = control-plane endpoint reachable from anywhere (still IAM-protected). Needed for GitHub-hosted runners."
  type = list(object({
    cidr = string
    name = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Application wiring
# ---------------------------------------------------------------------------
variable "artifact_repo_id" {
  description = "Artifact Registry repository name."
  type        = string
  default     = "linkforge"
}

variable "firestore_location" {
  description = "Firestore location. CANNOT be changed after creation."
  type        = string
  default     = "us-central1"
}

variable "kubernetes_namespace" {
  description = "Namespace the app runs in. Must match k8s/00-namespace.yaml."
  type        = string
  default     = "linkforge"
}

variable "api_service_account_name" {
  description = "Kubernetes ServiceAccount the API Pods use. Must match k8s/10-api-serviceaccount.yaml."
  type        = string
  default     = "linkforge-api"
}

# ---------------------------------------------------------------------------
# CI/CD (used from Chapter 08 onwards)
# ---------------------------------------------------------------------------
variable "github_owner" {
  description = "GitHub user or org that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name only, no owner prefix."
  type        = string
}
