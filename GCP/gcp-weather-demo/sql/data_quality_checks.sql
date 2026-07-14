-- ---------------------------------------------------------------------------
-- Data-quality checks: one row per assertion, each PASS/FAIL.
--
-- Idea: each check counts VIOLATIONS (rows that break a rule). 0 = healthy.
-- We UNION them into a single result so one query gives a full "report card".
-- In a real pipeline you'd fail the job if any status = 'FAIL'.
-- ---------------------------------------------------------------------------
WITH checks AS (

  -- 1. REQUIRED columns must never be NULL (schema enforces this, but verify).
  SELECT 'no_null_required' AS check_name,
         COUNTIF(observed_at IS NULL OR ingested_at IS NULL OR city IS NULL) AS violations
  FROM `your-project-id.weather_demo.weather_observations`

  UNION ALL

  -- 2. No duplicate observation for the same city at the same instant.
  SELECT 'no_duplicate_observation',
         (SELECT COUNT(*) FROM (
            SELECT observed_at, city
            FROM `your-project-id.weather_demo.weather_observations`
            GROUP BY observed_at, city
            HAVING COUNT(*) > 1
         ))

  UNION ALL

  -- 3. Temperature within a physically sane range (deg C).
  SELECT 'temperature_in_range',
         COUNTIF(temperature_c < -60 OR temperature_c > 60)
  FROM `your-project-id.weather_demo.weather_observations`

  UNION ALL

  -- 4. Humidity is a percentage: 0..100.
  SELECT 'humidity_in_range',
         COUNTIF(humidity_pct < 0 OR humidity_pct > 100)
  FROM `your-project-id.weather_demo.weather_observations`

  UNION ALL

  -- 5. Wind speed is non-negative.
  SELECT 'wind_speed_non_negative',
         COUNTIF(wind_speed_kmh < 0)
  FROM `your-project-id.weather_demo.weather_observations`

  UNION ALL

  -- 6. Reconciliation: every source row is accounted for in the summary.
  --    |source rows - sum(record_count)| must be 0.
  SELECT 'summary_reconciles_source',
         ABS(
           (SELECT COUNT(*)          FROM `your-project-id.weather_demo.weather_observations`)
         - (SELECT IFNULL(SUM(record_count), 0) FROM `your-project-id.weather_demo.weather_daily_summary`)
         )
)
SELECT
  check_name,
  violations,
  IF(violations = 0, 'PASS', 'FAIL') AS status
FROM checks
ORDER BY check_name;
