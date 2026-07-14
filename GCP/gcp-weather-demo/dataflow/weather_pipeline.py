import argparse
import json
import logging
from datetime import datetime, timezone
from typing import Any

import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, SetupOptions


class ParseWeatherRecord(beam.DoFn):
    def process(self, line: str, source_file: str):
        try:
            record: dict[str, Any] = json.loads(line)

            required = ["observed_at", "ingested_at", "city"]
            missing = [f for f in required if record.get(f) in (None, "")]
            if missing:
                logging.warning("Skipping record missing %s: %s", missing, line)
                return

            observed_at = record["observed_at"]
            # Open-Meteo returns e.g. "2026-07-12T07:30" (no seconds, no zone).
            # BigQuery TIMESTAMP needs a zone, so normalize to ...:00Z.
            if not observed_at.endswith("Z"):
                observed_at = (
                    f"{observed_at}:00Z" if len(observed_at) == 16 else f"{observed_at}Z"
                )

            yield {
                "observed_at": observed_at,
                "ingested_at": record.get(
                    "ingested_at", datetime.now(timezone.utc).isoformat()
                ),
                "city": record["city"],
                "country": record.get("country"),
                "latitude": record.get("latitude"),
                "longitude": record.get("longitude"),
                "temperature_c": record.get("temperature_c"),
                "humidity_pct": record.get("humidity_pct"),
                "wind_speed_kmh": record.get("wind_speed_kmh"),
                "source_file": source_file,
            }

        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            logging.warning("Invalid record: %s; error=%s", line, exc)


def run() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output_table", required=True)
    known_args, pipeline_args = parser.parse_known_args()

    pipeline_options = PipelineOptions(pipeline_args)
    pipeline_options.view_as(SetupOptions).save_main_session = True

    schema = {
        "fields": [
            {"name": "observed_at", "type": "TIMESTAMP", "mode": "REQUIRED"},
            {"name": "ingested_at", "type": "TIMESTAMP", "mode": "REQUIRED"},
            {"name": "city", "type": "STRING", "mode": "REQUIRED"},
            {"name": "country", "type": "STRING", "mode": "NULLABLE"},
            {"name": "latitude", "type": "FLOAT", "mode": "NULLABLE"},
            {"name": "longitude", "type": "FLOAT", "mode": "NULLABLE"},
            {"name": "temperature_c", "type": "FLOAT", "mode": "NULLABLE"},
            {"name": "humidity_pct", "type": "INTEGER", "mode": "NULLABLE"},
            {"name": "wind_speed_kmh", "type": "FLOAT", "mode": "NULLABLE"},
            {"name": "source_file", "type": "STRING", "mode": "NULLABLE"},
        ]
    }

    with beam.Pipeline(options=pipeline_options) as pipeline:
        (
            pipeline
            | "Read raw JSON" >> beam.io.ReadFromText(known_args.input)
            | "Parse and validate"
            >> beam.ParDo(ParseWeatherRecord(), source_file=known_args.input)
            | "Write to BigQuery"
            >> beam.io.WriteToBigQuery(
                known_args.output_table,
                schema=schema,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
            )
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
