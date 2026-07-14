import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3

CITIES = [
    {"city": "Vilnius", "country": "Lithuania", "latitude": 54.6872, "longitude": 25.2797},
    {"city": "Riga", "country": "Latvia", "latitude": 56.9496, "longitude": 24.1052},
    {"city": "Tallinn", "country": "Estonia", "latitude": 59.4370, "longitude": 24.7536},
    {"city": "Warsaw", "country": "Poland", "latitude": 52.2297, "longitude": 21.0122},
]

# Reused across warm invocations (best practice: create the client once at import).
s3 = boto3.client("s3")


def fetch_weather(city: dict) -> dict:
    query = urllib.parse.urlencode(
        {
            "latitude": city["latitude"],
            "longitude": city["longitude"],
            "current": "temperature_2m,relative_humidity_2m,wind_speed_10m",
            "timezone": "UTC",
        }
    )
    url = f"https://api.open-meteo.com/v1/forecast?{query}"
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))

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


def handler(event, context):
    bucket_name = os.environ["RAW_BUCKET"]

    now = datetime.now(timezone.utc)
    records = [fetch_weather(city) for city in CITIES]

    object_key = f"raw/load_date={now:%Y-%m-%d}/weather_{now:%Y%m%dT%H%M%SZ}.json"

    # Newline-delimited JSON (NDJSON): one JSON object per line.
    content = "\n".join(json.dumps(record) for record in records)

    s3.put_object(
        Bucket=bucket_name,
        Key=object_key,
        Body=content.encode("utf-8"),
        ContentType="application/x-ndjson",
    )

    result = {"bucket": bucket_name, "object": object_key, "records": len(records)}
    print(json.dumps(result))
    return result
