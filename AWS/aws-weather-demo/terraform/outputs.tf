output "raw_bucket" {
  description = "S3 raw landing bucket (NDJSON)"
  value       = aws_s3_bucket.raw.bucket
}

output "curated_bucket" {
  description = "S3 curated bucket (dbt Parquet materializations)"
  value       = aws_s3_bucket.curated.bucket
}

output "results_bucket" {
  description = "S3 Athena query-results bucket"
  value       = aws_s3_bucket.results.bucket
}

output "glue_database" {
  description = "Glue Data Catalog database (dataset analog)"
  value       = aws_glue_catalog_database.weather_demo.name
}

output "glue_raw_table" {
  description = "Glue external table over raw NDJSON"
  value       = aws_glue_catalog_table.raw_weather.name
}

output "athena_workgroup" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.weather.name
}

output "ecr_repository_url" {
  description = "ECR repo URI for the dbt container image"
  value       = aws_ecr_repository.weather.repository_url
}

output "lambda_ingest_role_arn" {
  description = "IAM role ARN for the ingestion Lambda"
  value       = aws_iam_role.lambda_ingest.arn
}

output "dbt_athena_role_arn" {
  description = "IAM role ARN for dbt-on-Athena (Phase 7 Lambda)"
  value       = aws_iam_role.dbt_athena.arn
}

output "ingestion_function_name" {
  description = "Name of the ingestion Lambda"
  value       = aws_lambda_function.ingest.function_name
}
