import json
import os
from datetime import datetime, timezone

import requests
from google.cloud import storage

CITIES = [
    {"city": "Vilnius", "country": "Lithuania", "latitude": 54.6872, "longitude": 25.2797},
    {"city": "Riga", "country": "Latvia", "latitude": 56.9496, "longitude": 24.1052},
    {"city": "Tallinn", "country": "Estonia", "latitude": 59.4370, "longitude": 24.7536},
    {"city": "Warsaw", "country": "Poland", "latitude": 52.2297, "longitude": 21.0122},
]


def fetch_weather(city: dict) -> dict:
    response = requests.get(
        "https://api.open-meteo.com/v1/forecast",
        params={
            "latitude": city["latitude"],
            "longitude": city["longitude"],
            "current": "temperature_2m,relative_humidity_2m,wind_speed_10m",
            "timezone": "UTC",
        },
        timeout=30,
    )
    response.raise_for_status()

    payload = response.json()
    current = payload["current"]

    return {
        "observed_at": current["time"],
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        "city": city["city"],
        "country": city["country"],
        "latitude": city["latitude"],
        "longitude": city["longitude"],
        "temperature_c": current.get("temperature_2m"),
        "humidity_pct": current.get("relative_humidity_2m"),
        "wind_speed_kmh": current.get("wind_speed_10m"),
    }


def main() -> None:
    bucket_name = os.environ["RAW_BUCKET"]
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)

    now = datetime.now(timezone.utc)
    records = [fetch_weather(city) for city in CITIES]

    object_name = (
        f"raw/load_date={now:%Y-%m-%d}/"
        f"weather_{now:%Y%m%dT%H%M%SZ}.json"
    )

    # Newline-delimited JSON (NDJSON): one JSON object per line, convenient for Dataflow.
    content = "\n".join(json.dumps(record) for record in records)

    blob = bucket.blob(object_name)
    blob.upload_from_string(content, content_type="application/x-ndjson")

    print(
        json.dumps(
            {
                "bucket": bucket_name,
                "object": object_name,
                "records": len(records),
            }
        )
    )


if __name__ == "__main__":
    main()
