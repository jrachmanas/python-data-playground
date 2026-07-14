# GCP Weather Demo — Runbook

A step-by-step, reproducible log of building this sandbox from an empty Google Cloud
account. Every command we run is recorded here with a short "what / why / what happens"
so the whole scenario can be replayed from scratch by one person.

> This file is filled **as we go**. It is the source of truth for "how was this built".
> A top-level `README.md` (the "what is this project") will be written **after** everything
> works, so it does not describe things that changed along the way.

## Conventions used in this doc
- Region = **`europe-west1`** (Belgium); BigQuery multi-region = **`EU`**.
- All `terraform` commands run from `GCP/gcp-weather-demo/terraform/`.
- Cost guardrail: everything lives in one throwaway project. Deleting the project at the
  end removes 100% of resources and stops all billing.

> **Placeholders.** Replace every `<...>` with your own value. Bucket names embed the
> project ID purely for global uniqueness — substitute yours.
>
> | Placeholder | What it is | How to obtain |
> |---|---|---|
> | `<PROJECT_ID>` | Your globally-unique project ID (e.g. `weather-demo-123456`) | you choose it at project creation; `gcloud config get-value project` shows the current one |
> | `<PROJECT_NUMBER>` | The numeric project number | `gcloud projects describe <PROJECT_ID> --format='value(projectNumber)'` |
> | `<hash>` | Random suffix GCP assigns to Composer's auto-created bucket | `gcloud composer environments describe ... --format='get(config.dagGcsPrefix)'` |

---

## Phase 0 — Account & project

### 0.1 Free trial
Signed up for the Google Cloud **Free Trial** (€263 credit, ~90 days). No charges occur
while on the trial unless you manually upgrade to a paid account.

### 0.2 Create a dedicated project
Console → project picker → **New Project**.
- Name: `weather-demo`
- Resulting **Project ID: `<PROJECT_ID>`** (globally unique, immutable — this is what
  every command/config references, *not* the display name).
- Project number: `<PROJECT_NUMBER>`.

**Why a fresh project:** deleting it later is a one-click, total teardown — the strongest
possible cost guardrail. Verified the trial billing account auto-linked to the new project.

---

## Phase 1 — Local tooling & authentication

### 1.1 Install the CLIs (macOS)
Homebrew failed here (outdated Xcode Command Line Tools on macOS 12), so we used the
official standalone distributions instead — no compiler needed.

- **Terraform** v1.15.8 — infrastructure-as-code. We declare resources in `.tf` files;
  Terraform makes the cloud match, and can destroy it all in one command.
- **Google Cloud SDK** (`gcloud` 575.0.1, plus `bq` and `gsutil`) — CLIs to operate and
  inspect GCP. Ships its own bundled Python, so it does not depend on the system Python.

The SDK installer appends its `bin/` to `PATH` in `~/.zshrc`. A shell opened **before**
the install won't see `gcloud` — open a new terminal (or `source ~/.zshrc`).

Verify:
```bash
terraform version
gcloud version
```

### 1.2 Authenticate
```bash
gcloud auth login                          # human login -> gcloud CLI itself
gcloud auth application-default login      # login -> credentials for client libs & Terraform (ADC)
gcloud config set project <PROJECT_ID>
```
- `auth login` authorizes the **`gcloud` command** as you.
- `application-default login` writes **Application Default Credentials (ADC)** to
  `~/.config/gcloud/application_default_credentials.json`. Terraform and Google client
  libraries automatically read this file — this is how Terraform authenticates without any
  key file.
- `config set project` sets the default project for `gcloud`/`bq`.

Optional but recommended (clears the "no quota project" warning ADC prints):
```bash
gcloud auth application-default set-quota-project <PROJECT_ID>
```
The **quota project** is which project gets billed for API quota when client libraries call
Google APIs. Leaving it unset can cause spurious "API not enabled / quota exceeded" errors.

---

## Phase 2 — Terraform scaffolding

All files live in `GCP/gcp-weather-demo/terraform/`.

### 2.1 `.gitignore` (what we exclude from git, and why)
- `.terraform/` — the local provider-plugin cache (hundreds of MB, machine-specific, rebuilt
  by `terraform init`). Never commit.
- `*.tfstate`, `*.tfstate.*` — Terraform **state**: the mapping between your `.tf` config and
  real cloud resource IDs. Can contain secrets in plaintext. Never commit (for real teams it
  lives in a remote backend like a GCS bucket).
- `*.tfvars` (except examples) — holds real values like your project ID; kept out of git so
  config is not hard-coded into shared history.
- `crash.log`, `*.tfplan` — transient.
- **`.terraform.lock.hcl` is deliberately NOT ignored** — see 2.4.

### 2.2 `versions.tf` — pin Terraform & provider
```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"     # allow 7.x, block 8.0 (pessimistic constraint)
    }
  }
}
provider "google" {
  project = var.project_id
  region  = var.region
}
```
- `required_version` guards which Terraform CLI may run this config.
- `required_providers` picks the Google provider; `~> 7.0` = "any 7.x, but not 8.0"
  (guards against breaking major-version changes).
