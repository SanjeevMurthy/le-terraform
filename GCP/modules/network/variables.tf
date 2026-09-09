variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "region" {
  description = "Region for the subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR for the node subnet. Nodes get their IPs from here."
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary CIDR used for Pod IPs (VPC-native / alias IP ranges)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR used for Kubernetes Service ClusterIPs."
  type        = string
  default     = "10.30.0.0/20"
}

variable "enable_cloud_nat" {
  description = <<-EOT
    Create a Cloud Router + Cloud NAT so private nodes can reach the public
    internet. LEAVE THIS FALSE unless you need it: Cloud NAT costs roughly
    $32/month. LinkForge does not need it, because every service the nodes
    talk to (Artifact Registry, Firestore, Cloud Logging) is a Google API
    reachable through Private Google Access, which is free.
  EOT
  type        = bool
  default     = false
}
