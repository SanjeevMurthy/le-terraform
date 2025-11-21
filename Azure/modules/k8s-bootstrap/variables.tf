variable "is_master" {
  description = "Whether this node is the master"
  type        = bool
}

variable "master_public_ip" {
  description = "Public IP of master (required when is_master = true for provisioning)"
  type        = string
  default     = ""
}

variable "master_private_ip" {
  description = "Private IP of master (used by kubeadm join)"
  type        = string
  default     = ""
}

variable "admin_user" {
  type    = string
  default = "azureuser"
}

variable "ssh_private_key_path" {
  description = "Path to the private key used by Terraform to SSH to master for kubeadm init"
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  type    = string
  default = "1.30.0"
}

variable "pod_network_cidr" {
  type    = string
  default = "10.244.0.0/16"
}

variable "join_command" {
  description = "(Optional) join command passed to worker from root module"
  type        = string
  default     = ""
}
