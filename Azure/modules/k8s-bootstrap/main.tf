locals {
  # common bootstrap steps (install containerd + kubeadm components)
  common_setup_script = <<-EOF
    #!/bin/bash
    set -eux

    # Basic prerequisites
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    # Install containerd
    apt-get install -y containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml || true
    systemctl restart containerd || true
    systemctl enable containerd || true

    # Install Kubernetes apt repo and packages
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] http://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list

    apt-get update -y
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable kubelet || true
  EOF
}

# cloud-init that will run on both master and worker to prepare the node (but NOT run kubeadm init/join here)
resource "local_file" "cloud_init_base" {
  content  = base64encode(local.common_setup_script)
  filename = "${path.module}/cloud_init_base.b64"
}

# Output cloud-init for the VM modules
# Master cloud-init will only run the common setup.
# The actual kubeadm init/join will be executed later via SSH provisioner (for master) or by injecting join command into worker cloud-init.
resource "local_file" "cloud_init_for_vm" {
  count    = 1
  content  = base64encode(local.common_setup_script)
  filename = "${path.module}/cloud_init_for_vm.txt"
}

# -------- MASTER post-provision step: run kubeadm init on master (only when is_master = true) --------
# We use a null_resource + local-exec that SSHes into the master and runs kubeadm init,
# then runs `kubeadm token create --print-join-command` and writes it to a local file.
resource "null_resource" "master_init_runner" {
  count = var.is_master ? 1 : 0

  # When these change re-run
  triggers = {
    master_public_ip     = var.master_public_ip
    ssh_private_key_path = var.ssh_private_key_path
    kubernetes_version   = var.kubernetes_version
    pod_network_cidr     = var.pod_network_cidr
  }

  provisioner "local-exec" {
    command     = <<EOT
set -e
KEY="${var.ssh_private_key_path}"
USER="${var.admin_user}"
HOST="${var.master_public_ip}"
OUTFILE="${path.module}/join_command.txt"

# wait for SSH to be ready (simple loop)
echo "Waiting for SSH on $${HOST}..."
for i in $(seq 1 60); do
  ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" 'echo ok' >/dev/null 2>&1 && break
  echo "SSH not ready yet... sleeping 5s"
  sleep 5
done

# Detect if master is already initialized (check /etc/kubernetes/admin.conf)
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" 'sudo test -f /etc/kubernetes/admin.conf' && {
  echo "Master already initialized — generating join command only"
  ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" "sudo kubeadm token create --print-join-command" > "$${OUTFILE}"
  exit 0
}

# Run kubeadm init (only if not already initialized)
echo "Running kubeadm init on master $${HOST}..."
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" <<'SSH_EOF'
set -eux
# ensure swap off and configured
sudo swapoff -a || true
sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

# initialize control plane
sudo kubeadm init --pod-network-cidr=${pod_cidr} --kubernetes-version=${k8s_ver}
# (the variables above are replaced by the wrapper below)
SSH_EOF

# Because we used a heredoc on the client, re-run init with variable substitution:
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" "sudo kubeadm init --pod-network-cidr=${var.pod_network_cidr} --kubernetes-version=${var.kubernetes_version}"

# Copy admin.conf to root so kubectl works
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" "sudo mkdir -p /root/.kube && sudo cp -i /etc/kubernetes/admin.conf /root/.kube/config && sudo chown root:root /root/.kube/config"

# Install a pod network (flannel) — optionally adapt to your preferred CNI
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" "sudo /bin/bash -lc 'kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml'"

# Generate and capture the join command
ssh -o StrictHostKeyChecking=no -i "$${KEY}" "$${USER}@$${HOST}" "sudo kubeadm token create --print-join-command" > "$${OUTFILE}"

echo "Join command captured in $${OUTFILE}"
EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# read join command file produced above (if exists)
data "local_file" "join_command_file" {
  filename = "${path.module}/join_command.txt"
  # this data source will only exist after null_resource writes the file. If it doesn't exist,
  # Terraform may error — but because null_resource is only created when is_master=true, and the
  # worker modules depend on master output, order is enforced by the root module triggers
  # (see explanation).
  # If you need robustness, add wrapper logic in root to only pass join_command when file exists.
  depends_on = [null_resource.master_init_runner]
}


