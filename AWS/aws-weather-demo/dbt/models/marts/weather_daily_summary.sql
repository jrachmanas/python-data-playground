-- The analytics output: one row per (load_date, city) with the daily aggregates.
--   GCP analog: sql/create_summary.sql (the BigQuery summary table).
--
-- materialized='table' (full-refresh): every run DROPs and rebuilds the whole
--   table from observations. Unlike the append-incremental observations, the
--   summary is always a clean recompute of "current truth" -- no history, no
--   dupes of its own. CTAS Parquet -> curated S3 + Glue table, same as observations.

{{ config(materialized='table') }}

select
    load_date,
    city,
    count(*)                        as record_count,
    round(avg(temperature_c),  2)   as avg_temperature_c,
    round(avg(humidity_pct),   2)   as avg_humidity_pct,
    round(avg(wind_speed_kmh), 2)   as avg_wind_speed_kmh
from {{ ref('observations') }}
group by load_date, city
