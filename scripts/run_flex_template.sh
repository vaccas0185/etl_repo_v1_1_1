#!/usr/bin/env bash
set -euo pipefail

# Dataflow Flex Template を gcloud で起動するラッパー

DEFAULT_REGION="us-central1"

usage() {
  cat <<'EOF'
使い方:
  run_flex_template.sh PROJECT_ID [REGION] [TEMPLATE_GCS] [TEMP_LOCATION] [INPUT_TABLE] [OUTPUT_TABLE] [SERVICE_ACCOUNT] [JOB_NAME]
  run_flex_template.sh --project PROJECT_ID [--region REGION] [--template TEMPLATE_GCS] [--temp-location GCS_PATH] [--input TABLE] [--output TABLE] [--service-account SA_EMAIL] [--job-name NAME]

デフォルト:
  REGION: us-central1
  TEMPLATE_GCS: gs://dataflow-<PROJECT_ID>/boston_star_p1_flex.json
  TEMP_LOCATION: gs://dataflow-<PROJECT_ID>/temp
  INPUT_TABLE: <PROJECT_ID>.raw.boston_raw
  OUTPUT_TABLE: <PROJECT_ID>.star.boston_fact_p1
  SERVICE_ACCOUNT: etl-dataflow-runner@<PROJECT_ID>.iam.gserviceaccount.com
  JOB_NAME: boston-star-p1-flex-<timestamp>
EOF
  exit 1
}

PROJECT=""
REGION="${DEFAULT_REGION}"
TEMPLATE=""
TEMP_LOCATION=""
INPUT_TABLE=""
OUTPUT_TABLE=""
SERVICE_ACCOUNT=""
JOB_NAME=""

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|-p) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --region|-r) REGION="$2"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --template=*) TEMPLATE="${1#*=}"; shift ;;
    --temp-location) TEMP_LOCATION="$2"; shift 2 ;;
    --temp-location=*) TEMP_LOCATION="${1#*=}"; shift ;;
    --input) INPUT_TABLE="$2"; shift 2 ;;
    --input=*) INPUT_TABLE="${1#*=}"; shift ;;
    --output) OUTPUT_TABLE="$2"; shift 2 ;;
    --output=*) OUTPUT_TABLE="${1#*=}"; shift ;;
    --service-account) SERVICE_ACCOUNT="$2"; shift 2 ;;
    --service-account=*) SERVICE_ACCOUNT="${1#*=}"; shift ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --job-name=*) JOB_NAME="${1#*=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ -z "${PROJECT}" ]] && [[ ${#POSITIONAL[@]} -ge 1 ]]; then PROJECT="${POSITIONAL[0]}"; fi
[[ -z "${PROJECT}" ]] && usage

TEMPLATE="${TEMPLATE:-gs://dataflow-${PROJECT}/boston_star_p1_flex.json}"
TEMP_LOCATION="${TEMP_LOCATION:-gs://dataflow-${PROJECT}/temp}"
INPUT_TABLE="${INPUT_TABLE:-${PROJECT}.raw.boston_raw}"
OUTPUT_TABLE="${OUTPUT_TABLE:-${PROJECT}.star.boston_fact_p1}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-etl-dataflow-runner@${PROJECT}.iam.gserviceaccount.com}"
JOB_NAME="${JOB_NAME:-boston-star-p1-flex-$(date +%Y%m%d%H%M%S)}"

echo "[info] launching Dataflow job: ${JOB_NAME}"
gcloud dataflow flex-template run "${JOB_NAME}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --template-file-gcs-location="${TEMPLATE}" \
  --service-account-email="${SERVICE_ACCOUNT}" \
  --parameters=project="${PROJECT}",region="${REGION}",temp_location="${TEMP_LOCATION}",input_table="${INPUT_TABLE}",output_table="${OUTPUT_TABLE}"
