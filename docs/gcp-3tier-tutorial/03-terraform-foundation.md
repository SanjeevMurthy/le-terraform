# Chapter 03 — Terraform: The Foundation

⏱ ~30 minutes, of which about 3 are Terraform waiting.

In this chapter you build the network, the image registry, the database and
the cluster's identity. Everything except the cluster itself, which is
Chapter 04 because it takes ten minutes to create and you should not be
debugging six things at once while it does.

---

## Step 3.0 — How this stack is organised

**What we're doing.** Understanding the shape before writing the files.

```
GCP/
├── modules/                 reusable building blocks, each with one job
│   ├── network/             VPC + subnet + (optional) NAT
│   ├── artifact-registry/   Docker repository + its IAM
│   ├── firestore/           the database
│   ├── gke/                 the cluster            [Chapter 04]
│   ├── workload-identity/   Pod identity           [Chapter 04]
│   └── github-oidc/         CI identity            [Chapter 08]
└── linkforge/               the ROOT STACK -- the only place you run terraform
    ├── backend.tf           where state lives
    ├── providers.tf         which providers, which versions
    ├── variables.tf         the knobs
    ├── main.tf              wires the modules together
    └── outputs.tf           values you need in later chapters
```

**Why modules.** A module is a folder of Terraform with inputs (variables) and
outputs. Three reasons they earn their keep here:

1. **A blast radius you can reason about.** `modules/network` cannot
   accidentally change your cluster, because it does not know it exists.
2. **Reuse.** The same `gke` module could build a staging cluster with
   different variables and no copy-paste.
3. **Readability.** `main.tf` reads as a list of *what* you are building.
   *How* each thing is built stays inside its module.

This mirrors how `Azure/` and `AWS/` are laid out in this repository.

**Why one root stack rather than several.** Splitting infrastructure into
separately-applied stacks (network / platform / app) is common at scale, and
it means passing values between them via remote state data sources. That is a
real technique, but it is a lot of ceremony for a lab. One root stack, applied
three times as you add to it, teaches the same Terraform and none of the
plumbing.

---

## Step 3.1 — Provider and backend configuration

**What we're doing.** Telling Terraform which cloud provider to use, pinning
its version, and pointing it at the state bucket from Chapter 02.

**Create `GCP/linkforge/providers.tf`:**

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Looks up the numeric project number, which Workload Identity Federation
# resource names require. Saves you from having to paste it into a variable.
data "google_project" "this" {
  project_id = var.project_id
}
```

**Why pin the version.** `version = "~> 6.0"` means "any 6.x, never 7.0". Cloud
providers make breaking changes in major versions. Without a pin, a colleague
running `terraform init` next month gets a different provider than you, and
your identical configuration produces a different plan.

**Why the `data "google_project"` block.** Workload Identity Federation
resource names need your project *number* (a long integer), not your project
*ID* (the string you chose). Looking it up here means one less thing to
copy-paste wrong later.

**Create `GCP/linkforge/backend.tf`:**

```hcl
# ---------------------------------------------------------------------------
# Remote state in a GCS bucket
# ---------------------------------------------------------------------------
# Deliberately EMPTY ("partial configuration"). The bucket name is not a
# secret, but hard-coding it means this file cannot be reused and every
# contributor must edit it. Instead we pass it at init time:
#
#   terraform init \
#     -backend-config="bucket=$TF_STATE_BUCKET" \
#     -backend-config="prefix=linkforge"
#
# This is the same pattern as the Azure stack in this repo.
terraform {
  backend "gcs" {}
}
```

**Why the empty block.** This is Terraform's "partial backend configuration".
The bucket name is supplied at `init` time instead of being hard-coded, so the
same code works for your bucket, a colleague's, and CI's. It is also exactly
the pattern the `Azure/k8s-cluster` stack in this repo already uses.

---

## Step 3.2 — The variables

**What we're doing.** Declaring every knob the stack exposes, with sensible
defaults, so `main.tf` reads cleanly and cost-relevant settings are in one
obvious place.

**Create `GCP/linkforge/variables.tf`:**

```hcl
# ---------------------------------------------------------------------------
# Identity of the project
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Your GCP project ID, e.g. linkforge-lab-1234."
  type        = string
}

