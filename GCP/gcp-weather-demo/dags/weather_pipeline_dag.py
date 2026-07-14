import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.google.cloud.operators.cloud_run import (
    CloudRunExecuteJobOperator,
)
from airflow.providers.apache.beam.operators.beam import (
    BeamRunPythonPipelineOperator,
)
from airflow.providers.google.cloud.operators.dataflow import (
    DataflowConfiguration,
)
from airflow.providers.google.cloud.operators.bigquery import (
    BigQueryInsertJobOperator,
    BigQueryCheckOperator,
)
from airflow.operators.empty import EmptyOperator

# Config comes from the Composer environment's env_variables (set in composer.tf).
# Reading them here (not hard-coding) keeps the DAG portable across environments.
PROJECT_ID = os.environ["WEATHER_PROJECT"]
REGION = os.environ["WEATHER_REGION"]
RAW_BUCKET = os.environ["RAW_BUCKET"]
DATAFLOW_BUCKET = os.environ["DATAFLOW_BUCKET"]
DATAFLOW_SA = os.environ["DATAFLOW_SA"]
BQ_DATASET = os.environ["BQ_DATASET"]
BQ_OBSERVATIONS = os.environ["BQ_OBSERVATIONS"]
BQ_DAILY_SUMMARY = os.environ["BQ_DAILY_SUMMARY"]
CLOUD_RUN_JOB = os.environ["CLOUD_RUN_JOB"]

DAG_ID = "weather_demo_pipeline"

default_args = {
    "owner": "data-eng",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id=DAG_ID,
    description="Fetch, transform and analyse weather data",
    start_date=datetime(2026, 7, 1),
    schedule="0 8 * * *",       # daily at 08:00 (cron); catchup=False = no backfill
    catchup=False,
    default_args=default_args,
    tags=["demo", "gcp", "weather"],
) as dag:

    start = EmptyOperator(task_id="start")

    # 1. Run the Cloud Run ingestion job (fetch weather -> NDJSON in raw bucket).
    execute_ingestion = CloudRunExecuteJobOperator(
        task_id="execute_cloud_run_ingestion",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=CLOUD_RUN_JOB,
        deferrable=False,
    )

    # 2. Launch the Dataflow pipeline (raw NDJSON -> parsed rows in BigQuery).
    #    Reads the pipeline code Composer picks up from gs://.../code/.
    run_dataflow = BeamRunPythonPipelineOperator(
        task_id="transform_weather_with_dataflow",
        runner="DataflowRunner",
        py_file=f"gs://{DATAFLOW_BUCKET}/code/weather_pipeline.py",
        py_options=[],
        py_interpreter="python3",
        # The Composer worker only SUBMITS the job (Beam then runs on Dataflow
        # VMs), but it still needs the beam SDK locally to build the graph.
        # Self-install it in an ephemeral venv, pinned to the version we tested.
        py_requirements=["apache-beam[gcp]==2.75.0"],
        pipeline_options={
            "temp_location": f"gs://{DATAFLOW_BUCKET}/temp",
            "staging_location": f"gs://{DATAFLOW_BUCKET}/staging",
            "service_account_email": DATAFLOW_SA,
            # {{ ds }} = the DAG run's logical date -> matches today's raw folder.
            "input": f"gs://{RAW_BUCKET}/raw/load_date={{{{ ds }}}}/*.json",
            "output_table": f"{PROJECT_ID}:{BQ_DATASET}.{BQ_OBSERVATIONS}",
        },
        # project_id + location come from here and are injected into the pipeline.
        dataflow_config=DataflowConfiguration(
            job_name="weather-{{ ds_nodash }}",
            project_id=PROJECT_ID,
            location=REGION,
            wait_until_finished=True,
        ),
    )

    # 3. Rebuild the daily summary for this run's date (idempotent DELETE+INSERT).
    build_summary = BigQueryInsertJobOperator(
        task_id="build_daily_summary",
        configuration={
            "query": {
                "query": f"""
                    DELETE FROM
                      `{PROJECT_ID}.{BQ_DATASET}.{BQ_DAILY_SUMMARY}`
                    WHERE observation_date = DATE('{{{{ ds }}}}');

                    INSERT INTO
                      `{PROJECT_ID}.{BQ_DATASET}.{BQ_DAILY_SUMMARY}`
                    (
                      observation_date,
                      city,
                      record_count,
                      avg_temperature_c,
                      avg_humidity_pct,
                      avg_wind_speed_kmh
                    )
                    SELECT
                      DATE(observed_at),
                      city,
                      COUNT(*),
                      ROUND(AVG(temperature_c), 2),
                      ROUND(AVG(humidity_pct), 2),
                      ROUND(AVG(wind_speed_kmh), 2)
                    FROM
                      `{PROJECT_ID}.{BQ_DATASET}.{BQ_OBSERVATIONS}`
                    WHERE DATE(observed_at) = DATE('{{{{ ds }}}}')
                    GROUP BY 1, 2
                """,
                "useLegacySql": False,
            }
        },
        location="EU",
    )

    # 4. Data-quality gate: fail the DAG if fewer than 4 rows landed for the day.
    check_rows = BigQueryCheckOperator(
        task_id="check_observation_count",
        sql=f"""
            SELECT COUNT(*) >= 4
            FROM `{PROJECT_ID}.{BQ_DATASET}.{BQ_OBSERVATIONS}`
            WHERE DATE(observed_at) = DATE('{{{{ ds }}}}')
        """,
        use_legacy_sql=False,
        location="EU",
    )

    end = EmptyOperator(task_id="end")

    (
        start
        >> execute_ingestion
        >> run_dataflow
        >> build_summary
        >> check_rows
        >> end
    )
