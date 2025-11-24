#!/usr/bin/env bash
set -euo pipefail

# Boston P1 パイプラインの初期セットアップ一括実行
# - Artifact Registry リポジトリ作成
# - GCS バケットと prefix (pipeline_root/temp) 準備
# - BigQuery データセットとサンプルテーブル作成
# - Dataflow 実行用サービスアカウント作成と権限付与

readonly DEFAULT_REGION="us-central1"
readonly DEFAULT_DATAFLOW_REGION="${DEFAULT_REGION}"
readonly DEFAULT_ARTIFACT_REGION="${DEFAULT_REGION}"
readonly DEFAULT_BUCKET_LOCATION="US"
readonly DEFAULT_DATASET_LOCATION="US"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DATA_DIR="${ROOT_DIR}/data"

usage() {
  cat <<EOF
使い方:
  $0 PROJECT_ID [DATAFLOW_REGION] [ARTIFACT_REGION] [ARTIFACT_REPO] [BUCKET_NAME] [BUCKET_LOCATION] [DATASET_LOCATION]
  $0 --project PROJECT_ID [--dataflow-region REGION] [--artifact-region REGION] [--artifact-repo NAME] [--bucket NAME] [--bucket-location LOC] [--dataset-location LOC]

可読性のためロングオプション推奨: --project, --dataflow-region, --artifact-region, --artifact-repo, --bucket/--bucket-name, --bucket-location, --dataset-location.

このスクリプトが行うこと:
  - Artifact Registry の Docker リポジトリ作成
  - GCS バケットと pipeline_root/temp プレースホルダ作成
  - BigQuery データセット raw/star と raw.boston_raw テーブル作成
  - Dataflow 実行用サービスアカウント作成と必要ロール付与

デフォルト値:
  DATAFLOW_REGION=${DEFAULT_DATAFLOW_REGION}
  ARTIFACT_REGION=${DEFAULT_ARTIFACT_REGION}
  ARTIFACT_REPO=dataflow-\${PROJECT_ID}
  BUCKET_NAME=dataflow-\${PROJECT_ID}
  BUCKET_LOCATION=${DEFAULT_BUCKET_LOCATION}
  DATASET_LOCATION=${DEFAULT_DATASET_LOCATION}
EOF
  exit 1
}

