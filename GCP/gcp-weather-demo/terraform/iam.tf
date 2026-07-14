# ---------------------------------------------------------------------------
# Service accounts: one non-human identity per workload.
# ---------------------------------------------------------------------------
resource "google_service_account" "cloud_run" {
  account_id   = "weather-ingestion"
  display_name = "Weather ingestion Cloud Run Job"
}

resource "google_service_account" "composer" {
  account_id   = "weather-composer"
  display_name = "Weather demo Composer"
}

resource "google_service_account" "dataflow" {
  account_id   = "weather-dataflow"
  display_name = "Weather demo Dataflow"
}

# ---------------------------------------------------------------------------
# Cloud Run ingestion job: write objects to GCS + write logs.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "run_storage" {
  project = var.project_id
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "run_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

# ---------------------------------------------------------------------------
# Dataflow workers: run jobs, read/write GCS staging, write to BigQuery.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_bigquery" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# bigquery.dataEditor lets the SA write rows, but WriteToBigQuery imports data
# via a BigQuery *load job*. Creating any job needs bigquery.jobs.create, which
# lives in roles/bigquery.jobUser -- a separate role. Without this the batch
# load fails with "User does not have bigquery.jobs.create permission".
resource "google_project_iam_member" "dataflow_bigquery_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# ---------------------------------------------------------------------------
# Composer (Airflow) orchestrator: trigger Cloud Run, launch Dataflow,
# run BigQuery jobs, and impersonate the Dataflow service account.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "composer_worker" {
  project = var.project_id
  role    = "roles/composer.worker"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_dataflow" {
  project = var.project_id
  role    = "roles/dataflow.developer"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_bigquery_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_bigquery_data" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.composer.email}"
}

resource "google_project_iam_member" "composer_act_as_dataflow" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.composer.email}"
}
