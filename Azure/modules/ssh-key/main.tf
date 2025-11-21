# 1. Generate SSH keypair
resource "tls_private_key" "generated" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 2. Store private key in specified local path
resource "local_file" "private_key" {
  content         = tls_private_key.generated.private_key_pem
  filename        = var.private_key_path
  file_permission = "0600"
}

