# AWS Weather Pipeline — RUNBOOK (dbt + Athena)

Teach-first port of the GCP weather demo. Same business task, AWS services + dbt.
Region: `eu-central-1` (Frankfurt). This is the step-by-step build log — follow it to
recreate the whole stack from scratch.

> **Placeholders.** Replace every `<...>` with your own value:
>
> | Placeholder | What it is | How to obtain |
> |---|---|---|
> | `<ACCOUNT_ID>` | Your 12-digit AWS account ID | `aws sts get-caller-identity --query Account --output text` (or top-right of the console) |
> | `<your-email>` | Account root / Identity Center user email | your own |
> | `<sso-user>` | Your IAM Identity Center username | IAM Identity Center → Users |
> | `<account-alias>` | Optional friendly account alias | IAM dashboard → "Account Alias" (or pick one) |
> | `<your-directory>` | SSO portal subdomain in `https://<...>.awsapps.com/start` | IAM Identity Center → Settings → "AWS access portal URL" |
> | `<sso-instance-id>` | Identity Center instance (`ssoins-...`) | `aws sso-admin list-instances --query 'Instances[0].InstanceArn'` |
> | `<org-id>` | AWS Organizations ID (`o-...`) | `aws organizations describe-organization --query 'Organization.Id' --output text` |
> | `<sso-role-id>` | Random suffix in the assumed-role ARN | printed by `aws sts get-caller-identity` after `aws sso login` |
>
> S3 bucket names below embed `<ACCOUNT_ID>` purely for global uniqueness — substitute yours.

**Business task (identical to GCP):** daily batch — fetch Open-Meteo current weather for 4
cities (Vilnius, Riga, Tallinn, Warsaw) → raw NDJSON in S3 at
`raw/load_date=YYYY-MM-DD/weather_*.json` → parse/validate/normalize (dbt staging) →
land typed *observations* (Parquet in S3, Glue table) → per-date+city daily summary →
6 data-quality checks (dbt tests) → orchestrate daily 08:00.

## GCP → AWS mapping
| GCP (done) | AWS | Role |
|---|---|---|
| Cloud Run job | Lambda (zip) | fetch → NDJSON → S3 |
| GCS | S3 raw bucket | object storage |
| Dataflow/Beam | dbt-on-Athena | parse/validate → SQL staging model |
| BigQuery | Athena (engine) + Glue Catalog (schema) + Parquet in S3 (storage) | warehouse split |
| BQ summary + DQ SQL | dbt models + dbt tests | transform + quality gate |
| Composer | Step Functions + EventBridge (free) + MWAA (costly capstone) | orchestration |
| Terraform google | Terraform hashicorp/aws ~> 5.0 | IaC |
| SA + IAM bindings | IAM roles per workload | identity |

---

## Phase 0 — Account & guardrails  (STATUS: DONE)
- [x] Account (existing, not fresh): alias **<account-alias>**, ID **<ACCOUNT_ID>**, root email <your-email>.
      Existing account → 12-mo free tier may be expired; irrelevant at our KB/MB scale (~$0 anyway).
- [x] Root MFA registered (authenticator app).
- [x] AWS Budget `weather-demo-budget` $10/mo, 3 alerts (50/90/100% actual), email both addrs. OK/Healthy.
- [x] Region pinned to `eu-central-1` (console default at signin was us-east-2)
- Checkpoint: budget active; `aws sts get-caller-identity` (Phase 1) confirms account <ACCOUNT_ID>.

## Phase 1 — Local tooling & auth  (STATUS: DONE)
- [x] AWS CLI v2 installed via official .pkg → `aws-cli/2.35.21 Python/3.14.6 Darwin/21.6.0 x86_64`.
- AUTH: chose **IAM Identity Center (SSO)** over access key (best practice, no static secret on disk).
- [x] IAM Identity Center enabled (org instance). Portal URL **https://<your-directory>.awsapps.com/start**,
      Primary Region eu-central-1, instance <sso-instance-id>, Org <org-id>, dir = Identity Center.
- [x] Permission set `AdministratorAccess` (8h session) + user `<sso-user>` (<your-email>, MFA) +
      assignment <sso-user> → <account-alias>/<ACCOUNT_ID> → AdministratorAccess (provisioned the SSO IAM role).