- The `provider` block sets defaults; it authenticates via ADC from Phase 1 automatically.

### 2.3 `variables.tf` + `terraform.tfvars` — parameterize
- `variables.tf` **declares** inputs (`project_id`, `region`, …) with types/defaults.
  `project_id` has **no default** on purpose — it must be supplied explicitly, so you can
  never accidentally apply to the wrong project.
- `terraform.tfvars` **supplies** the values. Terraform auto-loads any `*.tfvars` file.
  Git-ignored because it carries the concrete project ID.

### 2.4 `terraform init`
```bash
terraform init
```
Downloads the Google provider into `.terraform/`, and writes **`.terraform.lock.hcl`**
recording the exact provider version + checksums selected (locked **hashicorp/google
v7.39.0**).

**Why commit the lock file:** it guarantees every machine / CI run installs the *identical*
provider version and verifies checksums — reproducible, tamper-evident builds. It is the
Terraform equivalent of `package-lock.json` / `poetry.lock`.

### 2.5 `terraform validate`
```bash
terraform validate
```
Checks the config is internally consistent (syntax, references, types) **without** touching
the cloud. Returned `Success! The configuration is valid.`

---

## Phase 3 — First apply (foundational resources)

### 3.1 `main.tf` — what it declares (19 resources)
- **13 API enablements** (`google_project_service` via `for_each` over a set of service
  names): storage, bigquery, run, artifactregistry, dataflow, composer, compute, cloudbuild,
  iam, iamcredentials, logging, serviceusage, bigqueryconnection. Enabling an API is free and
  required before you can create resources of that type.
- **2 Cloud Storage buckets** (`google_storage_bucket`):
  - `<PROJECT_ID>-weather-raw` — raw NDJSON landing zone. Has a **lifecycle rule**
    auto-deleting objects after 7 days (cost hygiene). `force_destroy = true` lets Terraform
    delete it even if non-empty. `uniform_bucket_level_access = true` = IAM-only permissions
    (no legacy per-object ACLs).
  - `<PROJECT_ID>-dataflow` — staging/temp for Dataflow jobs.
- **1 BigQuery dataset** `weather_demo` (location `EU`), with `delete_contents_on_destroy`
  so teardown works.
- **2 BigQuery tables**:
  - `weather_observations` — **partitioned by day** on `observed_at` and **clustered** by
    `city`. Partitioning limits bytes scanned (BigQuery bills per bytes read); clustering
    speeds per-city filters. `deletion_protection = false` so we can tear down.
  - `weather_daily_summary` — small aggregate table (no partition/cluster needed).
- **1 Artifact Registry repo** `weather-demo` (Docker format, `europe-west1`) — stores the
  container image the Cloud Run ingestion job runs.

Reading Terraform plan symbols: `+` create, `-` destroy, `~` update in place, `-/+` replace.

### 3.2 `terraform plan`
```bash
terraform plan
```
Dry run — compares desired (`.tf`) vs current (empty) state and prints the diff. Result:
**`Plan: 19 to add, 0 to change, 0 to destroy`**, all `+`. Nothing created, $0.

### 3.3 `terraform apply`
```bash
terraform apply     # review, then type: yes
```
Created all 19 resources, respecting the dependency graph: the 13 APIs enabled first (in
parallel; compute/composer took ~2 min), then buckets/dataset/registry, then the tables
(which depend on the dataset).
Result: **`Apply complete! Resources: 19 added, 0 changed, 0 destroyed.`**

**Cost:** ~$0 standing — buckets/tables/registry are empty; you pay for stored bytes and
bytes scanned, both currently zero.

### 3.4 Verify independently (not just trusting Terraform)
```bash
terraform state list                                   # what Terraform thinks it made
gcloud storage buckets list --project <PROJECT_ID>
bq ls weather_demo                                     # dataset's tables
gcloud artifacts repositories list --location europe-west1
```

### 3.5 `iam.tf` — service accounts & IAM (also applied; +15 resources -> 34 total)
Applied alongside the foundation. Declares **3 workload service accounts** (non-human
identities, one per job — least privilege) and **12 project IAM bindings** granting each
only the roles it needs:
- `weather-ingestion` (Cloud Run job): `storage.objectCreator`, `logging.logWriter`.
- `weather-dataflow` (Beam workers): `dataflow.worker`, `storage.objectAdmin`,
  `bigquery.dataEditor`.
- `weather-composer` (Airflow): `composer.worker`, `run.developer`, `dataflow.developer`,
  `bigquery.jobUser`, `bigquery.dataEditor`, `storage.objectAdmin`, and
  `iam.serviceAccountUser` (so Composer can *impersonate* the Dataflow SA to launch jobs "as" it).

Key IAM concepts:
- A **service account** is an identity a workload authenticates *as* (email like
  `weather-ingestion@PROJECT.iam.gserviceaccount.com`). No passwords — GCP mints tokens.
