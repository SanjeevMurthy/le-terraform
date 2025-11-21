variable "name" {}
variable "location" {}
variable "resource_group" {}
variable "subnet_id" {}
variable "create_public_ip" {
  type    = bool
  default = false
}
