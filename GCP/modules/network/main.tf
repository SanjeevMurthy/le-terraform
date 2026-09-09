# ---------------------------------------------------------------------------
# Custom VPC
# ---------------------------------------------------------------------------
# auto_create_subnetworks = false means "do not create a subnet in every region
# for me". We want exactly one subnet that we control, in one region.
resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC for the LinkForge 3-tier lab"
}

# ---------------------------------------------------------------------------
# Subnet with secondary ranges (VPC-native GKE)
# ---------------------------------------------------------------------------
# A VPC-native cluster gives Pods real routable VPC IPs from a secondary range
# instead of an overlay network. This is what makes container-native load
# balancing (NEGs) possible, which is what the Ingress in this lab uses.
#
# private_ip_google_access = true is the single most important line in this
# file for your bill. It lets VMs WITHOUT an external IP reach Google APIs
# (Artifact Registry, Firestore, Logging) over Google's internal network.
# Without it we would need Cloud NAT (~$32/month) just to pull our own images.
resource "google_compute_subnetwork" "nodes" {
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# ---------------------------------------------------------------------------
# OPTIONAL: Cloud NAT (off by default -- costs money)
# ---------------------------------------------------------------------------
# Flip enable_cloud_nat to true only if you need your Pods to reach the public
# internet (e.g. pulling an image straight from Docker Hub, or calling a
# third-party API). Remember to flip it back off.
resource "google_compute_router" "nat_router" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "${var.name_prefix}-nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count                              = var.enable_cloud_nat ? 1 : 0
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.nat_router[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}
