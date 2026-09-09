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
