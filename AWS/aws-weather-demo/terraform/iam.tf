########################################
# ARNs used in policies (Glue/Athena need explicit region+account ARNs)
########################################
locals {
  workgroup_arn    = "arn:aws:athena:${var.region}:${var.account_id}:workgroup/${aws_athena_workgroup.weather.name}"
  glue_catalog_arn = "arn:aws:glue:${var.region}:${var.account_id}:catalog"
  glue_db_arn      = "arn:aws:glue:${var.region}:${var.account_id}:database/${aws_glue_catalog_database.weather_demo.name}"
  glue_tables_arn  = "arn:aws:glue:${var.region}:${var.account_id}:table/${aws_glue_catalog_database.weather_demo.name}/*"
}

# Trust policy shared by both workload roles: "a Lambda function may assume me".
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

########################################
# ROLE 1 — Lambda ingestion (fetch -> NDJSON -> S3)
#   Only power: write objects under raw/ + emit CloudWatch logs. Nothing else.
########################################
resource "aws_iam_role" "lambda_ingest" {
  name               = "${var.name_prefix}-lambda-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Managed policy for basic CloudWatch Logs (create log group/stream + PutLogEvents).
resource "aws_iam_role_policy_attachment" "lambda_ingest_logs" {
  role       = aws_iam_role.lambda_ingest.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline: PutObject scoped to raw/* ONLY.
data "aws_iam_policy_document" "lambda_ingest_s3" {
  statement {
    sid       = "PutRawObjects"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.raw.arn}/raw/*"]
  }
}

resource "aws_iam_role_policy" "lambda_ingest_s3" {
  name   = "put-raw-objects"
  role   = aws_iam_role.lambda_ingest.id
  policy = data.aws_iam_policy_document.lambda_ingest_s3.json
}

########################################
# ROLE 2 — dbt / Athena  (the compute-perm vs data-perm lesson)
#   Consumed by the dbt Lambda in Phase 7. dbt on Athena needs THREE grants:
#     (a) Athena  = the query ENGINE
#     (b) Glue    = the SCHEMA (create/alter tables as dbt materializes)
#     (c) S3      = the DATA (read raw, read/write curated + results)
#   Athena alone => AccessDenied. All three together => it works.
########################################
resource "aws_iam_role" "dbt_athena" {
  name               = "${var.name_prefix}-dbt-athena"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "dbt_athena_logs" {
  role       = aws_iam_role.dbt_athena.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "dbt_athena" {
  # (a) Athena engine
  statement {
    sid = "AthenaQuery"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]
    resources = [local.workgroup_arn]
  }

  # (b) Glue schema — create/alter/drop tables + partitions in weather_demo
  statement {
    sid = "GlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:BatchDeleteTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:UpdatePartition",
      "glue:DeletePartition",
      "glue:BatchDeletePartition",
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_db_arn,
      local.glue_tables_arn,
    ]
  }

  # (c-read) raw bucket: list + get
  statement {
    sid       = "S3ReadRaw"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn, "${aws_s3_bucket.raw.arn}/*"]
  }

  # (c-rw) curated + results buckets: list + get + put + delete
  statement {
    sid = "S3ReadWriteCuratedResults"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.curated.arn, "${aws_s3_bucket.curated.arn}/*",
      aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "dbt_athena" {
  name   = "dbt-athena-access"
  role   = aws_iam_role.dbt_athena.id
  policy = data.aws_iam_policy_document.dbt_athena.json
}
