variable "project_id" {
  description = "GCP project ID. Needed to build the Workload Identity pool name."
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
}

variable "zone" {
  description = <<-EOT
    A single zone, e.g. "us-central1-a". Using a zone (not a region) creates a
    ZONAL cluster. That matters for money: GKE's free tier covers the
    $74.40/month control-plane management fee for ONE zonal or Autopilot
    cluster per billing account. A regional cluster is not covered.
  EOT
  type        = string
}

variable "network_id" { type = string }
variable "subnet_id" { type = string }

variable "pods_range_name" {
  description = "Name of the subnet secondary range used for Pod IPs."
  type        = string
}

variable "services_range_name" {
  description = "Name of the subnet secondary range used for Service ClusterIPs."
  type        = string
}

variable "node_count" {
  description = "Nodes in the primary pool. 2 lets you drain one node and watch Pods reschedule."
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "Node machine type. e2-small (2 shared vCPU / 2 GB) is plenty for this lab."
  type        = string
  default     = "e2-small"
}

variable "use_spot_nodes" {
  description = <<-EOT
    Spot VMs cost ~70% less but Google can reclaim them with 30 seconds notice.
    For a learning lab that is a feature, not a bug: it is a free lesson in
    graceful shutdown and Pod rescheduling. Set to false if a preempted node
    mid-demo would annoy you.
  EOT
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  description = "Node boot disk size. 30 GB pd-standard is the cheap end; the default of 100 GB pd-balanced would cost ~$10/node/month."
  type        = number
  default     = 30
}

variable "disk_type" {
  type    = string
  default = "pd-standard"
}

variable "master_ipv4_cidr_block" {
  description = "A /28 for the control plane's private endpoint. Must not overlap any other range."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = <<-EOT
    Who may reach the public control-plane endpoint. An EMPTY list (the default)
    means "anyone on the internet may reach the endpoint" -- they still need a
    valid Google identity and RBAC to do anything, but the endpoint answers.
    That is what lets GitHub-hosted runners (which have unpredictable IPs)
    run kubectl. Lock this down to your home IP once CI is not using it.
  EOT
  type = list(object({
    cidr = string
    name = string
  }))
  default = []
}

variable "release_channel" {
  description = "RAPID | REGULAR | STABLE. REGULAR is the sane default."
  type        = string
  default     = "REGULAR"
}

variable "node_service_account_email" {
  description = "Dedicated least-privilege service account for the nodes. Never use the default Compute Engine SA -- it has project Editor."
  type        = string
}

variable "resource_labels" {
  description = "Labels applied to the cluster, useful for billing breakdowns."
  type        = map(string)
  default     = {}
}
