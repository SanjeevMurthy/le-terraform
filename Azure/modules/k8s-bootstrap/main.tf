locals {
  # Extract major.minor from the full version (e.g. 1.34.2 -> 1.34)
  k8s_major_minor = join(".", slice(split(".", var.kubernetes_version), 0, 2))

  # common bootstrap steps (install containerd + kubeadm components)
  common_setup_script = <<-SETUP
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
    
    # Load kernel modules for k8s
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF
    
    sudo modprobe overlay
    sudo modprobe br_netfilter
    
    # Sysctl params required by setup, params persist across reboots
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
    
    # Apply sysctl params without reboot
    sudo sysctl --system

    # Install Kubernetes apt repo and packages
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${local.k8s_major_minor}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${local.k8s_major_minor}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

    apt-get update -y
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable kubelet || true
  SETUP

  master_setup_script = <<-SETUP
    ${local.common_setup_script}

    # Initialize Master
    echo "Running kubeadm init..."
    # We need to detect if already initialized to be safe on re-runs
    if [ ! -f /etc/kubernetes/admin.conf ]; then
      kubeadm init --pod-network-cidr=${var.pod_network_cidr} --kubernetes-version=${var.kubernetes_version} --ignore-preflight-errors=NumCPU
      
      # Patch manifests to increase liveness probe timeouts (fix for slow VMs)
      sed -i 's/initialDelaySeconds: 10/initialDelaySeconds: 60/g' /etc/kubernetes/manifests/etcd.yaml
      sed -i 's/timeoutSeconds: 15/timeoutSeconds: 30/g' /etc/kubernetes/manifests/etcd.yaml
      sed -i 's/initialDelaySeconds: 10/initialDelaySeconds: 60/g' /etc/kubernetes/manifests/kube-apiserver.yaml
      # Restart kubelet to apply changes immediately
      systemctl restart kubelet
    fi

    # Setup kubeconfig for root
    mkdir -p /root/.kube
    cp -i /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config

    # Setup kubeconfig for admin user
    mkdir -p /home/${var.admin_user}/.kube
    cp -i /etc/kubernetes/admin.conf /home/${var.admin_user}/.kube/config
    chown ${var.admin_user}:${var.admin_user} /home/${var.admin_user}/.kube/config

    # Install Flannel
    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml --kubeconfig /root/.kube/config

    # Generate join command
    kubeadm token create --print-join-command > /tmp/join_command.txt
  SETUP
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

resource "local_file" "cloud_init_master" {
  content  = base64encode(local.master_setup_script)
  filename = "${path.module}/cloud_init_master.b64"
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

echo "Waiting for join command to be ready on $${HOST}..."
# We wait up to 10 minutes (60 * 10s) for cloud-init to finish and generate the token
for i in $(seq 1 60); do
  # Check if file exists on remote
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=5 -i "$${KEY}" "$${USER}@$${HOST}" 'test -f /tmp/join_command.txt' && break
  echo "Join command not ready yet... sleeping 10s"
  sleep 10
done

# Download the join command
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=5 -i "$${KEY}" "$${USER}@$${HOST}" "cat /tmp/join_command.txt" > "$${OUTFILE}"

echo "Join command captured in $${OUTFILE}"
EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# read join command file produced above (if exists)
# We use 'external' data source with a python script to avoid "file not found" errors during plan
# when the file doesn't exist yet. data.local_file is too eager.
data "external" "join_command" {
  count = var.is_master ? 1 : 0

  program = ["python3", "-c", <<EOT
import json
import os
import sys
filename = sys.argv[1]
if os.path.exists(filename):
    with open(filename, 'r') as f:
        content = f.read().strip()
    print(json.dumps({'command': content}))
else:
    print(json.dumps({'command': ''}))
EOT
  , "${path.module}/join_command.txt"]

  depends_on = [null_resource.master_init_runner]
}
