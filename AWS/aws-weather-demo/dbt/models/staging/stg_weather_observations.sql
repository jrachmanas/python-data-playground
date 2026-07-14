-- The Beam ParseWeatherRecord DoFn, rewritten in SQL.
--   1) drop rows missing required fields (observed_at / ingested_at / city)
--   2) normalize the seconds-less timestamp: "2026-07-13T11:30" -> "...:00Z"
--   3) cast the all-string raw columns to real types
--   4) stamp lineage via the Athena "$path" pseudo-column (= DoFn source_file)

{{ config(materialized='view') }}

with raw as (

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
        "$path" as source_file
    from {{ source('raw', 'raw_weather') }}

),

-- (1) validation gate: same required-field check the DoFn did
filtered as (

    select *
    from raw
    where observed_at is not null and observed_at <> ''
      and ingested_at is not null and ingested_at <> ''
      and city is not null and city <> ''

)

select
    -- (2)+(3) normalize then cast to timestamp.
    -- from_iso8601_timestamp returns "timestamp(3) with time zone" (a Trino type);
    -- a Glue-catalog view column must be a Hive type, which has no tz-aware timestamp.
    -- All values are UTC (Athena session zone = UTC), so cast to plain `timestamp`
    -- keeps the same instant and yields a Hive-legal column type.
    cast(
        from_iso8601_timestamp(
            case
                when length(observed_at) = 16 then observed_at || ':00Z'
                else observed_at || 'Z'
            end
        ) as timestamp
    ) as observed_at,
    cast(from_iso8601_timestamp(ingested_at) as timestamp) as ingested_at,

    city,
    country,
    cast(latitude as double)       as latitude,
    cast(longitude as double)      as longitude,
    cast(temperature_c as double)  as temperature_c,
    cast(humidity_pct as integer)  as humidity_pct,
    cast(wind_speed_kmh as double) as wind_speed_kmh,

    -- (4) lineage stamp
    source_file
from filtered
