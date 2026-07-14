# AWS Weather Pipeline (dbt + Athena)

An end-to-end, daily **batch data pipeline on AWS** — a deliberate port of the
[GCP weather pipeline](../../GCP/gcp-weather-demo/README.md) to compare how the two clouds
divide responsibility, with **dbt** as the transform + data-quality layer. Same business task,
different services.

> **Status:** Phases 1–6 built and verified end-to-end (ingest → catalog → dbt transform →
> mart → data-quality gate). Orchestration (Phase 7 Step Functions/EventBridge, Phase 8a MWAA)
> is **documented, not built** — see "Orchestration" below. Infrastructure has been torn down;
> all code stays here so it is fully reproducible.
> For the step-by-step build log (every command + the *why*, incl. two real debugging stories),
> see [`RUNBOOK_AWS.md`](RUNBOOK_AWS.md).

## What it does

```
Lambda ──▶ S3 (raw NDJSON) ──▶ Glue table ──▶ dbt on Athena ─────────────────────▶
(fetch)    raw/load_date=…/    (schema-on-     stg view → observations → summary
                                read)          (Parquet in S3, curated)   + 8 dbt tests
```

1. **Ingest** — a **Lambda** (zero-dependency zip; urllib + boto3) calls the Open-Meteo API for
   Vilnius, Riga, Tallinn, Warsaw and writes NDJSON to **S3**, partitioned by load date.
2. **Catalog** — a **Glue** external table exposes the raw JSON to SQL via schema-on-read
   (partition projection, JSON SerDe, no crawler).
3. **Transform (dbt on Athena)** — a staging **view** cleans / validates / casts; an
   **incremental** model lands typed observations as **Parquet** in a curated S3 bucket.
4. **Serve** — a marts table `weather_daily_summary` aggregates daily per-city metrics.
5. **Data quality** — **8 dbt tests** (not_null, accepted ranges, uniqueness, source-to-mart
   reconciliation). `dbt build` runs the whole DAG and gates on any failing test.

### The key AWS teaching point

BigQuery is one product; on AWS the warehouse is **three decoupled pieces** —
**S3** (storage) + **Glue Data Catalog** (schema) + **Athena** (engine). "Landing typed
observations" = *dbt CTAS writes Parquet to S3, and a Glue table makes it queryable.*

## Stack

| Concern | Service |
|---|---|
| Ingestion | AWS Lambda |
| Data lake | Amazon S3 |
| Schema / catalog | AWS Glue Data Catalog |
| Query engine | Amazon Athena (Trino) |
| Transform + tests | dbt (`dbt-athena-community`) |
| Storage format | Apache Parquet |
| IaC | Terraform (`hashicorp/aws`) |
| Identity (human) | IAM Identity Center (SSO), short-lived tokens |
| Identity (workload) | per-workload IAM roles (least privilege) |

## Orchestration (designed, not built)

- **Phase 7 — Step Functions + EventBridge** (free): a serverless state machine (Ingest → dbt
  `build`) fired daily by a schedule. A genuinely different paradigm from Airflow; full theory +
  exact commands are in [`RUNBOOK_AWS.md`](RUNBOOK_AWS.md).
- **Phase 8a — MWAA (managed Airflow)**: intentionally skipped — it is the *same engine* as the
  Cloud Composer capstone already built on the GCP track, so it would add cost without new
  learning.

## Layout

```
terraform/       # infra as code (S3, Glue, Athena workgroup, Lambda, IAM roles, ECR)
ingestion/       # main.py (API → NDJSON → S3)
dbt/             # dbt project: staging view, observations, marts, tests
RUNBOOK_AWS.md       # the full teach-first build log
```

## Reproduce

Requires AWS CLI v2 + Terraform + Python. Follow [`RUNBOOK_AWS.md`](RUNBOOK_AWS.md) phase by
phase (account/budget → SSO auth → `terraform apply` → invoke Lambda → `dbt build` → verify).
Everything is scale-to-zero / free-tier; standing cost ≈ $0. Teardown =
`terraform destroy` + a one-line CloudWatch log-group sweep (there is no static key or throwaway
account to clean up because auth is via SSO).

## Sibling project

The original **GCP pipeline** (Cloud Run + Dataflow + BigQuery + Composer) lives at
[`../../GCP/gcp-weather-demo/`](../../GCP/gcp-weather-demo/README.md).
