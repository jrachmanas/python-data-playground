########################################
# Locals: bucket names (globally unique via account_id suffix)
########################################
locals {
  raw_bucket     = "${var.name_prefix}-raw-${var.account_id}"
  curated_bucket = "${var.name_prefix}-curated-${var.account_id}"
  results_bucket = "${var.name_prefix}-athena-results-${var.account_id}"
}

########################################
# S3 buckets (the GCS analog)
#   raw     = landing zone for NDJSON  (7-day lifecycle: scratch)
#   curated = dbt Parquet materializations (the "warehouse storage")
#   results = Athena query results scratch (7-day lifecycle)
########################################
resource "aws_s3_bucket" "raw" {
  bucket        = local.raw_bucket
  force_destroy = true # allow teardown even if objects remain (sandbox)
}

resource "aws_s3_bucket" "curated" {
  bucket        = local.curated_bucket
  force_destroy = true
}

resource "aws_s3_bucket" "results" {
  bucket        = local.results_bucket
  force_destroy = true
}

# Block ALL public access on every bucket (secure default; no reason to expose).
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "curated" {
  bucket                  = aws_s3_bucket.curated.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Expire raw objects after 7 days (landing zone; we process same-day).
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "expire-raw"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

# Expire Athena query results after 7 days (pure scratch).
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    id     = "expire-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

########################################
# Glue Data Catalog (the "schema" half of BigQuery)
#   database = weather_demo  (the dataset analog)
########################################
resource "aws_glue_catalog_database" "weather_demo" {
  name = "weather_demo"
}

########################################
# Glue RAW external table over s3://<raw>/raw/
#   - OpenX JSON SerDe reads the NDJSON (ignore.malformed.json = drop-bad-line, the DoFn analog)
#   - Partition projection on load_date => NO crawler, NO MSCK REPAIR.
#     Athena computes partitions from the range/format at query time.
#   - All columns typed STRING here (truly "raw"); dbt staging does the casts/normalization.
########################################
resource "aws_glue_catalog_table" "raw_weather" {
  database_name = aws_glue_catalog_database.weather_demo.name
  name          = "raw_weather"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "json"

    # --- partition projection (the crawler-free trick) ---
    "projection.enabled"              = "true"
    "projection.load_date.type"       = "date"
    "projection.load_date.format"     = "yyyy-MM-dd"
    "projection.load_date.range"      = "2026-01-01,NOW"
    "projection.load_date.interval"   = "1"
    "projection.load_date.interval.unit" = "DAYS"
    "storage.location.template"       = "s3://${local.raw_bucket}/raw/load_date=$${load_date}/"
  }

  partition_keys {
    name = "load_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.raw_bucket}/raw/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
      }
    }

    columns {
      name = "observed_at"
      type = "string"
    }
    columns {
      name = "ingested_at"
      type = "string"
    }
    columns {
      name = "city"
      type = "string"
    }
    columns {
      name = "country"
      type = "string"
    }
    columns {
      name = "latitude"
      type = "string"
    }
    columns {
      name = "longitude"
      type = "string"
    }
    columns {
      name = "temperature_c"
      type = "string"
    }
    columns {
      name = "humidity_pct"
      type = "string"
    }
    columns {
      name = "wind_speed_kmh"
      type = "string"
    }
  }
}

########################################
# Athena workgroup (the query ENGINE config; storage lives in S3 above)
#   enforce_workgroup_configuration = FALSE: the workgroup provides a DEFAULT
#   result location, but does NOT force it. dbt-athena needs this so it can set
#   per-query locations itself: query RESULTS -> s3_staging_dir (results/dbt/),
#   CTAS DATA -> s3_data_dir (curated). With enforce=true the workgroup overrides
#   dbt's data dir and shoves materialized tables into the results bucket (which
#   has a 7-day lifecycle) instead of the durable curated "warehouse" bucket.
########################################
resource "aws_athena_workgroup" "weather" {
  name          = "weather-demo-wg"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = false
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${local.results_bucket}/output/"
    }
  }
}

########################################
# ECR repo (holds the dbt container image for Phase 7 orchestration)
########################################
resource "aws_ecr_repository" "weather" {
  name         = "weather-demo"
  force_delete = true # delete even with images (sandbox teardown)

  image_scanning_configuration {
    scan_on_push = false
  }
}