PROJECT_ID=""
DATAFLOW_REGION="${DEFAULT_DATAFLOW_REGION}"
ARTIFACT_REGION="${DEFAULT_ARTIFACT_REGION}"
ARTIFACT_REPO=""
BUCKET_NAME=""
BUCKET_LOCATION="${DEFAULT_BUCKET_LOCATION}"
DATASET_LOCATION="${DEFAULT_DATASET_LOCATION}"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)
      [[ $# -ge 2 ]] || { echo "ERROR: --project requires a value" >&2; usage; }
      PROJECT_ID="$2"
      shift 2
      ;;
    --project=*)
      PROJECT_ID="${1#*=}"
      shift
      ;;
    -r|--dataflow-region|--region)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; usage; }
      DATAFLOW_REGION="$2"
      shift 2
      ;;
    --dataflow-region=*)
      DATAFLOW_REGION="${1#*=}"
      shift
      ;;
    --artifact-region)
      [[ $# -ge 2 ]] || { echo "ERROR: --artifact-region requires a value" >&2; usage; }
      ARTIFACT_REGION="$2"
      shift 2
      ;;
    --artifact-region=*)
      ARTIFACT_REGION="${1#*=}"
      shift
      ;;
    --artifact-repo)
      [[ $# -ge 2 ]] || { echo "ERROR: --artifact-repo requires a value" >&2; usage; }
      ARTIFACT_REPO="$2"
      shift 2
      ;;
    --artifact-repo=*)
      ARTIFACT_REPO="${1#*=}"
      shift
      ;;
    --bucket|--bucket-name)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; usage; }
      BUCKET_NAME="$2"
      shift 2
      ;;
    --bucket=*|--bucket-name=*)
      BUCKET_NAME="${1#*=}"
      shift
      ;;
    --bucket-location)
      [[ $# -ge 2 ]] || { echo "ERROR: --bucket-location requires a value" >&2; usage; }
      BUCKET_LOCATION="$2"
      shift 2
      ;;
    --bucket-location=*)
      BUCKET_LOCATION="${1#*=}"
      shift
      ;;
    --dataset-location)
      [[ $# -ge 2 ]] || { echo "ERROR: --dataset-location requires a value" >&2; usage; }
      DATASET_LOCATION="$2"
      shift 2
      ;;
    --dataset-location=*)
      DATASET_LOCATION="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "ERROR: unknown option $1" >&2
      usage
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

# Anything after -- is treated as positional
if [[ $# -gt 0 ]]; then
  POSITIONAL+=("$@")
fi

# Backward-compatible positional parsing
if [[ -z "${PROJECT_ID}" ]] && [[ ${#POSITIONAL[@]} -ge 1 ]]; then PROJECT_ID="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then DATAFLOW_REGION="${POSITIONAL[1]}"; fi
if [[ ${#POSITIONAL[@]} -ge 3 ]]; then ARTIFACT_REGION="${POSITIONAL[2]}"; fi
if [[ ${#POSITIONAL[@]} -ge 4 ]]; then ARTIFACT_REPO="${POSITIONAL[3]}"; fi
if [[ ${#POSITIONAL[@]} -ge 5 ]]; then BUCKET_NAME="${POSITIONAL[4]}"; fi
if [[ ${#POSITIONAL[@]} -ge 6 ]]; then BUCKET_LOCATION="${POSITIONAL[5]}"; fi
if [[ ${#POSITIONAL[@]} -ge 7 ]]; then DATASET_LOCATION="${POSITIONAL[6]}"; fi

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required" >&2
  usage
fi

ARTIFACT_REPO="${ARTIFACT_REPO:-dataflow-${PROJECT_ID}}"
BUCKET_NAME="${BUCKET_NAME:-dataflow-${PROJECT_ID}}"

readonly SA_NAME="etl-dataflow-runner"
readonly SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

REQUIRED_COMMANDS=(gcloud bq gsutil python3)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: ${cmd} is required but missing" >&2
    exit 1
  fi
done

echo "[info] setting gcloud defaults project=${PROJECT_ID} region=${DATAFLOW_REGION}"
gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set ai/region "${DATAFLOW_REGION}" >/dev/null
gcloud config set compute/region "${DATAFLOW_REGION}" >/dev/null

ensure_artifact_repo() {
  if gcloud artifacts repositories describe "${ARTIFACT_REPO}" --project="${PROJECT_ID}" --location="${ARTIFACT_REGION}" &>/dev/null; then
    echo "[info] Artifact Registry repo already exists: ${ARTIFACT_REGION}/${ARTIFACT_REPO}"
    return
  fi

  echo "[run] creating Artifact Registry repo ${ARTIFACT_REPO} (${ARTIFACT_REGION})"
  gcloud artifacts repositories create "${ARTIFACT_REPO}" \
    --project="${PROJECT_ID}" \
    --location="${ARTIFACT_REGION}" \
    --repository-format=docker \
    --description="Boston Star P1 flex template artifacts"
}

ensure_bucket() {
  if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
    echo "[info] bucket already exists: gs://${BUCKET_NAME}"
  else
    echo "[run] creating bucket gs://${BUCKET_NAME} (${BUCKET_LOCATION})"
    gsutil mb -l "${BUCKET_LOCATION}" "gs://${BUCKET_NAME}"
  fi
}

ensure_bucket_prefixes() {
  for prefix in pipeline_root temp; do
    echo "[run] ensuring gs://${BUCKET_NAME}/${prefix}/"
    gsutil cp /dev/null "gs://${BUCKET_NAME}/${prefix}/.keep"
  done
}

ensure_datasets() {
  for dataset in raw star; do
    if bq --location="${DATASET_LOCATION}" show "${PROJECT_ID}:${dataset}" &>/dev/null; then
      echo "[info] dataset exists: ${PROJECT_ID}:${dataset}"
    else
      echo "[run] creating dataset ${PROJECT_ID}:${dataset} (${DATASET_LOCATION})"
      bq --location="${DATASET_LOCATION}" mk --dataset "${PROJECT_ID}:${dataset}"
    fi
  done
}

download_boston_csv() {
  local target="${DATA_DIR}/boston_housing.csv"
  echo "[run] downloading Boston housing data -> ${target}"
  BOSTON_CSV_PATH="${target}" python3 <<'PY'
import pathlib
import urllib.request
import os

target = pathlib.Path(os.environ["BOSTON_CSV_PATH"])
target.parent.mkdir(parents=True, exist_ok=True)

url = "https://archive.ics.uci.edu/ml/machine-learning-databases/housing/housing.data"
lines = [line for line in urllib.request.urlopen(url).read().decode().splitlines() if line.strip()]
header = "CRIM,ZN,INDUS,CHAS,NOX,RM,AGE,DIS,RAD,TAX,PTRATIO,B,LSTAT,MEDV"
rows = [",".join(line.split()) for line in lines]
target.write_text("\n".join([header] + rows) + "\n", encoding="utf-8")
PY
  echo "[info] CSV ready at ${target}"
}

load_boston_table() {
  local csv_path="${DATA_DIR}/boston_housing.csv"
  local table_spec="${PROJECT_ID}:raw.boston_raw"
  echo "[run] loading ${csv_path} into ${table_spec}"
  bq --location="${DATASET_LOCATION}" load \
    --replace \
    --skip_leading_rows=1 \
    "${table_spec}" \
    "${csv_path}" \
    CRIM:FLOAT,ZN:FLOAT,INDUS:FLOAT,CHAS:FLOAT,NOX:FLOAT,RM:FLOAT,AGE:FLOAT,DIS:FLOAT,RAD:FLOAT,TAX:FLOAT,PTRATIO:FLOAT,B:FLOAT,LSTAT:FLOAT,MEDV:FLOAT
}

ensure_runner_service_account() {
  echo "[info] ensuring runner service account ${SA_EMAIL}"
  if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
    echo "[info] service account already exists"
  else
    echo "[run] creating service account ${SA_EMAIL}"
    gcloud iam service-accounts create "${SA_NAME}" \
      --display-name="Boston P1 Dataflow Runner" \
      --project="${PROJECT_ID}"
  fi

  echo "[run] granting roles to ${SA_EMAIL}"
  for role in \
    roles/dataflow.worker \
    roles/dataflow.developer \
    roles/storage.objectAdmin \
    roles/bigquery.dataEditor \
    roles/artifactregistry.reader; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="${role}" \
      --quiet >/dev/null
  done

  echo "[run] granting iam.serviceAccountUser on ${SA_EMAIL} to project agents"
  PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
  for member in \
    "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"; do
    gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
      --member="${member}" \
      --role="roles/iam.serviceAccountUser" \
      --quiet >/dev/null || true
  done
}

ensure_artifact_repo
ensure_bucket
ensure_bucket_prefixes
ensure_datasets
download_boston_csv
load_boston_table
ensure_runner_service_account

cat <<EOF
[done] Bootstrap complete
- Artifact Registry: ${ARTIFACT_REGION}/${ARTIFACT_REPO}
- Bucket: gs://${BUCKET_NAME} (pipeline_root, temp)
- BigQuery datasets: ${PROJECT_ID}:raw (boston_raw), ${PROJECT_ID}:star
- Runner service account: ${SA_EMAIL}
EOF
