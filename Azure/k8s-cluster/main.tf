terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

# -------------------------------
# Resource Group
# -------------------------------
data "azurerm_resource_group" "k8s_rg" {
  name = var.resource_group
  #location = var.location
}

# -------------------------------
# VNet + Subnet
# -------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "k8s-vnet"
  address_space       = ["10.10.0.0/16"]
  location            = var.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "k8s-subnet"
  resource_group_name  = data.azurerm_resource_group.k8s_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

# -------------------------------
# NSG
# -------------------------------
resource "azurerm_network_security_group" "nsg" {
  name                = "k8s-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Associate NSG with subnet
resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}




# -------------------------------
# K8S BOOTSTRAP (Master Init)
# -------------------------------
module "k8s_bootstrap" {
  source               = "../modules/k8s-bootstrap"
  is_master            = true
  master_public_ip     = module.master_nic.public_ip
  ssh_private_key_path = var.ssh_private_key_path
  admin_user           = var.admin_user
}

module "master_nic" {
  source           = "../modules/nic"
  name             = "master-nic"
  location         = var.location
  resource_group   = data.azurerm_resource_group.k8s_rg.name
  subnet_id        = azurerm_subnet.subnet.id
  create_public_ip = true
}

# -------------------------------
# MASTER VM
# -------------------------------
module "master_vm" {
  source         = "../modules/vm"
  name           = "k8s-master"
  location       = var.location
  resource_group = data.azurerm_resource_group.k8s_rg.name

  nic_id         = module.master_nic.nic_id
  vm_size        = var.master_vm_size
  admin_username = var.admin_user
  ssh_public_key = var.ssh_public_key

  # Cloud-init: just the common setup
  custom_data = module.k8s_bootstrap.cloud_init_master_b64
}

# -------------------------------
# WORKER NICS
# -------------------------------
module "worker_nics" {
  count            = var.worker_count
  source           = "../modules/nic"
  name             = "worker-nic-${count.index}"
  location         = var.location
  resource_group   = data.azurerm_resource_group.k8s_rg.name
  subnet_id        = azurerm_subnet.subnet.id
  create_public_ip = false
}

# -------------------------------
# WORKER VMs
# -------------------------------
module "worker_vms" {
  count  = var.worker_count
  source = "../modules/vm"

  name           = "k8s-worker-${count.index}"
  location       = var.location
  resource_group = data.azurerm_resource_group.k8s_rg.name

  nic_id         = module.worker_nics[count.index].nic_id
  vm_size        = var.worker_vm_size
  admin_username = var.admin_user
  ssh_public_key = var.ssh_public_key

  # Cloud-init: common setup + join command
  custom_data = base64encode(<<EOF
${module.k8s_bootstrap.common_setup_script}

# Join the cluster
${module.k8s_bootstrap.join_command}
EOF
  )
}
