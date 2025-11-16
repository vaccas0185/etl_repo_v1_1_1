#!/usr/bin/env python3
"""Cleanup helper for Vertex AI Pipeline + Dataflow + BigQuery + GCS + Artifact Registry resources."""

import argparse
from argparse import ArgumentParser
import json
import os
import shutil
import subprocess
from typing import Iterable, List, Optional

from google.cloud import aiplatform, bigquery, storage


def run_cmd(cmd: List[str], *, dry_run: bool = False) -> Optional[str]:
    if dry_run:
        print(f"[dry-run] {' '.join(cmd)}")
        return None
    print(f"[run] {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def get_project_number(project: str) -> str:
    return run_cmd(
        [
            "gcloud",
            "projects",
            "describe",
            project,
            "--format=value(projectNumber)",
        ],
        dry_run=False,
    )


def cancel_pipeline_job(
    project: str,
    location: str,
    pipeline_job: str,
    *,
    dry_run: bool = False,
) -> None:
    if not pipeline_job:
        return
    aiplatform.init(project=project, location=location)
    job = aiplatform.PipelineJob.get(resource_name=pipeline_job)
    if job.state.name in ("PIPELINE_STATE_RUNNING", "PIPELINE_STATE_QUEUED"):
        print("[info] canceling pipeline job …")
        if not dry_run:
            job.cancel()
    print("[info] deleting pipeline job resource …")
    if not dry_run:
        job.delete()
    else:
        print(f"[dry-run] PipelineJob.delete() on {pipeline_job}")


def cancel_dataflow_jobs(
    project: str,
    region: str,
    name_prefix: str,
    *,
    dry_run: bool = False,
) -> None:
    jobs_json = run_cmd(
        [
            "gcloud",
            "dataflow",
            "jobs",
            "list",
            "--project",
            project,
            "--region",
            region,
            "--filter",
            f"name:{name_prefix}",
            "--format",
            "json",
        ],
        dry_run=dry_run,
    )
    if not jobs_json:
        return
    jobs = json.loads(jobs_json)
    for job in jobs:
        job_id = job["id"]
        print(f"[info] canceling Dataflow job {job_id} …")
        run_cmd(
            [
                "gcloud",
                "dataflow",
                "jobs",
                "cancel",
                job_id,
                "--project",
                project,
                "--region",
                region,
            ],
            dry_run=dry_run,
        )


def delete_bigquery(
    project: str,
    location: str,
    datasets: Iterable[str],
    tables: Iterable[str],
    *,
    dry_run: bool = False,
) -> None:
    client = bigquery.Client(project=project, location=location)
    for table in tables:
        dataset_id, table_id = table.split(".")
        table_ref = client.dataset(dataset_id).table(table_id)
        print(f"[info] deleting BigQuery table {table}")
        if not dry_run:
            client.delete_table(table_ref, not_found_ok=True)
    for dataset in datasets:
        dataset_ref = client.dataset(dataset)
        print(f"[info] deleting BigQuery dataset {dataset}")
        if not dry_run:
            client.delete_dataset(dataset_ref, delete_contents=True, not_found_ok=True)


def delete_gcs_paths(paths: Iterable[str], *, dry_run: bool = False) -> None:
    client = storage.Client()
    for path in paths:
        if not path.startswith("gs://"):
            continue
        bucket_name, *parts = path[5:].split("/", 1)
        prefix = parts[0] if parts else None
        bucket = client.bucket(bucket_name)
        if prefix:
            prefix = prefix.strip("/")
            print(f"[info] removing objects under gs://{bucket_name}/{prefix}")
            blobs = bucket.list_blobs(prefix=prefix)
        else:
            print(f"[info] removing objects under gs://{bucket_name}")
            blobs = bucket.list_blobs()
        if dry_run:
            for blob in blobs:
                print(f"[dry-run] delete gs://{bucket_name}/{blob.name}")
            continue
        bucket.delete_blobs(list(blobs))


def delete_artifact_images(
    project: str,
    artifact_region: str,
    repository: str,
    image: str,
    *,
    dry_run: bool = False,
) -> None:
    image_uri = f"{artifact_region}-docker.pkg.dev/{project}/{repository}/{image}"
    cmd = [
        "gcloud",
        "artifacts",
        "docker",
        "images",
        "delete",
        image_uri,
        "--project",
        project,
        "--delete-tags",
        "--quiet",
    ]
    try:
        run_cmd(cmd, dry_run=dry_run)
    except subprocess.CalledProcessError as exc:
        print(f"[warn] failed to delete artifact image: {exc}")


def cleanup_local(paths: Iterable[str], *, dry_run: bool = False) -> None:
    for path in paths:
        if os.path.isfile(path):
            print(f"[info] removing file {path}")
            if not dry_run:
                os.remove(path)
        elif os.path.isdir(path):
            print(f"[info] removing directory {path}")
            if not dry_run:
                shutil.rmtree(path, ignore_errors=True)
        else:
            print(f"[info] skipping missing path {path}")


def parse_args() -> argparse.Namespace:
    parser = ArgumentParser(description="Cleanup cloud resources for the Boston Star P1 pipeline.")
    parser.add_argument("--project", required=True)
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--pipeline-job", default="", help="Vertex AI PipelineJob resource name.")
    parser.add_argument("--dataflow-name-prefix", default="boston-star-p1-flex")
    parser.add_argument("--artifact-region", default="us-west1")
    parser.add_argument("--artifact-repo", default="dataflow-sample-yw")
    parser.add_argument("--artifact-image", default="boston-star-p1-flex")
    parser.add_argument("--gcs-bucket", default="dataflow-sample-yw")
    parser.add_argument("--staging-prefix", default="")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    dry_run = args.dry_run
    project_number = get_project_number(args.project)
    staging_bucket = (
        args.staging_prefix
        or f"dataflow-staging-{args.location}-{project_number}"
    )

    cancel_pipeline_job(
        args.project,
        args.location,
        args.pipeline_job,
        dry_run=dry_run,
    )
    cancel_dataflow_jobs(
        args.project,
        args.location,
        args.dataflow_name_prefix,
        dry_run=dry_run,
    )
    delete_bigquery(
        args.project,
        "US",
        datasets=["raw", "star"],
        tables=["raw.boston_raw", "star.boston_fact_p1"],
        dry_run=dry_run,
    )
    delete_gcs_paths(
        [
            f"gs://{args.gcs_bucket}/boston_star_p1_flex.json",
            f"gs://{args.gcs_bucket}/pipeline_root/",
            f"gs://{args.gcs_bucket}/temp/",
            f"gs://{staging_bucket}/",
        ],
        dry_run=dry_run,
    )
    delete_artifact_images(
        args.project,
        args.artifact_region,
        args.artifact_repo,
        args.artifact_image,
        dry_run=dry_run,
    )
    cleanup_local([".venv", "__pycache__"], dry_run=dry_run)
    print("[info] cleanup script completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
