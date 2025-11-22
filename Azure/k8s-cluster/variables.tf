variable "location" {
  default = "eastus"
}

variable "admin_user" {
  default = "azureuser"
}

# variable "ssh_public_key" {
#   description = "Path to SSH public key"
#   default     = "~/.ssh/id_rsa.pub"
# }

variable "master_vm_size" {
  default = "Standard_B2s"
}

variable "worker_vm_size" {
  default = "Standard_B1ms"
}

variable "worker_count" {
  default = 2
}

variable "resource_group" {
  default = "rg-learning-k8s"
}
