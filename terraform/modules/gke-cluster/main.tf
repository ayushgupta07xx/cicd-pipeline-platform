terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Private GKE cluster with Workload Identity — the cloud equivalent of the
# local kind clusters. The delivery pipeline is unchanged: it targets whatever
# cluster a deploy-config.yaml environment names.
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  # Node config lives in a separately managed pool; the default pool is removed.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity replaces long-lived ServiceAccount tokens — the single
  # most valuable upgrade over the local setup, where a static token must exist
  # because kind has no cloud IAM to federate with.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    horizontal_pod_autoscaling { disabled = false }
    http_load_balancing { disabled = false }
  }

  # Deletion protection on by default in the provider; explicit here so the
  # intent is visible rather than inherited.
  deletion_protection = true
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.this.name

  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0 # same zero-downtime principle as the app rollouts
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    # Least privilege at the node level.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      managed-by = "terraform"
    }
  }
}

# Artifact Registry replaces the local registry container.
resource "google_artifact_registry_repository" "images" {
  provider      = google
  project       = var.project_id
  location      = var.region
  repository_id = "delivery"
  format        = "DOCKER"
  description   = "Immutable application images promoted across environments"
}
