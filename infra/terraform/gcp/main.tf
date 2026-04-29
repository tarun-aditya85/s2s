# ============================================================================
# GCP Infrastructure for S2S Attribution Server
# ============================================================================
#
# Architecture:
# - Cloud Run: Serverless container deployment (auto-scaling)
# - Pub/Sub: Event streaming (clicks, postbacks, errors)
# - Dataflow: JSON to Parquet conversion
# - Cloud Storage: Parquet file storage (partitioned)
# - BigQuery: Data warehouse with authorized views
# - Memorystore Redis: Click ID storage with TTL
#
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ============================================================================
# Pub/Sub Topics for Event Streaming
# ============================================================================

resource "google_pubsub_topic" "clicks" {
  name = "s2s-clicks-${var.environment}"

  message_retention_duration = "86400s" # 24 hours
}

resource "google_pubsub_topic" "postbacks" {
  name = "s2s-postbacks-${var.environment}"

  message_retention_duration = "86400s"
}

resource "google_pubsub_topic" "errors" {
  name = "s2s-errors-${var.environment}"

  message_retention_duration = "604800s" # 7 days
}

# ============================================================================
# Cloud Storage Bucket for Parquet Files
# ============================================================================

resource "google_storage_bucket" "parquet_storage" {
  name          = "${var.project_id}-s2s-parquet-${var.environment}"
  location      = var.region
  force_destroy = false

  lifecycle_rule {
    condition {
      age = 365 # Delete after 1 year
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 90 # Move to Coldline after 90 days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  uniform_bucket_level_access = true
}

# ============================================================================
# Pub/Sub Subscriptions for Dataflow
# ============================================================================

resource "google_pubsub_subscription" "clicks_dataflow" {
  name  = "s2s-clicks-dataflow-${var.environment}"
  topic = google_pubsub_topic.clicks.name

  ack_deadline_seconds = 600 # 10 minutes for Dataflow processing

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.errors.id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_subscription" "postbacks_dataflow" {
  name  = "s2s-postbacks-dataflow-${var.environment}"
  topic = google_pubsub_topic.postbacks.name

  ack_deadline_seconds = 600

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.errors.id
    max_delivery_attempts = 5
  }
}

# ============================================================================
# Memorystore Redis (Managed Redis for Click ID Storage)
# ============================================================================

resource "google_redis_instance" "click_cache" {
  name           = "s2s-redis-${var.environment}"
  tier           = "STANDARD_HA" # High availability
  memory_size_gb = 5
  region         = var.region

  redis_version = "REDIS_7_0"

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 2
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }

  auth_enabled = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"
}

# ============================================================================
# BigQuery Dataset
# ============================================================================

resource "google_bigquery_dataset" "s2s_attribution" {
  dataset_id                 = "s2s_attribution_${var.environment}"
  friendly_name              = "S2S Attribution Data"
  description                = "Server-to-server attribution tracking data"
  location                   = var.region
  default_table_expiration_ms = null

  labels = {
    environment = var.environment
    purpose     = "attribution"
  }
}

# ============================================================================
# BigQuery Table (Base Table for All Events)
# ============================================================================

resource "google_bigquery_table" "events" {
  dataset_id = google_bigquery_dataset.s2s_attribution.dataset_id
  table_id   = "events"

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  clustering = ["tenant_id", "event_type"]

  schema = jsonencode([
    { name = "event_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_type", type = "STRING", mode = "REQUIRED" },
    { name = "tenant_id", type = "STRING", mode = "REQUIRED" },
    { name = "timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "click_id", type = "STRING", mode = "NULLABLE" },
    { name = "ip_address", type = "STRING", mode = "NULLABLE" },
    { name = "user_agent", type = "STRING", mode = "NULLABLE" },
    { name = "referrer", type = "STRING", mode = "NULLABLE" },
    { name = "target_url", type = "STRING", mode = "NULLABLE" },
    { name = "utm_source", type = "STRING", mode = "NULLABLE" },
    { name = "utm_medium", type = "STRING", mode = "NULLABLE" },
    { name = "utm_campaign", type = "STRING", mode = "NULLABLE" },
    { name = "utm_term", type = "STRING", mode = "NULLABLE" },
    { name = "utm_content", type = "STRING", mode = "NULLABLE" },
    { name = "device_type", type = "STRING", mode = "NULLABLE" },
    { name = "device_brand", type = "STRING", mode = "NULLABLE" },
    { name = "os", type = "STRING", mode = "NULLABLE" },
    { name = "browser", type = "STRING", mode = "NULLABLE" },
    { name = "country", type = "STRING", mode = "NULLABLE" },
    { name = "region", type = "STRING", mode = "NULLABLE" },
    { name = "city", type = "STRING", mode = "NULLABLE" },
    { name = "conversion_value", type = "FLOAT64", mode = "NULLABLE" },
    { name = "currency", type = "STRING", mode = "NULLABLE" },
    { name = "order_id", type = "STRING", mode = "NULLABLE" },
    { name = "network_name", type = "STRING", mode = "NULLABLE" },
    { name = "payout", type = "FLOAT64", mode = "NULLABLE" },
    { name = "commission", type = "FLOAT64", mode = "NULLABLE" },
    { name = "latency_ms", type = "INT64", mode = "NULLABLE" },
    { name = "matched", type = "BOOL", mode = "NULLABLE" },
  ])
}

# ============================================================================
# Cloud Run Service
# ============================================================================

resource "google_cloud_run_v2_service" "s2s_server" {
  name     = "s2s-attribution-${var.environment}"
  location = var.region

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 100
    }

    containers {
      image = "gcr.io/${var.project_id}/s2s-attribution:latest"

      env {
        name  = "NODE_ENV"
        value = "production"
      }

      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      env {
        name  = "REDIS_HOST"
        value = google_redis_instance.click_cache.host
      }

      env {
        name  = "REDIS_PORT"
        value = "6379"
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "512Mi"
        }
      }

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 10
        timeout_seconds       = 3
        period_seconds        = 10
        failure_threshold     = 3
      }

      liveness_probe {
        http_get {
          path = "/liveness"
        }
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 10
        failure_threshold     = 3
      }
    }
  }
}

# ============================================================================
# Cloud Run IAM (Allow unauthenticated access)
# ============================================================================

resource "google_cloud_run_v2_service_iam_member" "public_access" {
  name     = google_cloud_run_v2_service.s2s_server.name
  location = google_cloud_run_v2_service.s2s_server.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ============================================================================
# Outputs
# ============================================================================

output "cloud_run_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_v2_service.s2s_server.uri
}

output "redis_host" {
  description = "Redis host"
  value       = google_redis_instance.click_cache.host
}

output "redis_port" {
  description = "Redis port"
  value       = google_redis_instance.click_cache.port
}

output "storage_bucket" {
  description = "Parquet storage bucket"
  value       = google_storage_bucket.parquet_storage.name
}

output "bigquery_dataset" {
  description = "BigQuery dataset"
  value       = google_bigquery_dataset.s2s_attribution.dataset_id
}
