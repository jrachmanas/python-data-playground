# ---------------------------------------------------------------------------
# Cloud Composer (managed Apache Airflow) — the orchestration capstone.
#
# COST WARNING: unlike everything else here, Composer is NOT scale-to-zero. It
# runs a persistent GKE cluster + Airflow, billed ~$10-25/day while it exists.
# We create it, run the DAG, inspect, then `terraform destroy` it the SAME
# session. Creation takes ~25 min.
#
# The env_variables below are how the DAG learns the concrete resource names
# (project, buckets, SA, dataset, tables, Cloud Run job) without hard-coding —
# the DAG reads them via os.environ at parse time.
# ---------------------------------------------------------------------------
resource "google_composer_environment" "weather" {
  name   = "weather-demo"
  region = var.region

  config {
    software_config {
      env_variables = {
        # NB: GCP_PROJECT / GCP_TENANT_NAME (and AIRFLOW__*, SQL_*) are RESERVED
        # by Composer and rejected. Use a neutral prefix for our own config.
        WEATHER_PROJECT  = var.project_id
        WEATHER_REGION   = var.region
        RAW_BUCKET       = google_storage_bucket.raw.name
        DATAFLOW_BUCKET  = google_storage_bucket.dataflow.name
        DATAFLOW_SA      = google_service_account.dataflow.email
        BQ_DATASET       = google_bigquery_dataset.weather.dataset_id
        BQ_OBSERVATIONS  = google_bigquery_table.observations.table_id
        BQ_DAILY_SUMMARY = google_bigquery_table.daily_summary.table_id
        CLOUD_RUN_JOB    = google_cloud_run_v2_job.ingestion.name
      }
    }

    node_config {
      # DAG code executes AS this service account. Anyone who can edit a DAG
      # can use its permissions -> user-managed least-privilege SA (not default).
      service_account = google_service_account.composer.email
    }
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.composer_worker,
    google_project_iam_member.composer_run,
    google_project_iam_member.composer_dataflow,
    google_project_iam_member.composer_bigquery_job,
  ]
}
