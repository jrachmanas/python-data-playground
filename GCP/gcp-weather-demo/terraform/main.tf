# ---------------------------------------------------------------------------
# 1. Enable the Google Cloud APIs this project needs.
# ---------------------------------------------------------------------------
locals {
  services = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "cloudbuild.googleapis.com",
    "composer.googleapis.com",
    "compute.googleapis.com",
    "dataflow.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# 2. Cloud Storage buckets.
#    - raw:      landing zone for the ingestion job's NDJSON files
#    - dataflow: staging/temp/templates area for Dataflow jobs
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-weather-raw"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket" "dataflow" {
  name                        = "${var.project_id}-dataflow"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# 3. BigQuery dataset + two tables (raw observations, daily summary).
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "weather" {
  dataset_id = "weather_demo"
  location   = var.bq_location

  delete_contents_on_destroy = true

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_table" "observations" {
  dataset_id          = google_bigquery_dataset.weather.dataset_id
  table_id            = "weather_observations"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "observed_at"
  }

  clustering = ["city"]

  schema = jsonencode([
    { name = "observed_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "ingested_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "city", type = "STRING", mode = "REQUIRED" },
    { name = "country", type = "STRING", mode = "NULLABLE" },
    { name = "latitude", type = "FLOAT", mode = "NULLABLE" },
    { name = "longitude", type = "FLOAT", mode = "NULLABLE" },
    { name = "temperature_c", type = "FLOAT", mode = "NULLABLE" },
    { name = "humidity_pct", type = "INTEGER", mode = "NULLABLE" },
    { name = "wind_speed_kmh", type = "FLOAT", mode = "NULLABLE" },
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "daily_summary" {
  dataset_id          = google_bigquery_dataset.weather.dataset_id
  table_id            = "weather_daily_summary"
  deletion_protection = false

  schema = jsonencode([
    { name = "observation_date", type = "DATE", mode = "REQUIRED" },
    { name = "city", type = "STRING", mode = "REQUIRED" },
    { name = "record_count", type = "INTEGER", mode = "REQUIRED" },
    { name = "avg_temperature_c", type = "FLOAT", mode = "NULLABLE" },
    { name = "avg_humidity_pct", type = "FLOAT", mode = "NULLABLE" },
    { name = "avg_wind_speed_kmh", type = "FLOAT", mode = "NULLABLE" },
  ])
}

# ---------------------------------------------------------------------------
# 4. Artifact Registry repository for the ingestion container image.
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "containers" {
  location      = var.region
  repository_id = "weather-demo"
  description   = "Container images for the weather demo"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# 5. Cloud Run Job: runs the ingestion container to completion, then exits.
#    Runs AS the weather-ingestion service account; writes to the raw bucket.
# ---------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "ingestion" {
  name                = "weather-ingestion"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.cloud_run.email
      timeout         = "300s"
      max_retries     = 1

      containers {
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.containers.repository_id}/ingestion:latest"

        env {
          name  = "RAW_BUCKET"
          value = google_storage_bucket.raw.name
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.run_storage,
  ]
}
