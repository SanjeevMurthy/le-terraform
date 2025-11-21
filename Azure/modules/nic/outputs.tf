output "nic_id" {
  value = azurerm_network_interface.nic.id
}

output "private_ip" {
  value = azurerm_network_interface.nic.private_ip_address
}

output "public_ip" {
  value = var.create_public_ip ? azurerm_public_ip.nic_public_ip[0].ip_address : null
}
