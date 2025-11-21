output "public_key" {
  value = tls_private_key.generated.public_key_openssh
}

output "private_key" {
  value     = tls_private_key.generated.private_key_pem
  sensitive = true
}

output "private_key_path" {
  value = local_file.private_key.filename
}
