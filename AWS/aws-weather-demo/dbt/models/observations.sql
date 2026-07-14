-- The "land typed observations into the warehouse" step.
--   GCP analog: the Beam pipeline's WriteToBigQuery(WRITE_APPEND) sink.
--   Here: dbt CTAS writes Parquet files to curated S3, and a Glue table
--   (created/managed by dbt) makes them queryable. Athena = engine only;
--   S3 Parquet = storage; the Glue table = schema.
--
-- materialized='incremental' + incremental_strategy='append':
--   every run APPENDS the current staging rows (no dedupe). This is the exact
--   WRITE_APPEND analog and reproduces the duplicate-row DQ lesson from GCP:
--   invoke the ingest Lambda twice for the same load_date, run this twice,
--   and the daily summary's record_count doubles -> DQ test catches it.
--
-- partitioned_by=['load_date']: the BQ DAY-partition analog. Athena writes
--   one S3 folder per load_date; queries that filter on load_date prune folders
--   (partition pruning) = scan less = cheaper. This is a TABLE property set here
--   in the model config, NOT a bucket property.
--
-- format='parquet': columnar storage w/ per-row-group min/max stats
--   (predicate pushdown), distinct from the folder partitioning above.

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    format='parquet',
    partitioned_by=['load_date']
) }}

select
    observed_at,
    ingested_at,
    city,
    country,
    latitude,
    longitude,
    temperature_c,
    humidity_pct,
    wind_speed_kmh,
    source_file,

    -- partition column must be LAST in an Athena/Hive partitioned CTAS.
    -- derive the load_date from the observation timestamp so a row always
    -- lands in the folder for the day it describes.
    date_format(observed_at, '%Y-%m-%d') as load_date

from {{ ref('stg_weather_observations') }}

{% if is_incremental() %}
    -- on incremental runs, only pull staging rows we haven't landed yet.
    -- (append still allows dupes across runs of the SAME source file -- that's
    --  intentional, it's the WRITE_APPEND lesson -- this just avoids re-landing
    --  everything already in the table on every run.)
    where date_format(observed_at, '%Y-%m-%d') not in (
        select distinct load_date from {{ this }}
    )
{% endif %}
