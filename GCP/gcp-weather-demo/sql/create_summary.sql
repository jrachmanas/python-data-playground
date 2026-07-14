-- ---------------------------------------------------------------------------
-- Rebuild the per-day, per-city weather summary from raw observations.
--
-- Pattern: DELETE-then-INSERT, scoped to only the dates present in the source.
-- This makes the script IDEMPOTENT -- running it twice produces the same result
-- (it clears the days it is about to recompute, so no double-counting), while
-- leaving summary rows for other days untouched. This is the standard "refresh
-- the affected partitions" shape for a batch rollup.
-- ---------------------------------------------------------------------------

-- 1. Remove any existing summary rows for the day(s) we're recomputing.
DELETE FROM `your-project-id.weather_demo.weather_daily_summary`
WHERE observation_date IN (
  SELECT DISTINCT DATE(observed_at)
  FROM `your-project-id.weather_demo.weather_observations`
);

-- 2. Recompute and insert fresh aggregates.
INSERT INTO `your-project-id.weather_demo.weather_daily_summary`
  (observation_date, city, record_count,
   avg_temperature_c, avg_humidity_pct, avg_wind_speed_kmh)
SELECT
  DATE(observed_at)     AS observation_date,   -- event-time day (partition key of source)
  city,
  COUNT(*)              AS record_count,        -- how many observations rolled up
  AVG(temperature_c)    AS avg_temperature_c,
  AVG(humidity_pct)     AS avg_humidity_pct,
  AVG(wind_speed_kmh)   AS avg_wind_speed_kmh
FROM `your-project-id.weather_demo.weather_observations`
GROUP BY observation_date, city;
