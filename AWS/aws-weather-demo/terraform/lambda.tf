########################################
# Ingestion Lambda: Open-Meteo -> NDJSON -> S3 raw
#   Zero-dependency zip (boto3 is in the Lambda runtime; urllib for HTTP).
#   Terraform zips main.py itself — no Docker / no build step.
########################################

# Package ingestion/main.py into a zip at plan time.
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_file = "${path.module}/../ingestion/main.py"
  output_path = "${path.module}/../ingestion/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name = "${var.name_prefix}-ingestion"
  role          = aws_iam_role.lambda_ingest.arn

  runtime = "python3.12"
  handler = "main.handler" # file main.py, function handler()

  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256

  timeout     = 60
  memory_size = 128

  environment {
    variables = {
      RAW_BUCKET = aws_s3_bucket.raw.bucket
    }
  }
}