variable "region" {
  description = "Region for the subnet, Artifact Registry and Firestore."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the GKE cluster. Must be inside var.region. A zonal cluster is what the GKE free tier covers."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Prefix for resource names, so everything is easy to spot and easy to delete."
  type        = string
  default     = "linkforge"
}

# ---------------------------------------------------------------------------
# Cluster sizing (this is where your bill is decided)
# ---------------------------------------------------------------------------
variable "node_count" {
  type    = number
  default = 2
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "use_spot_nodes" {
  description = "Spot nodes are ~70% cheaper. True is the right answer for a lab."
  type        = bool
  default     = true
}

variable "enable_cloud_nat" {
  description = "Leave false. See GCP/modules/network/variables.tf for why."
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "Empty list = control-plane endpoint reachable from anywhere (still IAM-protected). Needed for GitHub-hosted runners."
  type = list(object({
    cidr = string
    name = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Application wiring
# ---------------------------------------------------------------------------
variable "artifact_repo_id" {
  description = "Artifact Registry repository name."
  type        = string
  default     = "linkforge"
}

variable "firestore_location" {
  description = "Firestore location. CANNOT be changed after creation."
  type        = string
  default     = "us-central1"
}

variable "kubernetes_namespace" {
  description = "Namespace the app runs in. Must match k8s/00-namespace.yaml."
  type        = string
  default     = "linkforge"
}

variable "api_service_account_name" {
  description = "Kubernetes ServiceAccount the API Pods use. Must match k8s/10-api-serviceaccount.yaml."
  type        = string
  default     = "linkforge-api"
}

# ---------------------------------------------------------------------------
# CI/CD (used from Chapter 08 onwards)
# ---------------------------------------------------------------------------
variable "github_owner" {
  description = "GitHub user or org that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name only, no owner prefix."
  type        = string
}
```

**Why defaults on almost everything.** Only `project_id`, `github_owner` and
`github_repo` have no default, so Terraform will refuse to run without them.
Everything else has a working value, which means a new person can get going by
setting three things instead of fifteen.

**Now create your `terraform.tfvars`:**

```bash
cd GCP/linkforge
cp terraform.tfvars.example terraform.tfvars
```

Edit it and fill in your real `project_id`, `github_owner` and `github_repo`.
The example file:

```hcl
# Copy to terraform.tfvars and fill in. terraform.tfvars is gitignored.
#
#   cp terraform.tfvars.example terraform.tfvars

project_id = "REPLACE-ME-linkforge-lab-1234"
region     = "us-central1"
zone       = "us-central1-a"

github_owner = "REPLACE-ME"
github_repo  = "le-terraform"

# --- cost knobs -----------------------------------------------------------
node_count     = 2
machine_type   = "e2-small"
use_spot_nodes = true

# Costs ~$32/month. Only turn on if your Pods must reach the public internet.
enable_cloud_nat = false

# Lock the control plane to your own IP once CI is not using kubectl.
# Find your IP with: curl -s ifconfig.me
# master_authorized_cidrs = [
#   { cidr = "203.0.113.7/32", name = "home" },
# ]
```

> `*.tfvars` is already in this repo's `.gitignore`. That is deliberate: a
> tfvars file is where people put things that should not be committed.

---

## Step 3.3 — The network module

**What we're doing.** Creating a VPC with one subnet, carrying three IP
ranges: one for node VMs, one for Pods, one for Services.

**Why three ranges.** A **VPC-native** cluster gives every Pod a real,
routable VPC IP address from a secondary range, instead of hiding Pods behind
an overlay network. That matters for three concrete reasons:

- The load balancer can send traffic **straight to Pod IPs** (container-native
  load balancing). Without it, traffic hits a node port and kube-proxy makes a
  second hop to a random Pod — extra latency, and the real client IP is lost.
- Firewall rules can target Pods directly.
- It is required for the NEG-based Ingress we build in Chapter 07.

**Why `private_ip_google_access = true` is the most important line here.**
Our nodes will have **no external IP addresses**. Normally that means they
cannot reach anything outside the VPC — including Artifact Registry, so they
could not pull the very images we are about to build. The usual fix is Cloud
NAT, which costs about **$32/month**.

But every single thing our nodes need to talk to is a *Google API*: Artifact
Registry, Firestore, Cloud Logging. Private Google Access routes exactly those
calls over Google's internal network, for free. So we get private nodes and no
NAT bill.

The trade-off is real and you will meet it: **Pods cannot reach the public
internet.** `kubectl run test --image=nginx` will sit in `ImagePullBackOff`
forever, because Docker Hub is not a Google API. That is not a bug. Push
images to Artifact Registry, or flip `enable_cloud_nat = true` for an hour
when you genuinely need egress.

**Create `GCP/modules/network/variables.tf`:**

```hcl
variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "region" {
  description = "Region for the subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR for the node subnet. Nodes get their IPs from here."
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary CIDR used for Pod IPs (VPC-native / alias IP ranges)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR used for Kubernetes Service ClusterIPs."
  type        = string
  default     = "10.30.0.0/20"
}

variable "enable_cloud_nat" {
  description = <<-EOT
    Create a Cloud Router + Cloud NAT so private nodes can reach the public
    internet. LEAVE THIS FALSE unless you need it: Cloud NAT costs roughly
    $32/month. LinkForge does not need it, because every service the nodes
    talk to (Artifact Registry, Firestore, Cloud Logging) is a Google API
    reachable through Private Google Access, which is free.
  EOT
  type        = bool
  default     = false
}
```

**Create `GCP/modules/network/main.tf`:**

```hcl
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
```

**Create `GCP/modules/network/outputs.tf`:**

```hcl
output "network_id" {
  description = "Full resource ID of the VPC, consumed by the GKE module."
  value       = google_compute_network.vpc.id
}

output "network_name" {
  description = "Short name of the VPC."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "Full resource ID of the node subnet."
  value       = google_compute_subnetwork.nodes.id
}

output "subnet_name" {
  description = "Short name of the node subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the secondary range GKE will use for Pod IPs."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range GKE will use for Service ClusterIPs."
  value       = "services"
}

output "cloud_nat_enabled" {
  description = "Whether the (billable) Cloud NAT gateway is currently deployed."
  value       = var.enable_cloud_nat
}
```

**Why the CIDR sizes.** `10.20.0.0/16` for Pods looks enormous for a two-node
lab, and it is — but Pod range sizing is **permanent**. GKE carves a `/24`
(256 IPs) out of it per node by default, so a `/16` supports 256 nodes. Ranges
cannot be resized after the cluster is created, and running out means
rebuilding the cluster. Over-provision here; unused private IP space is free.

---

## Step 3.4 — The Artifact Registry module

**What we're doing.** Creating the Docker repository your images will live in,
with a cleanup policy so it stays free.

**Why a cleanup policy.** Artifact Registry gives you 0.5 GB free per month.
Our two images are about 200 MB together, and Chapter 09's pipeline pushes a
new copy on **every commit to main**. Without cleanup you would blow past the
free tier within a week of normal work — not expensive ($0.10/GB), but
avoidable and a genuinely good habit.

The two policies work together: "delete anything older than 30 days, unless it
is one of the 10 newest". `KEEP` rules always win over `DELETE` rules.

**Create `GCP/modules/artifact-registry/variables.tf`:**

```hcl
variable "repository_id" {
  description = "Name of the Docker repository, e.g. \"linkforge\"."
  type        = string
}

variable "region" {
  description = "Region that hosts the repository. Keep it equal to your cluster region so image pulls stay in-region and free."
  type        = string
}

variable "keep_recent_versions" {
  description = "How many recent image versions to keep. Keeps you inside the 0.5 GB Artifact Registry free tier."
  type        = number
  default     = 10
}

variable "reader_members" {
  description = "IAM members granted read (pull) access, e.g. the GKE node service account."
  type        = list(string)
  default     = []
}

variable "writer_members" {
  description = "IAM members granted write (push) access, e.g. the GitHub Actions service account."
  type        = list(string)
  default     = []
}
```

**Create `GCP/modules/artifact-registry/main.tf`:**

```hcl
# ---------------------------------------------------------------------------
# Artifact Registry: where our container images live
# ---------------------------------------------------------------------------
# Artifact Registry replaced Container Registry (gcr.io). Images are addressed
# as:  REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY_ID/IMAGE:TAG
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Container images for the LinkForge 3-tier lab"

  # Cleanup policies are how you stay inside the 0.5 GB/month free tier.
  # Every push adds ~200 MB, so without this you would blow past it in a week.
  # KEEP rules always win over DELETE rules, so the two below mean:
  # "delete anything older than 30 days, UNLESS it is one of the 10 newest".
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_recent_versions
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }
}

# Least privilege: readers can only pull, writers can only push+pull.
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each   = toset(var.reader_members)
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each   = toset(var.writer_members)
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
```

**Create `GCP/modules/artifact-registry/outputs.tf`:**

```hcl
output "repository_name" {
  description = "Short name of the repository."
  value       = google_artifact_registry_repository.docker.repository_id
}

output "registry_host" {
  description = "Docker registry hostname, e.g. us-central1-docker.pkg.dev."
  value       = "${var.region}-docker.pkg.dev"
}

output "repository_url" {
  description = "Prefix you tag images with, e.g. us-central1-docker.pkg.dev/my-project/linkforge."
  value       = "${var.region}-docker.pkg.dev/${google_artifact_registry_repository.docker.project}/${google_artifact_registry_repository.docker.repository_id}"
}
```

**Why repository-level IAM rather than project-level.** Granting
`roles/artifactregistry.reader` on the project would let the holder read every
repository you ever create. Granting it on this one repository is the same
amount of Terraform and a much smaller blast radius.

---

## Step 3.5 — The Firestore module

**What we're doing.** Creating the database. It is nine lines, which is the
whole argument for choosing Firestore for this lab.

**Two things that will bite you if you skip the comments:**

1. The database is literally named `(default)`, parentheses included. Every
   project gets exactly one primary Firestore database and that is its name.
2. `location_id` **cannot be changed after creation**. Changing it in
   Terraform means destroying and recreating the database — losing all data.
   Pick your region now.

**Create `GCP/modules/firestore/variables.tf`:**

```hcl
variable "location_id" {
  description = "Firestore location. Use a region like \"us-central1\" (cheapest) or a multi-region like \"nam5\". THIS CANNOT BE CHANGED after creation."
  type        = string
  default     = "us-central1"
}

variable "deletion_policy" {
  description = "Set to DELETE so \"terraform destroy\" can actually remove the database. Use ABANDON in production."
  type        = string
  default     = "DELETE"
}
```

**Create `GCP/modules/firestore/main.tf`:**

```hcl
# ---------------------------------------------------------------------------
# Firestore in Native mode -- our Tier 3 (data tier)
# ---------------------------------------------------------------------------
# Why Firestore instead of Cloud SQL for this lab:
#   * Always Free tier: 1 GiB stored, 50k reads/day, 20k writes/day. LinkForge
#     will never come close, so the data tier costs $0.
#   * Serverless: no VPC peering, no private IP, no Cloud SQL Auth Proxy
#     sidecar, no database password to store and rotate.
#   * Access is pure IAM, which lets us demonstrate GKE Workload Identity
#     cleanly: the Pod gets a Google identity, no keys anywhere.
#
# Every project gets exactly one database named "(default)". The parentheses
# are part of the literal name -- that is not a typo.
resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.location_id
  type        = "FIRESTORE_NATIVE"

  # Without this, "terraform destroy" leaves the database behind and fails.
  deletion_policy = var.deletion_policy
}
```

**Create `GCP/modules/firestore/outputs.tf`:**

```hcl
output "database_name" {
  description = "Firestore database name (always \"(default)\" for the primary database)."
  value       = google_firestore_database.default.name
}

output "location_id" {
  description = "Where the Firestore data physically lives."
  value       = google_firestore_database.default.location_id
}
```

**Why `deletion_policy = "DELETE"`.** The provider defaults to refusing to
delete a Firestore database, which is correct for production and infuriating
in a lab. Without this line, Chapter 12's `terraform destroy` fails partway
through and leaves you cleaning up by hand.

---

## Step 3.6 — Wire it together in `main.tf`

**What we're doing.** Writing the root `main.tf` — the file that says *what*
we are building, with all the *how* delegated to modules.

**Create `GCP/linkforge/main.tf`** with this content:

```hcl
# ===========================================================================
# LinkForge -- root stack
# ===========================================================================
# Built up over three chapters of the tutorial:
#   Chapter 03 -> APIs, network, Artifact Registry, Firestore, node identity
#   Chapter 04 -> GKE cluster + Workload Identity for the API Pods
#   Chapter 08 -> Workload Identity Federation for GitHub Actions
# ===========================================================================

locals {
  common_labels = {
    project = var.name_prefix
    managed = "terraform"
    env     = "lab"
  }
}

# ---------------------------------------------------------------------------
# [Ch 03] Enable the APIs this stack needs
# ---------------------------------------------------------------------------
# Chicken-and-egg: Terraform can only enable APIs if serviceusage and
# cloudresourcemanager are ALREADY on. Chapter 02 turns those two on with
# gcloud; Terraform owns the rest from here.
#
# disable_on_destroy = false matters: without it, "terraform destroy" would
# switch off compute.googleapis.com for the whole project, which can break
# unrelated things and takes ages to undo.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# [Ch 03] Network
# ---------------------------------------------------------------------------
module "network" {
  source = "../modules/network"

  name_prefix      = var.name_prefix
  region           = var.region
  enable_cloud_nat = var.enable_cloud_nat

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# [Ch 03] Identity for the GKE nodes themselves
# ---------------------------------------------------------------------------
# GKE defaults to the Compute Engine default service account, which holds
# project Editor. Every Pod on the node inherits that blast radius. We create
# a dedicated SA with the four roles a node genuinely needs, plus pull-only
# access to Artifact Registry (granted below, on the repository itself).
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-node"
  display_name = "GKE node identity"
  description  = "Least-privilege identity for GKE node VMs"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ---------------------------------------------------------------------------
# [Ch 03] Artifact Registry
# ---------------------------------------------------------------------------
module "artifact_registry" {
  source = "../modules/artifact-registry"

  repository_id = var.artifact_repo_id
  region        = var.region

  # Nodes pull. CI pushes.
  reader_members = ["serviceAccount:${google_service_account.gke_nodes.email}"]

  # [Ch 08] Added once the GitHub OIDC module exists. Until then this is [].
  writer_members = ["serviceAccount:${module.github_oidc.app_service_account_email}"]

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# [Ch 03] Firestore -- the data tier
# ---------------------------------------------------------------------------
module "firestore" {
  source = "../modules/firestore"

  location_id = var.firestore_location

  depends_on = [google_project_service.required]
}
```

> ⚠️ **One line to change for now.** In the `artifact_registry` module block
> above, `writer_members` references `module.github_oidc`, which you have not
> created yet — that arrives in Chapter 08. Terraform would fail with
> `Reference to undeclared module`. Change that one line to an empty list:
>
> ```hcl
>   # [Ch 08] Added once the GitHub OIDC module exists. Until then this is [].
>   writer_members = []
> ```
>
> Chapter 08 tells you to change it back. This is what incremental Terraform
> actually feels like: you cannot reference something that does not exist yet.

**What the pieces do.**

- **`google_project_service`** enables the seven remaining APIs. Note
  `disable_on_destroy = false` — without it, `terraform destroy` would switch
  off Compute Engine for the whole project, which is slow to undo and can
  break unrelated things.
- **`google_service_account.gke_nodes`** is the identity the node VMs run as.
  This matters more than it looks: GKE's default is the **Compute Engine
  default service account, which holds project Editor**. Every Pod on the node
  inherits that reach. A dedicated account with four narrow roles is a
  five-minute change with an enormous security payoff.
- **`depends_on = [google_project_service.required]`** on each module.
  Terraform infers dependencies from references between resources, but nothing
  in the network module *references* the API enablement, so Terraform would
  happily try to create a VPC before Compute Engine is switched on. Explicit
  `depends_on` is the fix.

---

## Step 3.7 — Initialise Terraform

**What we're doing.** Downloading the Google provider and connecting to the
state bucket.

**Do this.**

```bash
cd GCP/linkforge

terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="prefix=linkforge"
```

**What just happened.** Terraform:

1. read `providers.tf` and downloaded `hashicorp/google` 6.x into `.terraform/`;
2. read the empty `backend "gcs" {}` block, merged in the two `-backend-config`
   values, and confirmed it can reach `gs://YOUR-BUCKET/linkforge/`;
3. wrote `.terraform.lock.hcl` recording the exact provider version and its
   checksums.

Expected, at the end:

```
Terraform has been successfully initialized!
```

**A note on `.terraform.lock.hcl`.** This repository's `.gitignore` currently
excludes it. In a real team you should **commit the lock file** — it is what
guarantees every machine, including CI, uses byte-identical providers. Worth
changing when you take these patterns to work.

**If it breaks.**

- *`Failed to get existing workspaces: querying Cloud Storage failed: storage:
  bucket doesn't exist`* — `TF_STATE_BUCKET` is wrong or unset. Run
  `echo $TF_STATE_BUCKET` and `source scripts/env.sh`.
- *`could not find default credentials`* — you skipped
  `gcloud auth application-default login` in Step 1.3.
- *`Error acquiring the state lock`* — a previous run died. Confirm nothing
  else is running, then `terraform force-unlock LOCK_ID`.

---

## Step 3.8 — Plan

**What we're doing.** Asking Terraform what it *would* do, and reading the
answer before letting it do anything.

**Do this.**

```bash
terraform fmt -recursive ..
terraform validate
terraform plan
```

**What just happened.** Three separate checks, each catching a different class
of mistake:

- `fmt` normalises whitespace and alignment. Run it before every commit; the
  CI pipeline in Chapter 09 fails the build if formatting is off.
- `validate` checks syntax and that every referenced variable and resource
  attribute actually exists. It does **not** talk to GCP.
- `plan` talks to GCP, compares reality against your configuration, and prints
  exactly what it intends to change.

Expected, at the end of the plan:

```
Plan: 19 to add, 0 to change, 0 to destroy.
```

The exact count will vary by a resource or two as you tweak things. What
matters is that **every line starts with `+`** — nothing is being destroyed,
because nothing exists yet.

> 🔍 **Read the plan.** Not skim — read. This is the habit that separates
> people who are comfortable with Terraform from people who are afraid of it.
> Every `-` (destroy) and `-/+` (replace) in a plan is a thing that is about to
> disappear. In production, `-/+` on a database is how you lose a company's
> data. It costs you ten seconds here to build the habit while the stakes are
> zero.

---

## Step 3.9 — Apply

**Do this.**

```bash
terraform apply
```

Type `yes` when it asks.

**What just happened.** About 2–3 minutes. The API enablements are the slow
part; the VPC and registry take seconds. Firestore takes about a minute.

Expected:

```
Apply complete! Resources: 19 added, 0 changed, 0 destroyed.
```

**Verify** — check the real cloud, not just Terraform's opinion of it:

```bash
gcloud compute networks list
gcloud compute networks subnets describe linkforge-subnet --region="$REGION" \
  --format="value(name,ipCidrRange,privateIpGoogleAccess)"
gcloud artifacts repositories list --location="$REGION"
gcloud firestore databases list --format="value(name,locationId,type)"
```

Expected:

```
NAME             SUBNET_MODE  ...
linkforge-vpc    CUSTOM       ...

linkforge-subnet	10.10.0.0/24	True

REPOSITORY  FORMAT  ...
linkforge   DOCKER  ...

projects/linkforge-lab-4821/databases/(default)	us-central1	FIRESTORE_NATIVE
```

The `True` on the subnet line is Private Google Access. That single boolean is
why there is no Cloud NAT in your bill.

**Confirm the state file landed in the bucket:**

```bash
gcloud storage ls "gs://${TF_STATE_BUCKET}/linkforge/"
```

Expected: `gs://.../linkforge/default.tfstate`

**If it breaks.**

- *`Error 403: ... API has not been used in project ... before or it is disabled`*
  — an API enablement had not propagated yet. Just run `terraform apply` again;
  it is idempotent and the second run almost always succeeds.
- *`Error creating Database: googleapi: Error 409: Database already exists`* —
  the project already has a `(default)` Firestore database (a previous attempt,
  or you enabled it in the console). Import it instead of recreating:
  `terraform import module.firestore.google_firestore_database.default "projects/${PROJECT_ID}/databases/(default)"`
- *`Error: Reference to undeclared module`* — you did not make the
  `writer_members = []` change from Step 3.6.

---

## What this cost

Still essentially nothing. A VPC, an empty registry and an empty Firestore
database are all free. The meter starts in the next chapter.

---

> ✅ **Checkpoint** — You have a VPC with Private Google Access, an Artifact
> Registry repository with a cleanup policy, a Firestore database, a
> least-privilege node service account, and Terraform state living safely in
> GCS. Run `terraform state list` to see all nineteen things you now own.

**Next:** [Chapter 04 — Terraform: the cluster](04-terraform-gke.md)
