variable "project_id" {
  type = string
}

variable "account_id" {
  description = "Google service account ID, e.g. \"linkforge-api\". Becomes linkforge-api@PROJECT.iam.gserviceaccount.com."
  type        = string
}

variable "display_name" {
  type    = string
  default = ""
}

variable "project_roles" {
  description = "Project-level IAM roles granted to this service account, e.g. [\"roles/datastore.user\"]."
  type        = list(string)
  default     = []
}

variable "kubernetes_namespace" {
  description = "Namespace of the Kubernetes ServiceAccount allowed to impersonate this Google SA."
  type        = string
}

variable "kubernetes_service_account" {
  description = "Name of the Kubernetes ServiceAccount allowed to impersonate this Google SA."
  type        = string
}
