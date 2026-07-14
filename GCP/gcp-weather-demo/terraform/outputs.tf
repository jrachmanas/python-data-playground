# Convenience outputs: values you'll paste into later gcloud / Dataflow / bq
# commands. Run `terraform output` any time to see them.

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "raw_bucket" {
  description = "Bucket where the ingestion job lands NDJSON files"
  value       = google_storage_bucket.raw.name
}

output "dataflow_bucket" {
  description = "Bucket for Dataflow staging/temp/code"
  value       = google_storage_bucket.dataflow.name
}

output "bq_dataset" {
  value = google_bigquery_dataset.weather.dataset_id
}

output "artifact_registry_repo" {
  description = "Docker image path prefix for the ingestion image"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.containers.repository_id}"
}

output "cloud_run_sa" {
  value = google_service_account.cloud_run.email
}

output "dataflow_sa" {
  value = google_service_account.dataflow.email
}

output "composer_sa" {
  value = google_service_account.composer.email
}