- `google_project_iam_member` = **additive** binding ("add this member to this role").
  Contrast `_binding` (authoritative for a role) and `_policy` (authoritative for the whole
  project). `_member` is safe: it won't clobber bindings it doesn't manage.
- **Least privilege:** three identities instead of one shared, each scoped to its task, so a
  compromise or bug is contained.

Verify:
```bash
terraform state list | wc -l                                    # -> 34
gcloud iam service-accounts list --project <PROJECT_ID>  # 3 weather-* + default compute
terraform plan                                                  # -> "No changes"
```

**Foundation status:** 34 resources live, `terraform plan` clean. Remaining to add later:
the Cloud Run *job* (Phase 4/5, needs the image first) and Composer (Phase 7, expensive).

---

## Phase 4 — Cloud Run ingestion job

### 4.0 What & why
A **Cloud Run Job** (not a Service): it runs to completion and exits — perfect for a batch
task that fetches weather, writes one NDJSON file to the raw bucket, and stops. (A Service
would stay up serving HTTP; we don't need that.) The code is packaged as a container image,
stored in Artifact Registry, and executed by the `weather-ingestion` service account.

Flow: write Python -> containerize (Dockerfile) -> build for `linux/amd64` -> push to
Artifact Registry -> declare the Cloud Run job in Terraform -> execute -> verify the file.

### 4.1 Ingestion code (`ingestion/`)
- `main.py` — fetches current weather for 4 cities (Vilnius/Riga/Tallinn/Warsaw) from the free
  Open-Meteo API (no key), builds flat records, writes them as **NDJSON** (one JSON per line)
  to `gs://<raw-bucket>/raw/load_date=YYYY-MM-DD/weather_<ts>.json`, prints a structured log.
  - Two timestamps by design: `observed_at` = event time (from API), `ingested_at` =
    processing time (now). Bucket name comes from env var `RAW_BUCKET` (12-factor).
  - `.get()` for optional metrics => missing value becomes `None`/NULL (Python KeyError guard);
    those columns are NULLABLE in BQ so NULLs load fine. `raise_for_status()` = fail loud on API error.
- `requirements.txt` — `google-cloud-storage==3.*`, `requests==2.*` (pin major only).
- `Dockerfile` — `python:3.12-slim`; `PYTHONUNBUFFERED=1` for live logs; copies
  requirements before code so the pip layer caches across code edits; `CMD python main.py`.

### 4.2 Build & push the image — via Cloud Build (not local Docker)
Chose **Cloud Build** over installing Docker locally: avoids the macOS-12 Docker Desktop
wall, builds natively as `linux/amd64` (no ARM emulation), and cloudbuild API was already
enabled. Cost negligible (free tier).
```bash
cd ../ingestion
gcloud builds submit \
  --tag europe-west1-docker.pkg.dev/<PROJECT_ID>/weather-demo/ingestion:latest \
  .
```
Result: build SUCCESS in ~40s, image pushed. Digest `sha256:b51a3257...`.
Verify:
```bash
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/<PROJECT_ID>/weather-demo/ingestion
```

### 4.3 Declare the Cloud Run Job in Terraform (§5)
Added `google_cloud_run_v2_job "ingestion"` to `main.tf`. Notes:
- Nested `template { template { } }` = execution template -> task template (Cloud Run Jobs'
  real hierarchy; a job can fan out to parallel tasks — here just one).
- `service_account = weather-ingestion` — runs AS that SA (inherits storage + logging roles).
- `image = ...ingestion:latest` — `:latest` tag resolved at execution time (re-push updates
  the run without a Terraform change).
- `env RAW_BUCKET = google_storage_bucket.raw.name` — reference, not hard-coded.
- `timeout 300s`, `max_retries 1`, `cpu 1 / 512Mi` (billed only while running, ~seconds).
- `depends_on run_storage` — ensures the SA can write before the first run.
```bash
cd ../terraform
terraform plan      # expect: 1 to add
terraform apply     # yes  -> creates the job DEFINITION only (no run, no cost yet)
```

Applied: `Apply complete! Resources: 1 added` (the job definition; state now 35 resources).

### 4.4 Execute the job & verify (first real run)
```bash
gcloud run jobs execute weather-ingestion --region europe-west1 --wait
gcloud storage ls "gs://<PROJECT_ID>-weather-raw/raw/**"
gcloud storage cat "gs://<PROJECT_ID>-weather-raw/raw/load_date=YYYY-MM-DD/FILE.json"
```
- `execute --wait` blocks until the run finishes; execution name like `weather-ingestion-jb9s4`.
- `gcloud storage cat` streams an object to stdout (no download).
- Result: 1 file written, 4 NDJSON lines (Vilnius/Riga/Tallinn/Warsaw) with real temps.
- **Observed data quirk:** `observed_at` comes back as `"2026-07-12T07:30"` — no seconds, no
  `Z`. BigQuery TIMESTAMP needs a zone, so the Dataflow parser normalizes it to `...:00Z`.

**Phase 4 DONE.** Cloud Run job builds, deploys, runs, and lands NDJSON in GCS.

## Phase 5 — Dataflow / Apache Beam pipeline (raw NDJSON -> BigQuery)

### 5.0 Concepts
- **Beam** = the SDK to write the pipeline; **Dataflow** = Google's managed runner that executes it.
- **Pipeline** = DAG of transforms. **PCollection** = distributed immutable dataset flowing
  between steps. **PTransform** = a step, chained with `|`. **DoFn/ParDo** = per-element logic
  (`process()` can yield 0/1/many -> that's how records are filtered/dropped).
- **Runner** decides *where* it runs: `DirectRunner` (local laptop, free, for testing) vs
  `DataflowRunner` (managed cloud workers, small cost). Same code, different `--runner` flag.

### 5.1 Pipeline code (`dataflow/`)
- `weather_pipeline.py`:
  - `ParseWeatherRecord(beam.DoFn)` — per line: `try/except` (bad line -> log + drop, no crash);
    required-field check (missing observed_at/ingested_at/city -> `return`, record dropped);
    timestamp normalize `...T07:30` -> `...:00Z` (BQ TIMESTAMP needs a zone); `yield` clean dict
    with `.get()` on optionals -> NULLs. `source_file` passed as a ParDo side-arg (lineage).
  - `run()` — `argparse` for `--input`/`--output_table`; `parse_known_args()` leaves Beam flags
    (`--runner`, `--project`, ...) for `PipelineOptions`. `save_main_session=True` pickles module
    globals so remote Dataflow workers get imports (classic gotcha). Chain:
    `ReadFromText | ParDo(ParseWeatherRecord) | WriteToBigQuery`.
  - `WriteToBigQuery`: `WRITE_APPEND` (accumulate rows) + `CREATE_NEVER` (table must pre-exist,
    made by Terraform -> fail loud instead of auto-creating a wrong schema).
- `requirements.txt` — `apache-beam[gcp]` (the `[gcp]` extra = GCS + BigQuery + Dataflow connectors).

### 5.2 Local Beam environment (own venv, isolated)
```bash
cd ../dataflow
python3 -m venv .venv        # dedicated venv for Beam (it pins strict deps)
source .venv/bin/activate
pip install -r requirements.txt      # ~100+ packages, slow; normal
python -c "import apache_beam; print(apache_beam.__version__)"   # checkpoint
```

### 5.3 Local run (DirectRunner) -> BigQuery
Optional local sample copy (NOT required — `ReadFromText` reads `gs://` directly; the copy is
just to eyeball the file):
```bash
gcloud storage cp "gs://<PROJECT_ID>-weather-raw/raw/load_date=2026-07-12/weather_20260712T074407Z.json" ./sample.json
```
Run locally (no `--runner` => DirectRunner, i.e. Beam 2.75's PrismRunner, in-process, free):
```bash
python weather_pipeline.py \
  --input=./sample.json \
  --output_table=<PROJECT_ID>:weather_demo.weather_observations \
  --temp_location=gs://<PROJECT_ID>-dataflow/temp
```
- `--temp_location` is REQUIRED: `WriteToBigQuery` (batch) uses the **load-job** method — it
  stages rows as a file in GCS, then tells BigQuery to load it. Auth = your ADC.
- **Key idea:** the pipeline *code* runs locally, but the *sink is the real cloud BQ table*.
  There is no local BigQuery. Data round-trips: GCS -> laptop (parse) -> cloud BQ.
- Result: load job DONE, 4 rows in `weather_observations`.

### 5.4 Verify in BigQuery
```bash
bq query --use_legacy_sql=false \
'SELECT observed_at, city, temperature_c, humidity_pct, wind_speed_kmh, source_file
 FROM `<PROJECT_ID>.weather_demo.weather_observations` ORDER BY city'
```
- `--use_legacy_sql=false` = standard GoogleSQL (always use). Backtick `project.dataset.table`.
- Confirms 4 rows; `observed_at` renders `2026-07-12 07:30:00` (parser `...:00Z` normalization
  worked); `source_file = ./sample.json` (lineage stamped by the DoFn).

Data topology after 5.3/5.4: raw NDJSON in GCS (source of truth) + a disposable local
`sample.json` + 4 typed rows persisted server-side in BigQuery.

### 5.5 Run the SAME script on managed Dataflow
Identical code, `--runner=DataflowRunner` -> managed worker VMs in GCP (reads straight from GCS,
no local copy). `WRITE_APPEND` means this ADDS 4 more rows (local test already added 4 => 8);
we truncate afterwards.
```bash
python weather_pipeline.py \
  --runner=DataflowRunner \
  --project=<PROJECT_ID> \
  --region=europe-west1 \
  --temp_location=gs://<PROJECT_ID>-dataflow/temp \
  --staging_location=gs://<PROJECT_ID>-dataflow/staging \
  --service_account_email=weather-dataflow@<PROJECT_ID>.iam.gserviceaccount.com \
  --input="gs://<PROJECT_ID>-weather-raw/raw/load_date=2026-07-12/*.json" \
  --output_table="<PROJECT_ID>:weather_demo.weather_observations" \
  --job_name="weather-manual-$(date +%Y%m%d-%H%M%S)"
```
- `--staging_location` — Beam packages code+deps and uploads here for workers to fetch.
- `--service_account_email=weather-dataflow@...` — workers run AS this SA (least privilege:
  dataflow.worker + storage.objectAdmin + bigquery.dataEditor). Owner may launch "as" it via
  iam.serviceAccountUser.
- **Cost/time:** spins up >=1 worker VM, ~5-8 min, a few cents (the one intentional pre-Composer
  spend). Watch: Console -> Dataflow -> Jobs -> `weather-manual-*` (pipeline graph, element counts).

### 5.5.1 Troubleshooting: Dataflow 403 `bigquery.jobs.create`
The first `DataflowRunner` run **FAILED** (`JOB_STATE_FAILED`). Repeated 403 at
`Write to BigQuery/BigQueryBatchFileLoads/.../TriggerLoadJobs`:
```
Access Denied: Project <PROJECT_ID>:
User does not have bigquery.jobs.create permission in project <PROJECT_ID>.
```

**Root cause — a rights gap, not a broken config.** `WriteToBigQuery` in batch mode does
not stream rows; it stages the data in GCS and then submits a BigQuery **load job**.
Creating *any* job requires the permission `bigquery.jobs.create`. The `weather-dataflow`
SA had `roles/bigquery.dataEditor` (write *rows into a table*) but **not**
`roles/bigquery.jobUser` (create *jobs*) — GCP splits "modify data" from "run compute/jobs"
into different roles on purpose. The earlier local DirectRunner run worked only because it
used *your* ADC (project owner), which already has everything.

**Why no reset was needed.** Terraform is idempotent and `google_project_iam_member` is an
*additive* binding, so we just declare the one missing binding and apply — Terraform adds
only that, destroys nothing.

Fix — added to `iam.tf` (mirrors the existing `composer_bigquery_job`):
```hcl
resource "google_project_iam_member" "dataflow_bigquery_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}
```
```bash
cd ../terraform
terraform plan      # expect exactly: 1 to add, 0 to change, 0 to destroy
terraform apply     # yes  -> adds dataflow_bigquery_job (state 35 -> 36)
```
Then re-run the 5.5 Dataflow command. **Note:** IAM changes can take ~1-2 min to propagate;
an immediate 403 right after apply is eventual consistency — wait a minute and retry.

**Lesson:** for BigQuery you almost always need BOTH a *data* role (`dataEditor`) AND a
*job* role (`jobUser`) — one to touch the rows, one to run the load/query job.

### 5.6 Verify 8 rows, then clean the table
The managed run reads `raw/**` (all files) — currently one file with 4 records — and
`WRITE_APPEND`s them on top of the 4 the local test loaded, so the table holds **8**.
```bash
bq query --use_legacy_sql=false \
'SELECT COUNT(*) AS n FROM `<PROJECT_ID>.weather_demo.weather_observations`'   # -> 8
bq query --use_legacy_sql=false \
'TRUNCATE TABLE `<PROJECT_ID>.weather_demo.weather_observations`'              # -> 0
```
- Got `n = 8` (proves `WRITE_APPEND` accumulated, didn't overwrite), then
  `TRUNCATE` reported `Number of affected rows: 8` → table now empty.
- `TRUNCATE` wipes rows but keeps schema + day-partitioning + city-clustering (cheaper and
  cleaner than DROP + recreate). We reset so Phase 6's summary isn't computed off the
  local-test duplicates.
- **Note on the run:** the Dataflow job finished `JOB_STATE_DONE`; the load-job path
  (`BigQueryBatchFileLoads → TriggerLoadJobs`) is exactly what the 5.5.1 `jobUser` fix
  unblocked. A harmless warning flagged **soft-delete** on the dataflow bucket (GCP retains
  deleted temp/staging objects for a window = minor storage cost); negligible at this scale,
  can be disabled later.

**Phase 5 DONE.** Raw NDJSON → parsed/validated/typed → BigQuery, both locally (DirectRunner)
and on managed Dataflow. Table truncated to a clean baseline for Phase 6.

## Phase 6 — BigQuery transformation (summary) + data-quality

### 6.0 Concept
The warehouse split: `weather_observations` = raw immutable facts (one row per API reading);
`weather_daily_summary` = a derived rollup (one row per day+city with counts/averages) that
dashboards actually query — smaller, cheaper, faster.

### 6.1 Reload rows (table was truncated in 5.6)
Cheapest path = local **DirectRunner** (free, ADC), reloads the 4 records:
```bash
cd ../dataflow
python weather_pipeline.py \
  --input="gs://<PROJECT_ID>-weather-raw/raw/**" \
  --output_table=<PROJECT_ID>:weather_demo.weather_observations \
  --temp_location=gs://<PROJECT_ID>-dataflow/temp
```

### 6.2 `sql/create_summary.sql` — idempotent rollup
DELETE-then-INSERT scoped to the dates present in the source: clears the day(s) it's about
to recompute, then re-inserts fresh aggregates. Idempotent (re-runnable, no double-count);
leaves other days untouched — the standard "refresh affected partitions" shape. A plain
`INSERT ... SELECT` would pile up duplicate summary rows every run.
```bash
cd ../sql
bq query --use_legacy_sql=false < create_summary.sql
```
Result: `DELETE ... 0 rows` (summary was empty) then `INSERT ... 4 rows`. Verify:
```bash
bq query --use_legacy_sql=false \
'SELECT * FROM `<PROJECT_ID>.weather_demo.weather_daily_summary` ORDER BY city'
```
-> 4 rows (Riga/Tallinn/Vilnius/Warsaw), each `record_count = 1`, avgs = that single reading.

### 6.3 `sql/data_quality_checks.sql` — PASS/FAIL report card
Each check COUNTs *violations* (0 = healthy); `UNION ALL` into one result; `IF(violations=0,
'PASS','FAIL')`. Checks: no-null-required, no-duplicate-observation, temperature/humidity/
wind range, and **summary_reconciles_source** (|source rows − Σ record_count| = 0, the
end-to-end integrity check). In a real pipeline you'd fail the job if any status = FAIL.
```bash
bq query --use_legacy_sql=false < data_quality_checks.sql
```
Result: **all 6 PASS**.

### 6.4 Where DQ belongs in the ecosystem (note)
SQL-in-warehouse checks answer "is the LANDED dataset correct" (set-based: nulls, ranges,
reconciliation). In-stream checks in the Beam DoFn answer "reject bad records" before they
land. At scale you graduate raw SQL to managed frameworks (dbt tests, Great Expectations,
Soda, GCP Dataplex) — same SQL underneath, but versioned + alerting. Raw SQL is right for
this demo.

**Phase 6 DONE.** Raw facts -> idempotent daily summary -> green data-quality report.
The pipeline is now fully working, manually orchestrated, at near-zero standing cost.

## Phase 7 — Orchestration: Cloud Composer (managed Airflow)  *(COSTLY — same-session teardown)*

### 7.0 Decision + cost gate
Composer is the one piece that is NOT scale-to-zero: a persistent GKE cluster + Airflow,
~$10-25/day while it exists, ~25 min to create. We opted to build it, run it, inspect it,
then `terraform destroy` it in the SAME session. Guardrail: set a **budget alert** first
(Console → Billing → Budgets & alerts → Create budget, e.g. €50, thresholds 50/90/100%).
Budget alerts only *notify* — the real stop is the same-session destroy.

### 7.1 `terraform/composer.tf`
`google_composer_environment "weather"` (region europe-west1). `software_config.env_variables`
pass concrete resource names (project, buckets, dataflow SA, dataset, tables, Cloud Run job)
into Airflow so the DAG reads them via `os.environ` — no hard-coding. `node_config.
service_account = weather-composer` (user-managed least-privilege SA: DAG code runs AS it, so
whoever edits DAGs wields its rights). `depends_on` the composer IAM bindings.

**GOTCHA — reserved env var names.** `terraform plan` failed:
`env_variable "GCP_PROJECT" is a reserved name and cannot be used`. Composer reserves
`GCP_PROJECT`, `GCP_TENANT_NAME`, `AIRFLOW_HOME`, and any `AIRFLOW__*` / `SQL_*`. Renamed our
two to **`WEATHER_PROJECT` / `WEATHER_REGION`** in BOTH composer.tf and the DAG (keys must match).

### 7.2 `dags/weather_pipeline_dag.py`
DAG `weather_demo_pipeline`, chain: `start >> execute_cloud_run_ingestion >>
transform_weather_with_dataflow >> build_daily_summary >> check_observation_count >> end`.
- Operators = one per manual stage: `CloudRunExecuteJobOperator`, `DataflowStartPythonJobOperator`,
  `BigQueryInsertJobOperator` (DELETE+INSERT summary), `BigQueryCheckOperator` (fails DAG if
  `COUNT(*) >= 4` false = inline DQ gate), `EmptyOperator` bookends.
- `{{ ds }}` Jinja = the run's logical date; scopes the Dataflow input glob + summary + check
  to that day. **Trigger the DAG on TODAY's date** so `load_date={{ ds }}` matches the file
  ingestion just wrote (doc §9 caveat).
- `schedule="0 8 * * *"`, `catchup=False` (no backfill of missed days).

### 7.3 Apply (starts the ~25 min build + real spend)
```bash
cd terraform
terraform plan     # expect: 1 to add (google_composer_environment.weather)
terraform apply    # yes  -> ~25 min
```

### 7.4 Upload the Dataflow pipeline code (while Composer builds)
The DAG's `DataflowStartPythonJobOperator` runs `py_file=gs://<dataflow-bucket>/code/
weather_pipeline.py`. Composer does not have our repo — we must stage the pipeline file in
GCS so Airflow can launch it. This can be done any time (doesn't need Composer ready).
```bash
gcloud storage cp \
  dataflow/weather_pipeline.py \
  gs://<PROJECT_ID>-dataflow/code/weather_pipeline.py
gcloud storage ls gs://<PROJECT_ID>-dataflow/code/   # verify
```

### 7.5 Upload the DAG (needs Composer ready)
Composer watches a dedicated GCS "DAG bucket"; dropping a .py there registers the DAG.
Find that bucket, then import:
```bash
gcloud composer environments describe weather-demo \
  --location=europe-west1 --format="get(config.dagGcsPrefix)"
# -> gs://europe-west1-weather-demo-xxxx-bucket/dags

gcloud composer environments storage dags import \
  --environment=weather-demo --location=europe-west1 \
  --source=dags/weather_pipeline_dag.py
```
Airflow re-parses the bucket every ~30s; the DAG then appears in the UI.

### 7.5.1 Troubleshooting: "Broken DAG" — removed operator
After import, the environment page showed a red **Broken DAG** banner:
```
ImportError: cannot import name 'DataflowStartPythonJobOperator'
  from 'airflow.providers.google.cloud.operators.dataflow'
```
**Root cause:** the source doc uses `DataflowStartPythonJobOperator`, which was deprecated
and **removed** from apache-airflow-providers-google (v5+). Current Composer ships a newer
provider, so the import fails and Airflow refuses to load the whole file (it never appears in
the UI). The environment itself was healthy — purely our DAG code.

**Fix:** switch to the current API — `BeamRunPythonPipelineOperator` (from the Apache Beam
provider) + `DataflowConfiguration` (job_name/project/location/wait_until_finished):
```python
from airflow.providers.apache.beam.operators.beam import BeamRunPythonPipelineOperator
from airflow.providers.google.cloud.operators.dataflow import DataflowConfiguration
...
run_dataflow = BeamRunPythonPipelineOperator(
    task_id="transform_weather_with_dataflow",
    runner="DataflowRunner",
    py_file=f"gs://{DATAFLOW_BUCKET}/code/weather_pipeline.py",
    py_interpreter="python3",
    py_requirements=["apache-beam[gcp]==2.75.0"],   # worker self-installs beam to submit
    pipeline_options={ temp/staging/service_account/input/output_table },
    dataflow_config=DataflowConfiguration(job_name="weather-{{ ds_nodash }}",
        project_id=PROJECT_ID, location=REGION, wait_until_finished=True),
)
```
Re-import the DAG (overwrites), Refresh -> banner clears, `weather_demo_pipeline` appears.
**Note:** `py_requirements` makes the task install beam in a temp venv on first run (a few
min) before submitting — expected, not a hang.
**Lesson:** provider operators churn across versions; when a DAG breaks on import in managed
Airflow, suspect a moved/removed operator and check the current provider docs.

### 7.5.2 Troubleshooting: date-interval mismatch (scheduled run fails)
On unpause, Airflow auto-ran the latest *scheduled* interval. Its **logical date `{{ ds }}` =
2026-07-11** (Airflow's data-interval convention: a run firing at 08:00 on the 12th represents
the interval whose START is the 11th). But ingestion writes to `load_date=2026-07-12` (actual
today), so the Dataflow input glob `load_date=2026-07-11/*.json` matched **no files** ->
`transform_weather_with_dataflow` failed (red), and `build_daily_summary`/`check`/`end` went
**orange = upstream_failed** (skipped because a parent failed). Red = this task broke; orange =
something upstream broke. **Fix:** trigger the DAG **manually** (▶ on the DAG page) — a manual
run's logical date = now -> `ds` = today -> matches the file. (Doc §9 caveat, confirmed live.)

### 7.5.3 Troubleshooting: transform task OOM (worker evicted)
The manual run's `transform_weather_with_dataflow` went `up_for_retry`, then failed both
attempts. Attempt-1 log **cut off mid-install** (last line: "Successfully uninstalled
setuptools") yet the task ran ~7 more min in silence before dying; attempt-2 had **no logs**
("worker executing it might have finished abnormally (e.g. was evicted)"). That truncation +
"evicted" is the signature of an **OOM kill**. Cause: `py_requirements=["apache-beam[gcp]==
2.75.0"]` pip-installs the whole `[gcp]` extra (pyarrow 47MB, numpy, grpcio, aiplatform,
spanner, bigtable, vision...) into an ephemeral venv **on the ~2GB Composer worker**, on top
of Airflow itself -> memory ceiling exceeded -> pod killed before it can log an error.
**Fix — give the worker more memory, then re-run the task:**
```bash
gcloud composer environments update weather-demo \
  --location europe-west1 --worker-cpu 1 --worker-memory 4 --worker-storage 1
```
(~15-20 min env update, small extra cost.) Then in the Airflow UI: `transform_weather_with_
dataflow` -> **Clear task** (Downstream) to re-queue it (auto-retries were spent). It cascades
to build_summary -> check -> end.
**Lesson:** launching Beam from an Airflow worker via `py_requirements` is memory-heavy; the
robust production pattern is a Dataflow **Flex Template** (worker just calls an API, no local
beam install) or a right-sized worker.
**Resolved (confirmed live):** after the 4GB bump, Monitoring → Workers → *Total workers memory
usage* showed the limit step 2GiB→4GiB and usage peak at **2.06 GiB** — i.e. it sailed past the
old 2GiB wall that had been killing it. Attempt **3** of `transform_weather_with_dataflow` then
succeeded: Beam graph built, Dataflow job `weather-20260712-...` created, polled
`JOB_STATE_PENDING → JOB_STATE_RUNNING → JOB_STATE_DONE`, and the whole DAG went green
(build_daily_summary → check_observation_count → end). Where to *see* the OOM proof:
Composer env → **Monitoring** tab → **Workers** → memory graph (usage pinned to the limit) +
**Worker Pod evictions** / **container restarts** ticking to 1. Airflow itself never says "OOM";
the infra graphs are the ground truth.
**Gotcha to watch:** `--worker-storage 1` drops the disk limit 10GiB→1GiB. The `[gcp]` install
is disk-heavy too; if a future run dies with *"No space left on device"* / disk-pressure instead
of OOM, bump `--worker-storage` back to 5–10.

### 7.6 Trigger + watch (Airflow UI)
Console → Composer → weather-demo → **Open Airflow UI**. Find `weather_demo_pipeline`,
**unpause**, **Trigger DAG** — trigger on **today's date** (so `load_date={{ ds }}` matches the
file ingestion writes; doc §9 caveat). Grid/Graph view → follow each task green:
`execute_cloud_run_ingestion → transform_weather_with_dataflow → build_daily_summary →
check_observation_count`. Open a task's **Logs** to read what it did (and practice reading a
FAILED task's logs — a "definition of done" item).

### 7.6 Result (confirmed live)
DAG `weather_demo_pipeline` ran GREEN end-to-end on the manual run (logical date 2026-07-12):
`start → execute_cloud_run_ingestion → transform_weather_with_dataflow (attempt 3, after the
4GB OOM fix) → build_daily_summary → check_observation_count → end`. Dataflow job
`weather-20260712-...` polled `PENDING → RUNNING → DONE`. Verified in BigQuery: 20
`weather_observations` rows for the day + 4 `weather_daily_summary` rows (record_count=5/city).
NB the pipeline APPENDS (`WRITE_APPEND`), so repeated ingestion runs produce duplicate
`(observed_at, city)` rows — a real pipeline would dedup; `data_quality_checks.sql`'s
`no_duplicate_observation` would now flag them.

### 7.7 TEARDOWN Composer IMMEDIATELY (stop the billing) — DONE
As soon as we'd inspected the run, destroyed just Composer (left cheap infra up):
```bash
cd terraform
terraform destroy -target=google_composer_environment.weather   # yes  -> ~6m34s
gcloud composer environments list --locations=europe-west1       # -> Listed 0 items (verified)
```
`-target` destroys ONE resource; the rest of the stack stays. Single most important cost action
in the project. `composer.tf` stays in the config so the env is recreatable next session.

### 7.8 Clean up orphaned auto-created buckets
Managed services silently create their own scratch buckets that Terraform never sees, so they
LINGER after teardown. After destroying Composer we had two orphans:
- `europe-west1-weather-demo-<hash>-bucket` — Composer's DAG/logs/plugins bucket.
- `<PROJECT_ID>_cloudbuild` — Cloud Build's source+logs bucket from the Phase-4 image build.
```bash
gcloud storage rm -r gs://europe-west1-weather-demo-<hash>-bucket
gcloud storage rm -r gs://<PROJECT_ID>_cloudbuild
gcloud storage buckets list --format="value(name)" | grep weather-demo
# -> only <PROJECT_ID>-dataflow + <PROJECT_ID>-weather-raw remain (our 2 managed)
```
(The `_cloudbuild` bucket is recreated automatically on the next image build — normal, not a leak.)

## Phase 8 — Full teardown + README (every session end)
Composer (the only pricey piece) is GONE; what remains is cheap/free-tier scale-to-zero (2
buckets, BQ dataset+2 tables, Cloud Run job, Artifact Registry, IAM) — safe to leave idle at
~near-zero cost. Options at session end:
```bash
terraform destroy          # yes  -> removes ALL remaining resources (cleanest)
# verify nothing lingers:
gcloud composer environments list --locations=europe-west1
gcloud run jobs list --region=europe-west1
gcloud dataflow jobs list --region=europe-west1
gcloud storage buckets list --project=<PROJECT_ID>
```
Strongest guarantee = delete the whole throwaway project (`gcloud projects delete
<PROJECT_ID>`), which removes 100% and stops all billing. README.md (the "what is
this") gets written at the very end, AFTER everything is proven, so it never describes a moving target.

## Session close — 2026-07-12
Pipeline fully built + run end-to-end incl. the Composer capstone (green), then Composer
destroyed + orphan buckets cleaned same session. Standing state: 36 Terraform resources
(Composer removed from state but still in config), 2 managed buckets, all cheap/scale-to-zero.
Remaining TODO next session: decide full `terraform destroy` vs keep, then write README.md.
