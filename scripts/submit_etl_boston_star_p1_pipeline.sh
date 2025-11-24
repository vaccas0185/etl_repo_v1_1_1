#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
REGION="${2:-us-central1}"
PIPELINE_ROOT="${3:-}"
TEMPLATE_FILE_GCS_PATH="${4:-}"
TEMP_LOCATION="${5:-}"
INPUT_TABLE="${6:-}"
OUTPUT_TABLE="${7:-}"
# デフォルトでは setup.sh が作成した実行専用サービスアカウントを使用
SERVICE_ACCOUNT="${8:-}"

if [[ -z "${PROJECT_ID}" ]]; then
  cat >&2 <<EOF
使い方: $0 PROJECT_ID [REGION] [PIPELINE_ROOT] [TEMPLATE_FILE_GCS_PATH] [TEMP_LOCATION] [INPUT_TABLE] [OUTPUT_TABLE] [SERVICE_ACCOUNT]
省略時のデフォルト:
  REGION: us-central1
  PIPELINE_ROOT: gs://dataflow-${PROJECT_ID}/pipeline_root
  TEMPLATE_FILE_GCS_PATH: gs://dataflow-${PROJECT_ID}/boston_star_p1_flex.json
  TEMP_LOCATION: gs://dataflow-${PROJECT_ID}/temp
  INPUT_TABLE: ${PROJECT_ID}.raw.boston_raw
  OUTPUT_TABLE: ${PROJECT_ID}.star.boston_fact_p1
  SERVICE_ACCOUNT: etl-dataflow-runner@${PROJECT_ID}.iam.gserviceaccount.com
EOF
  exit 1
fi

PIPELINE_ROOT="${PIPELINE_ROOT:-gs://dataflow-${PROJECT_ID}/pipeline_root}"
TEMPLATE_FILE_GCS_PATH="${TEMPLATE_FILE_GCS_PATH:-gs://dataflow-${PROJECT_ID}/boston_star_p1_flex.json}"
TEMP_LOCATION="${TEMP_LOCATION:-gs://dataflow-${PROJECT_ID}/temp}"
INPUT_TABLE="${INPUT_TABLE:-${PROJECT_ID}.raw.boston_raw}"
OUTPUT_TABLE="${OUTPUT_TABLE:-${PROJECT_ID}.star.boston_fact_p1}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-etl-dataflow-runner@${PROJECT_ID}.iam.gserviceaccount.com}"

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
