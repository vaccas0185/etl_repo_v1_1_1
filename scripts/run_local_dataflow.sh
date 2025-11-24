#!/usr/bin/env bash
set -euo pipefail

# ローカル DirectRunner 検証用スクリプト
# - dev 用イメージ (etl-dev) が無ければ自動ビルド
# - gcloud の ADC 認証をホストからマウントして BigQuery にアクセス

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_IMAGE="etl-dev"

PROJECT_ID=""
INPUT_TABLE=""
OUTPUT_TABLE=""
TEMP_LOCATION=""

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2 ;;
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --input) INPUT_TABLE="$2"; shift 2 ;;
    --input=*) INPUT_TABLE="${1#*=}"; shift ;;
    --output) OUTPUT_TABLE="$2"; shift 2 ;;
    --output=*) OUTPUT_TABLE="${1#*=}"; shift ;;
    --temp-location) TEMP_LOCATION="$2"; shift 2 ;;
    --temp-location=*) TEMP_LOCATION="${1#*=}"; shift ;;
    -h|--help)
      cat >&2 <<'EOF'
Usage: run_local_dataflow.sh --project PROJECT_ID [--input INPUT_TABLE] [--output OUTPUT_TABLE] [--temp-location GCS_PATH]
Defaults: INPUT_TABLE=<PROJECT_ID>.raw.boston_raw OUTPUT_TABLE=<PROJECT_ID>.star.boston_fact_p1 TEMP_LOCATION=gs://dataflow-<PROJECT_ID>/temp
EOF
      exit 1 ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ -z "${PROJECT_ID}" ]] && [[ ${#POSITIONAL[@]} -ge 1 ]]; then
  PROJECT_ID="${POSITIONAL[0]}"
fi
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: --project <PROJECT_ID> が必要です" >&2
  exit 1
fi

normalize_table() {
  local t="$1"
  # 先頭のコロンをドットに変換（Beam が期待する project.dataset.table 形式に合わせる）
  echo "${t/:/.}"
}

INPUT_TABLE="$(normalize_table "${INPUT_TABLE:-${PROJECT_ID}.raw.boston_raw}")"
OUTPUT_TABLE="$(normalize_table "${OUTPUT_TABLE:-${PROJECT_ID}.star.boston_fact_p1}")"
TEMP_LOCATION="${TEMP_LOCATION:-gs://dataflow-${PROJECT_ID}/temp}"

ensure_dev_image() {
  local needs_build=false
  if ! docker image inspect "${DEV_IMAGE}" >/dev/null 2>&1; then
    needs_build=true
  else
    # 旧イメージに Java が無い場合は再ビルド
    if ! docker run --rm "${DEV_IMAGE}" java -version >/dev/null 2>&1; then
      echo "[info] existing ${DEV_IMAGE} lacks Java; rebuilding"
      needs_build=true
    fi
  fi

  if ${needs_build}; then
    echo "[run] building ${DEV_IMAGE} image from docker/Dockerfile.dev"
    docker build -f "${ROOT_DIR}/docker/Dockerfile.dev" -t "${DEV_IMAGE}" "${ROOT_DIR}"
  fi
}

ensure_dev_image

docker run --rm -it \
  -v "${ROOT_DIR}":/app \
  -w /app \
  -v "$HOME/.config/gcloud:/root/.config/gcloud:ro" \
  -e GOOGLE_CLOUD_PROJECT="${PROJECT_ID}" \
  -e GCP_PROJECT="${PROJECT_ID}" \
  "${DEV_IMAGE}" \
  bash -lc "
    uv sync &&
    uv run python dataflow/star_schema/boston_star_pipeline.py \
      --runner=DirectRunner \
      --project=${PROJECT_ID} \
      --input_table=${INPUT_TABLE} \
      --output_table=${OUTPUT_TABLE} \
      --temp_location=${TEMP_LOCATION}
  "
