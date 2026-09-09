# ---------------------------------------------------------------------------
# GKE Standard cluster (zonal, private nodes, VPC-native, Workload Identity)
# ---------------------------------------------------------------------------
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone # a ZONE, not a region -> zonal cluster -> free tier applies

  network    = var.network_id
  subnetwork = var.subnet_id

  # Terraform cannot create a cluster with zero node pools, so GKE makes a
  # default one and we immediately throw it away and manage our own pool as a
  # separate resource. That separation lets us change machine types later
  # without recreating the whole cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  # VPC-native: Pods get real VPC IPs from the "pods" secondary range.
  # Required for container-native load balancing (NEGs), which our Ingress uses.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Private nodes: no external IPs on the VMs.
  #   - Saves ~$3.60/node/month in IPv4 charges.
  #   - Nodes still reach Artifact Registry / Firestore / Logging through
  #     Private Google Access (enabled on the subnet), so no Cloud NAT needed.
  #   - Trade-off: nodes CANNOT reach the public internet. Pulling an image
  #     straight from Docker Hub will fail with ImagePullBackOff. That is
  #     expected -- push it to Artifact Registry first.
  #
  # enable_private_endpoint = false keeps a PUBLIC control-plane endpoint so
  # your laptop and GitHub-hosted runners can run kubectl without a bastion.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block   = cidr_blocks.value.cidr
          display_name = cidr_blocks.value.name
        }
      }
    }
  }

  # Workload Identity: the mechanism that lets a Kubernetes ServiceAccount
  # impersonate a Google service account. This is why there is not a single
  # credential file anywhere in this project.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = var.release_channel
  }

  addons_config {
    http_load_balancing {
      disabled = false # required for the GKE Ingress controller
    }
    horizontal_pod_autoscaling {
      disabled = false # required for the HPA in the Day-2 chapter
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false # keeps the metrics bill at zero for this lab
    }
  }

  # Free, and it makes per-namespace cost visible in the billing console.
  cost_management_config {
    enabled = true
  }

  resource_labels = var.resource_labels

  # The google provider defaults this to TRUE, and it will block
  # "terraform destroy" with a confusing error. For a lab, set it to false NOW
  # so teardown day is not a fight.
  deletion_protection = false
}

# ---------------------------------------------------------------------------
# Primary node pool
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "primary" {
  name       = "primary"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = var.disk_type
    spot         = var.use_spot_nodes

    service_account = var.node_service_account_email
    # With a dedicated least-privilege SA the modern practice is to grant the
    # broad cloud-platform scope and let IAM roles do the actual restricting.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # GKE_METADATA turns on the Workload Identity metadata server on the node
    # and BLOCKS Pods from reading the raw VM metadata endpoint. Without this,
    # any Pod could steal the node's service account token.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role = "app"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # max_surge = 1 / max_unavailable = 0 means upgrades add a node first, then
  # drain an old one. Zero downtime, one extra node's cost for a few minutes.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [
      # Node pool versions drift as GKE auto-upgrades. Ignoring this stops
      # every plan from showing a phantom change.
      version,
    ]
  }
}
