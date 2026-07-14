# GCP Weather Pipeline

An end-to-end, daily **batch data pipeline on Google Cloud** — built hands-on to learn how
cloud services divide responsibility. It fetches current weather for 4 cities, lands raw
JSON in a data lake, transforms and validates it into a warehouse, and orchestrates the whole
chain on a schedule with managed Apache Airflow.

> **Status:** complete end-to-end, ran green (including the Airflow capstone), then torn down.
> Infrastructure is gone; all code stays here so it is fully reproducible.
> For the step-by-step build log (every command + the *why*), see
> [`RUNBOOK_GCP.md`](RUNBOOK_GCP.md).

## What it does

```
Cloud Run job ──▶ GCS (raw NDJSON) ──▶ Dataflow/Beam ──▶ BigQuery ──▶ BigQuery
 (fetch API)      raw/load_date=…/      parse/validate/    observations   daily_summary
                                        normalize/type     (facts)        (+ 6 DQ checks)
        └───────────────── orchestrated daily 08:00 by Cloud Composer (Airflow) ─────────────┘
```

1. **Ingest** — a Cloud Run **Job** (containerized Python) calls the free Open-Meteo API for
   Vilnius, Riga, Tallinn, Warsaw and writes NDJSON to Cloud Storage, partitioned by load date.
2. **Transform** — an **Apache Beam** pipeline (parse / validate / drop-bad-rows / normalize
   timestamps / cast types) runs on **Dataflow**, writing typed rows to BigQuery.
3. **Warehouse** — BigQuery `weather_observations` (partitioned by day, clustered by city) +
   an idempotent `weather_daily_summary` rollup.
4. **Data quality** — 6 SQL PASS/FAIL checks (nulls, ranges, duplicates, source-to-summary
   reconciliation).
5. **Orchestrate** — a **Cloud Composer / Airflow** DAG chains all stages on a cron schedule.

## Stack

| Concern | Service |
|---|---|
| Ingestion | Cloud Run Jobs |
| Data lake | Cloud Storage (GCS) |
| Transform | Apache Beam on Cloud Dataflow |
| Warehouse | BigQuery (partitioned + clustered) |
| Orchestration | Cloud Composer (managed Apache Airflow) |
| Container build | Cloud Build → Artifact Registry |
| IaC | Terraform (`hashicorp/google`) |
| Identity | per-workload service accounts (least privilege) |

## Layout

```
terraform/   # all infra as code (buckets, BQ, IAM, Cloud Run job, Composer)
ingestion/   # main.py (API → NDJSON → GCS) + Dockerfile
dataflow/    # weather_pipeline.py (Beam parse/validate/type → BigQuery)
sql/         # create_summary.sql (rollup) + data_quality_checks.sql
dags/        # weather_pipeline_dag.py (Airflow DAG)
RUNBOOK_GCP.md   # the full teach-first build log
```

## Reproduce

Requires the `gcloud` SDK + Terraform. Follow [`RUNBOOK_GCP.md`](RUNBOOK_GCP.md) phase by phase
(account → auth → `terraform apply` → build image → run Dataflow → summary + DQ → Composer).
Cost note: everything is scale-to-zero except **Cloud Composer** (~$10–25/day), which the
runbook builds, runs, and destroys in the same session. Teardown = `terraform destroy` (or
delete the throwaway project for a total, one-click stop).

## Sibling project

The **same pipeline on AWS** (with dbt as the transform + test layer) lives at
[`../../AWS/aws-weather-demo/`](../../AWS/aws-weather-demo/README.md) — useful as a direct
GCP↔AWS service-by-service comparison.
