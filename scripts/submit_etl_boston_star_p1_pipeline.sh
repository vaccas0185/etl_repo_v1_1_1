#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
REGION="${2:-}"
PIPELINE_ROOT="${3:-}"
TEMPLATE_FILE_GCS_PATH="${4:-}"
TEMP_LOCATION="${5:-}"
INPUT_TABLE="${6:-}"
OUTPUT_TABLE="${7:-}"
SERVICE_ACCOUNT="${8:-}"

if [[ -z "${PROJECT_ID}" || -z "${REGION}" || -z "${PIPELINE_ROOT}" || -z "${TEMPLATE_FILE_GCS_PATH}" || -z "${TEMP_LOCATION}" || -z "${INPUT_TABLE}" || -z "${OUTPUT_TABLE}" ]]; then
  echo "Usage: $0 PROJECT_ID REGION PIPELINE_ROOT TEMPLATE_FILE_GCS_PATH TEMP_LOCATION INPUT_TABLE OUTPUT_TABLE [SERVICE_ACCOUNT]" >&2
  exit 1
fi

PIPELINE_PY="pipelines/etl_boston_star_p1_pipeline.py"
JOB_NAME="etl-boston-star-p1-$(date +%Y%m%d-%H%M%S)"

ARGS=(
  "--project=${PROJECT_ID}"
  "--region=${REGION}"
  "--file=${PIPELINE_PY}"
  "--pipeline-root=${PIPELINE_ROOT}"
  "--parameter=project_id=${PROJECT_ID}"
  "--parameter=region=${REGION}"
  "--parameter=template_file_gcs_path=${TEMPLATE_FILE_GCS_PATH}"
  "--parameter=temp_location=${TEMP_LOCATION}"
  "--parameter=input_table=${INPUT_TABLE}"
  "--parameter=output_table=${OUTPUT_TABLE}"
)

if [[ -n "${SERVICE_ACCOUNT:-}" ]]; then
  ARGS+=("--service-account=${SERVICE_ACCOUNT}")
fi

gcloud ai pipelines run "${JOB_NAME}" "${ARGS[@]}"
