-- DQ check #6 (singular test): the summary must reconcile with its source.
--   Total observations landed == total record_count summed across the summary.
--   GCP analog: the reconciliation check in data_quality_checks.sql.
--
-- A dbt SINGULAR test is just a SELECT that should return ZERO rows to pass.
-- We return a row only when the two totals disagree, so a match = empty = pass.

with obs as (
    select count(*) as n_obs
    from {{ ref('observations') }}
),

summary as (
    select coalesce(sum(record_count), 0) as n_summary
    from {{ ref('weather_daily_summary') }}
)

select
    obs.n_obs,
    summary.n_summary
from obs
cross join summary
where obs.n_obs <> summary.n_summary