- [x] `aws configure sso` → profile **weather-demo**, sso-session **weather-demo-sso**, start URL
      https://<your-directory>.awsapps.com/start, SSO region eu-central-1, client region eu-central-1, json.
      Written to ~/.aws/config (NO ~/.aws/credentials static key). 8h token → refresh via `aws sso login`.
- [x] Checkpoint PASSED: `aws sts get-caller-identity --profile weather-demo` →
      Account <ACCOUNT_ID>, Arn assumed-role/AWSReservedSSO_AdministratorAccess_<sso-role-id>/<sso-user>.
- Terraform/dbt must reference profile `weather-demo` (provider profile / AWS_PROFILE).

## Phase 2 — Terraform scaffolding  (STATUS: DONE)
- Files created under `terraform/` (mirrors GCP layout, provider google→aws):
  - `versions.tf`: `required_version >= 1.7`; provider `hashicorp/aws ~> 5.0`; provider block sets
    `region`, `profile = var.aws_profile` (SSO creds inherited), and **`allowed_account_ids=[account_id]`**
    (hard-errors if creds resolve to a different account — wrong-target safety rail).
  - `variables.tf`: `account_id` (NO default = explicit target), `region` (def eu-central-1),
    `aws_profile` (def weather-demo), `name_prefix` (def weather-demo; buckets append account_id).
  - `terraform.tfvars` (gitignored): account_id <ACCOUNT_ID>, region eu-central-1, profile weather-demo.
  - `.gitignore`: adapted from GCP (state/tfvars/venv ignored; `.terraform.lock.hcl` KEPT/committed;
    + dbt logs/target/dbt_packages + ingestion/*.zip).
- [x] `terraform init` → provider **hashicorp/aws v5.100.0** installed, .terraform.lock.hcl written (commit it).
- [x] `terraform validate` → "Success! The configuration is valid."
## Phase 3 — Foundation apply  (STATUS: DONE)
Split into 3a (storage+catalog) and 3b (IAM roles).
### 3a — storage + catalog (`main.tf`, `outputs.tf`)
- S3 x3: `weather-demo-{raw,curated,athena-results}-<ACCOUNT_ID>` (account_id suffix = global uniqueness).
  All: public-access-block (all 4 true), force_destroy=true. raw+results: 7-day lifecycle expiry.
  curated persists (= warehouse storage). raw=landing NDJSON.
- Glue database `weather_demo` (dataset analog) + Glue external table `raw_weather` over s3://<raw>/raw/:
  OpenX JSON SerDe (ignore.malformed.json=true = DoFn drop-bad-line), partition projection on load_date
  (type=date, format yyyy-MM-dd, range 2026-01-01,NOW, storage.location.template) → NO crawler/MSCK.
  All 9 cols STRING (truly raw; dbt staging casts). THE split: S3=storage, Glue=schema, Athena=engine.
- Athena workgroup `weather-demo-wg` (enforce_workgroup_configuration=true, results → s3://<results>/output/).
- ECR repo `weather-demo` (force_delete, scan_on_push=false) — holds dbt container for Phase 7.
- HCL gotcha fixed: Glue `columns` blocks must be multi-line (one attr per line).
- [x] `apply` → **12 resources added**. Outputs: raw=weather-demo-raw-<ACCOUNT_ID>,
  curated=weather-demo-curated-<ACCOUNT_ID>, results=weather-demo-athena-results-<ACCOUNT_ID>,
  glue_database=weather_demo, glue_raw_table=raw_weather, workgroup=weather-demo-wg,
  **ecr_url=<ACCOUNT_ID>.dkr.ecr.eu-central-1.amazonaws.com/weather-demo**. Standing cost ~$0.
  (S3 lifecycle configs took ~56s = S3 eventual-consistency retry, normal.)
### 3b — IAM roles (`iam.tf`)  (STATUS: in progress)
- Design: create only the 2 DATA-PLANE roles now (fully scopeable vs existing resources); defer the
  2 ORCHESTRATION roles (Step Functions, EventBridge) to Phase 7 (their target ARNs don't exist yet).
- Role 1 `weather-demo-lambda-ingest`: trust lambda.amazonaws.com; AWSLambdaBasicExecutionRole (logs)
  + inline s3:PutObject on <raw>/raw/* ONLY.
- Role 2 `weather-demo-dbt-athena` (the compute-vs-data lesson = GCP dataEditor-vs-jobUser): trust
  lambda; logs; inline = (a) Athena on workgroup ARN, (b) Glue get/create/update/delete Table+Partition
  on catalog+db weather_demo+tables, (c) S3 read raw + rw curated+results. Any one missing → different break.
- Used aws_iam_policy_document data sources (typed policy builder). Outputs add both role ARNs.
- Pre-existing unrelated bucket in account: `some-preexisting-bucket` (2026-04-28) — NOT ours, leave at teardown.
- [x] apply → **6 resources added**. ARNs: role/weather-demo-lambda-ingest, role/weather-demo-dbt-athena.
- [x] Verified: each role = managed AWSLambdaBasicExecutionRole + 1 inline (put-raw-objects / dbt-athena-access).
- Teaching notes captured: IAM policy `Version 2012-10-17` = policy-language grammar version (always use it,
  enables policy variables); managed-policy ARN `arn:aws:iam::aws:policy/...` — `aws` in account slot =
  AWS-owned managed policy (vs your account id = customer-managed); IAM is global → empty region field.
## Phase 4 — Lambda ingestion  (STATUS: DONE)
- `ingestion/main.py`: ported GCP logic verbatim (4 cities, Open-Meteo current=temp/humidity/wind,
  timezone UTC, two-timestamp NDJSON record, path raw/load_date=YYYY-MM-DD/weather_<ts>Z.json).
  Swaps: requests→urllib (zero-dep zip; boto3 in runtime), GCS→boto3 s3.put_object. Handler `main.handler`,
  s3 client at module scope (warm reuse).
- Terraform: added `archive` provider (~>2.0) to versions.tf → `terraform init` again. `lambda.tf`:
  archive_file zips main.py → ingest.zip; aws_lambda_function `weather-demo-ingestion` py3.12 128MB 60s,
  role=lambda-ingest, env RAW_BUCKET, source_code_hash auto-redeploy. NO Docker (vs GCP Cloud Build). Output added.
- [x] init+plan(1 add)+apply. `aws lambda invoke` → StatusCode 200, records 4,
      object raw/load_date=2026-07-13/weather_20260713T114314Z.json (946 B).
- [x] Verified NDJSON: 4 records; observed_at "2026-07-13T11:30" (16 chars, NO sec/tz = THE quirk),
      ingested_at full ISO +00:00. CloudWatch REPORT: 743ms/128MB/97MB used/510ms init. ~$0.
- Log group `/aws/lambda/weather-demo-ingestion` = observability (Phase 7/8 surface failures here).
## Phase 5 — dbt transform (local-first)  (STATUS: DONE)
- dbt project files created under `dbt/`:
  - `dbt_project.yml` (profile weather_demo; staging +materialized=view),
    `profiles.yml` (athena; s3_staging_dir=results/dbt/, s3_data_dir=curated/, work_group weather-demo-wg,
    schema weather_demo, aws_profile_name weather-demo — SSO creds), `packages.yml` (dbt_utils >=1.1,<2).
  - `models/staging/_sources.yml`: source raw.raw_weather (the Glue external table Terraform owns).
  - `models/staging/stg_weather_observations.sql` (VIEW = the Beam ParseWeatherRecord DoFn in SQL):
    drop rows missing observed_at/ingested_at/city; normalize no-sec ts (len=16 → ||':00Z'); cast 10 types;
    source_file = Athena "$path" pseudo-col (= DoFn lineage stamp).
  - `models/observations.sql` (INCREMENTAL append, format=parquet, partitioned_by=[load_date]):
    the WRITE_APPEND analog → CTAS Parquet to curated S3 + dbt-managed Glue table. load_date derived from
    observed_at (partition col LAST). is_incremental() skips already-landed load_dates. append = dupes on
    re-run of same source = the duplicate-row DQ lesson.
- RUN (local against Athena = DirectRunner analog): dedicated `dbt/.venv`, pip dbt-core + dbt-athena-community,
  `dbt deps` → `dbt debug` → `dbt run --select stg_weather_observations` → `dbt run --select observations`.
- [x] `dbt/.venv` created; installed **dbt-core 1.11.12** + **dbt-athena-community (adapter athena 1.10.2)**,
      python 3.12.1. `dbt deps` → **dbt_utils 1.4.1** (package-lock.yml written).
- [x] `dbt debug` → all checks passed; Connection test OK (SSO profile weather-demo → Athena eu-central-1,
      schema weather_demo, workgroup weather-demo-wg, s3_staging_dir results/dbt/, s3_data_dir curated/).
- [x] `dbt run --select stg_weather_observations` (VIEW; no data moves).
      - BUG #1 (fixed): first run ERROR after 178s — `Unsupported Hive type: timestamp(3) with time zone`.
        Cause: `from_iso8601_timestamp()` returns a Trino tz-aware type; a Glue-catalog VIEW column must be
        a Hive type, which has no tz-aware timestamp. (Trino = the ENGINE, rich types; Glue/Hive = the
        SCHEMA registry, frozen ~2013 type vocab. Rich in flight, plain at rest.) The 178s was Athena
        retrying the failing DDL, not real work.
        Fix: wrap both ts exprs in `cast(... as timestamp)` (all data is UTC = Athena session zone → same
        instant, Hive-legal type). Re-run → OK in 3s.
- [x] Verified view via read-only SELECT (I ran it): 4 rows (Riga/Tallinn/Vilnius/Warsaw); numeric cols
      REAL not null (`23.3`, `71`, `56.9496`) → **OpenX SerDe number-coercion risk did NOT materialize**;
      observed_at normalized `2026-07-13 11:30:00.000`; ingested_at parsed with millis. All 4 checks pass.
- [x] `dbt run --full-refresh --select observations` (CTAS Parquet → curated S3 + Glue table).
      - BUG #2 (fixed): first `dbt run` succeeded (OK 4) but the table landed in the WRONG bucket —
        Glue location `s3://<RESULTS>/output/tables/<uuid>`, curated bucket EMPTY. Results bucket has a
        7-day lifecycle → our "warehouse" data would auto-delete in a week.
        Cause: workgroup had `enforce_workgroup_configuration = true`, which FORCES all query output
        (incl. CTAS data files) to the workgroup result location, OVERRIDING dbt's `s3_data_dir`. The
        enforced-workgroup guardrail and dbt's data-dir are mutually exclusive.
        Fix: Terraform set workgroup `enforce_workgroup_configuration = false` (workgroup still provides a
        DEFAULT result loc, but dbt now sets per-query locations: RESULTS→s3_staging_dir, CTAS DATA→
        s3_data_dir=curated). `terraform apply` (1 change) → `dbt run --full-refresh` (drops misplaced
        table + its files, recreates in curated).
      - [x] CONFIRMED relocated: Glue loc now `s3://<CURATED>/weather_demo/observations/<uuid>`; Parquet at
        `.../observations/<uuid>/load_date=2026-07-13/...` (partition folder = Hive/BQ DAY-partition layout).
      - ORPHANS for Phase 8b sweep: old CTAS scratch left in results bucket at
        `output/tables/a6f9350e-...-manifest.csv` (183B) + `.metadata` (81B). Harmless; 7-day lifecycle
        will expire them anyway. (CTAS always writes a manifest to the workgroup output loc = results.)
- GUARDRAILS checked: (1) `SELECT load_date, count(*) GROUP BY load_date` → `2026-07-13 | 4` (partition-
  projection date-format OK, no silent-empty). (2) SerDe numbers real (above). (3) SSO 8h token:
  `aws sso login --profile weather-demo` if auth fails.

### Read-only verification commands (how I check "together" — anatomy)
Athena's CLI is async 2-step: start a query (get an ID), then poll state / fetch results by that ID.
```bash
# 1) START — submit SQL, capture the execution ID. --work-group carries result-location + engine config.
QID=$(aws athena start-query-execution \
  --profile weather-demo \            # SSO named profile → short-lived creds from ~/.aws sso cache
  --work-group weather-demo-wg \       # runs in OUR workgroup (result loc, quotas)
  --query-string "SELECT ..." \
  --query 'QueryExecutionId' --output text)   # --query is CLIENT-SIDE JMESPath: pluck one field from the JSON

# 2) POLL state until SUCCEEDED (Athena runs async; results aren't ready at submit time)
aws athena get-query-execution --profile weather-demo --query-execution-id "$QID" \
  --query 'QueryExecution.Status.State' --output text     # QUEUED/RUNNING/SUCCEEDED/FAILED

# 3) FETCH the result rows once SUCCEEDED
aws athena get-query-results --profile weather-demo --query-execution-id "$QID" \
  --query 'ResultSet.Rows[].Data[].VarCharValue' --output text   # flatten rows→cells to tab-separated text
```
Note the two different `--query` meanings: the CLI's `--query` is a local JMESPath filter on the JSON
response (nothing to do with SQL); `--query-string` is the actual SQL. `sleep 4` between start and poll =
give Athena a moment (our queries finish in <3s; a real poll loop would re-check State until terminal).
Where-did-data-land checks: `aws glue get-table ... --query 'Table.StorageDescriptor.Location'` (the S3
path a Glue table points at) and `aws s3 ls s3://<bucket>/ --recursive` (what's physically there).
## Phase 6 — dbt marts + tests  (STATUS: DONE)
- `models/marts/weather_daily_summary.sql` (materialized='table', full-refresh CTAS Parquet → curated):
  GROUP BY load_date, city → record_count + round(avg temp/humidity/wind, 2). GCP create_summary.sql analog.
- [x] `dbt run --select weather_daily_summary` → OK 4. Verified 4 rows (Riga/Tallinn/Vilnius/Warsaw,
  2026-07-13, record_count=1 each, avgs = the single reading). Glue loc s3://curated/weather_demo/
  weather_daily_summary/<uuid> (workgroup fix holds).
- 6 DQ CHECKS → dbt tests (GCP data_quality_checks.sql analog), = 8 test nodes:
  - `models/_observations.yml`: #1 not_null ×3 (observed_at, city, temperature_c); #3 accepted_range temp
    -60..60; #4 humidity 0..100; #5 wind ≥0; #2 unique_combination_of_columns (city, observed_at) =
    the WRITE_APPEND dupe detector.
  - `tests/assert_summary_reconciles_source.sql`: #6 singular test (count(obs) == sum(record_count));
    singular test = a SELECT that must return ZERO rows to pass (query the BAD rows).
- [x] `dbt test` → PASS=8. [x] `dbt build` → PASS=11 (full DAG stg→observations→summary + tests inline,
  gate aborts on any fail = replaces BigQueryCheckOperator + report card in ONE command). NOTE: build's
  observations step showed `OK 0` = is_incremental() skipped the already-landed 2026-07-13 partition
  (append-dedup-by-load_date working).
- Deprecation fixed: dbt 1.11 wants generic-test args nested under `arguments:` key (accepted_range +
  unique_combination_of_columns updated in _observations.yml).
- UI available (not required): `dbt docs generate && dbt docs serve` → local static site at :8080 with
  interactive lineage DAG (raw_weather→stg→observations→summary), compiled SQL, tests. dbt Cloud = paid SaaS.
- HOW dbt discovers: build order from ref()/source() edges (topological sort, NOT hand-declared); tests
  auto-found from .yml data_tests: entries (schema tests) + tests/*.sql (singular). dbt tests ≈ Great
  Expectations (lighter); dbt ref-lineage ≈ OpenMetadata (project-scoped, not org-wide).
---

## DECISION (2026-07-14): stop hands-on build at Phase 6; document orchestration theoretically
Phases 1-6 are built and verified end-to-end (ingest → catalog → dbt transform → mart →
data-quality gate). The remaining orchestration phases are **documented, not executed**, because:
- **MWAA = managed Apache Airflow = the SAME engine as Cloud Composer**, which we already built,
  ran green, and debugged on the GCP track. Re-building it on AWS teaches ~nothing new
  conceptually and costs ~$0.49/hr + NAT. Skipped deliberately.
- **Step Functions** IS a genuinely different paradigm (serverless state machine, not a DAG
  scheduler) and is free — worth knowing, so it's written up below with the exact commands we
  *would* run, but left unbuilt to close the track.
Below: theory + "what we would run" for Phase 7 and 8a. Phase 8b (teardown) IS actionable.

## Phase 7 — Orchestration A: Step Functions + EventBridge  (THEORETICAL — not built)

### 7.0 Concept — how this differs from Airflow
Airflow (Composer/MWAA) = a scheduler that runs a Python-defined DAG on a persistent cluster.
**Step Functions** = a serverless **state machine**: you declare states (Task / Choice / Parallel /
Wait / Fail) in Amazon States Language (JSON/ASL); AWS runs them event-driven with no standing
compute. **EventBridge Scheduler** replaces Airflow's cron: a managed rule fires the state machine
on `cron(0 8 * * ? *)`. Cost: Step Functions Standard = 4,000 transitions/mo free (we'd use ~6/run);
EventBridge ~14M/mo free → effectively $0.

### 7.1 The prerequisite we deferred: run dbt somewhere headless
The ingestion Lambda already exists. dbt needs a runtime the state machine can invoke. Two options:
- **Lambda container image** (dbt-core + dbt-athena in a zip/image on the existing ECR repo
  `weather-demo`) — simplest, fits our free-tier goal, cold-start ~seconds. **Preferred.**
- **ECS Fargate task** — heavier, better if dbt run > 15 min Lambda ceiling (not our case).

What we'd build (CloudShell, so no local Docker):
```bash
# in CloudShell, from a checkout of dbt/
aws ecr get-login-password --region eu-central-1 \
  | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.eu-central-1.amazonaws.com
docker build -t weather-demo-dbt .          # Dockerfile: python:3.12-slim + pip dbt-athena-community + COPY dbt project
docker tag weather-demo-dbt:latest <ACCOUNT_ID>.dkr.ecr.eu-central-1.amazonaws.com/weather-demo:dbt
docker push <ACCOUNT_ID>.dkr.ecr.eu-central-1.amazonaws.com/weather-demo:dbt
```
Then a `aws_lambda_function "dbt_run"` (package_type=Image, image_uri=…:dbt, timeout 900, memory 1024,
role = existing `weather-demo-dbt-athena`, handler invokes `dbt build`).

### 7.2 Terraform we would add (the deferred orchestration IAM + resources)
- `aws_iam_role "sfn_exec"` — trust `states.amazonaws.com`; inline: `lambda:InvokeFunction` on the
  ingestion + dbt Lambdas, `logs:*` for the state-machine log group.
- `aws_iam_role "scheduler_exec"` — trust `scheduler.amazonaws.com`; inline: `states:StartExecution`
  on the state-machine ARN.
- `aws_sfn_state_machine "weather"` — ASL definition (see 7.3).
- `aws_scheduler_schedule "daily"` — `schedule_expression = "cron(0 8 * * ? *)"`,
  target = the state-machine ARN, role = scheduler_exec.

### 7.3 State-machine definition (ASL sketch)
```
Ingest (Task: invoke weather-demo-ingestion Lambda)
   → Transform (Task: invoke weather-demo dbt Lambda, cmd = "dbt build")
   → Succeed
   (Catch on either Task → Notify/Fail state)
```
`dbt build` in one step = ingest→stage→observations→summary→tests, gate aborts on any failing
test (this is the AWS analog of the Composer DAG's BigQueryCheckOperator + the whole chain, but
collapsed because dbt already owns the internal DAG + DQ gate).

### 7.4 What we would run to build + test
```bash
cd terraform
terraform plan      # expect: + sfn state machine, + schedule, + 2 IAM roles, + dbt Lambda
terraform apply     # yes

# manual test run (don't wait for 08:00):
ARN=$(terraform output -raw state_machine_arn)
aws stepfunctions start-execution --profile weather-demo --state-machine-arn "$ARN" \
  --name "manual-$(date +%Y%m%d-%H%M%S)"
# watch:
aws stepfunctions describe-execution --profile weather-demo --execution-arn <ARN from start> \
  --query 'status' --output text      # RUNNING → SUCCEEDED / FAILED
# verify data refreshed (same read-only Athena 2-step as Phase 5) + CloudWatch logs per Lambda.
```
Then let EventBridge fire it at 08:00 the next day and confirm a scheduled `SUCCEEDED` execution.
**Lesson we'd capture:** Step Functions is declarative/serverless (no cluster to size or OOM —
contrast the GCP Composer worker-memory saga); the trade-off is less rich in-flight Python logic
than an Airflow operator, which is exactly why we push all real work into Lambda + dbt.

## Phase 8a — Orchestration B: MWAA capstone  (SKIPPED — redundant with GCP Composer)
**Decision: not built.** MWAA is managed Apache Airflow — identical engine and DAG-authoring model
to the Cloud Composer capstone already completed on the GCP track. For completeness, what it *would*
have involved:
- Terraform `aws_mwaa_environment` requires a **VPC with ≥2 private subnets + a DAGs S3 bucket**
  (versioning on) — noticeably more infra than Composer's one-line environment. ~$0.49/hr for the
  smallest class + NAT gateway cost → the one genuinely paid piece; build + `terraform destroy`
  same session, like the GCP Composer capstone.
- Upload `dags/` to the DAG bucket; Airflow auto-registers.
- The DAG would swap GCP operators for AWS ones: `LambdaInvokeFunctionOperator` (ingestion) →
  an ECS/`LambdaInvokeFunctionOperator` running `dbt build` → done. Same Jinja `{{ ds }}` /
  cron / catchup=False patterns already practiced on Composer.
- Expected new-learning delta ≈ zero (only MWAA's VPC/networking setup differs); hence skipped.

## Phase 8b — Teardown + orphan sweep + README  (ACTIONABLE — do this to close out)
Standing cost is already ~$0 (S3/Glue/Athena/Lambda scale-to-zero; raw + results buckets self-expire
in 7 days). Clean teardown anyway for hygiene:
```bash
cd terraform
terraform destroy      # yes → removes all managed resources (buckets are force_destroy=true)

# orphan sweep (things Terraform never saw / other tools created):
aws s3 ls s3://weather-demo-athena-results-<ACCOUNT_ID>/output/tables/ --profile weather-demo
  # Phase 5 CTAS manifests (~183B+81B); 7-day lifecycle expires them, or delete now.
aws ecr list-images --repository-name weather-demo --profile weather-demo   # any dbt image pushed in 7.1
aws glue get-tables --database-name weather_demo --profile weather-demo 2>/dev/null || true  # gone after destroy
aws s3 ls --profile weather-demo | grep weather-demo   # confirm our 3 buckets gone

# leave alone (NOT ours): pre-existing bucket `some-preexisting-bucket` (2026-04-28).
```
Note: `.venv` dirs, dbt `target/`, `ingest.zip` are local/gitignored — no cloud cost, delete at leisure.
Strongest guarantee if desired: none needed here (no throwaway *account*, unlike GCP's throwaway
*project*) — `terraform destroy` + the orphan sweep is the complete stop.

Finally, write top-level `README.md` (the "what is this") once teardown is confirmed — it should
describe the *proven* Phase 1-6 pipeline + the GCP→AWS mapping table, and note orchestration as
"designed (Step Functions/EventBridge), MWAA intentionally omitted (covered on the GCP track)".

## Phase 8b — TEARDOWN DONE (2026-07-14)
- SSO token had expired (8h); `aws sso login --profile weather-demo` to refresh before teardown.
- `terraform destroy` → **19 destroyed** (3 S3 buckets w/ force_destroy wiped dbt Parquet+CTAS
  manifests inside; Glue db delete cascaded the dbt-created observations/stg/summary tables; Glue
  raw table, Athena workgroup, Lambda, 2 IAM roles, ECR repo).
- Verified clean (read-only): our 3 buckets gone; no Lambdas; Glue only AWS built-in `default`
  left; no `weather-demo*` IAM roles.
- Orphan swept: CloudWatch log group `/aws/lambda/weather-demo-ingestion` (Lambda auto-created,
  unmanaged by TF) → `aws logs delete-log-group ... --log-group-name /aws/lambda/weather-demo-ingestion`.
- NOT ours, left alone: pre-existing `some-preexisting-bucket`. No IAM access key to delete (SSO). No
  throwaway account to close. Optional: `aws sso logout`.
- Local files (terraform/, dbt/, ingestion/, runbook) intact → whole stack recreatable anytime.

## Session close — 2026-07-14
AWS track CLOSED. **Phases 1-6 built + verified** (Lambda ingest → Glue raw table → dbt staging
view → incremental Parquet observations → daily-summary mart → 8 dbt tests, `dbt build` green).
Orchestration (Phase 7 Step Functions/EventBridge, Phase 8a MWAA) **documented theoretically, not
built** — MWAA redundant with the GCP Composer capstone; Step Functions written up with exact
commands. **Phase 8b teardown DONE** (19 destroyed, verified clean, log-group orphan swept).
