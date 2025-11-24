#!/usr/bin/env bash
set -euo pipefail

DEFAULT_LOCATION="us-central1"
DEFAULT_ARTIFACT_REGION="${DEFAULT_LOCATION}"
DEFAULT_DATASET_LOCATION="US"
DEFAULT_BUCKET_LOCATION="US"
DEFAULT_ARTIFACT_IMAGE="boston-star-p1-flex"
DEFAULT_DATAFLOW_NAME_PREFIX="boston-star-p1-flex"
DEFAULT_PIPELINE_PREFIX="etl-boston-star-p1"
DEFAULT_RUNNER_SA="etl-dataflow-runner"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"

usage() {
  cat <<'EOF'
使い方: cleanup.sh --project <PROJECT_ID> [options]

オプション:
  --project               (必須) 対象の GCP プロジェクト ID
  --location              Vertex AI / Dataflow のリージョン (既定: us-central1)
  --pipeline-job          削除する Vertex AI PipelineJob 名（リソース名または短縮名）
  --dataflow-name-prefix  Dataflow ジョブ名のフィルタプレフィックス (既定: boston-star-p1-flex)
  --artifact-region       Artifact Registry のリージョン (既定: us-central1)
  --artifact-repo         Artifact Registry のリポジトリ名 (既定: dataflow-<PROJECT>)
  --artifact-image        削除対象の Artifact イメージ名 (既定: boston-star-p1-flex)
  --bucket-name           削除対象の GCS バケット (既定: dataflow-<PROJECT>)
  --staging-prefix        Dataflow ステージング用バケットを明示 (既定: dataflow-staging-<location>-<project_number>)
  --keep-bucket           バケット本体を残し、中身のみ削除
  --keep-artifact-repo    Artifact Registry リポジトリを残し、イメージのみ削除
  --dry-run               コマンドを実行せず出力のみ
  --help                  このヘルプを表示

削除対象: Vertex AI PipelineJob、Dataflow ジョブ、BigQuery raw/star データセット、GCS パス
(template/pipeline_root/temp/staging)、Artifact Registry イメージ/リポジトリ、対象バケット、
ローカル CSV、ローカル .venv / __pycache__。
EOF
}

PROJECT=""
LOCATION="${DEFAULT_LOCATION}"
PIPELINE_JOB=""
DATAFLOW_PREFIX="${DEFAULT_DATAFLOW_NAME_PREFIX}"
PIPELINE_PREFIX="${DEFAULT_PIPELINE_PREFIX}"
RUNNER_SA_NAME="${DEFAULT_RUNNER_SA}"
RUNNER_SA=""
ARTIFACT_REGION="${DEFAULT_ARTIFACT_REGION}"
ARTIFACT_REPO=""
ARTIFACT_IMAGE="${DEFAULT_ARTIFACT_IMAGE}"
BUCKET_NAME=""
STAGING_PREFIX=""
KEEP_BUCKET=false
KEEP_ARTIFACT_REPO=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --pipeline-job) PIPELINE_JOB="$2"; shift 2 ;;
    --pipeline-prefix) PIPELINE_PREFIX="$2"; shift 2 ;;
    --dataflow-name-prefix) DATAFLOW_PREFIX="$2"; shift 2 ;;
    --artifact-region) ARTIFACT_REGION="$2"; shift 2 ;;
    --artifact-repo) ARTIFACT_REPO="$2"; shift 2 ;;
    --artifact-image) ARTIFACT_IMAGE="$2"; shift 2 ;;
    --runner-sa) RUNNER_SA_NAME="$2"; shift 2 ;;
    --bucket-name|--gcs-bucket) BUCKET_NAME="$2"; shift 2 ;;
    --staging-prefix) STAGING_PREFIX="$2"; shift 2 ;;
    --keep-bucket) KEEP_BUCKET=true; shift ;;
    --keep-artifact-repo) KEEP_ARTIFACT_REPO=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${PROJECT}" ]]; then
  echo "ERROR: --project is required" >&2
  usage
  exit 1
fi

REQUIRED_CMD=(gcloud bq gsutil curl)
for cmd in "${REQUIRED_CMD[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} is required" >&2
    exit 1
  fi
done

if [[ -z "${ARTIFACT_REPO}" ]]; then
  ARTIFACT_REPO="dataflow-${PROJECT}"
fi
if [[ -z "${BUCKET_NAME}" ]]; then
  BUCKET_NAME="dataflow-${PROJECT}"
fi
if [[ -z "${RUNNER_SA}" ]]; then
  RUNNER_SA="${RUNNER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
fi

run_cmd() {
  if ${DRY_RUN}; then
    echo "[dry-run] $*"
  else
    echo "[run] $*"
    "$@"
  fi
}

get_project_number() {
  if ${DRY_RUN}; then
    echo "000000000000"
    return
  fi
  gcloud projects describe "${PROJECT}" --format="value(projectNumber)"
}

cancel_pipeline_job() {
  [[ -z "${PIPELINE_JOB}" ]] && return
  delete_pipeline_job "${PIPELINE_JOB}"
}

delete_pipeline_job() {
  local name="$1"
  if [[ "${name}" != projects/* ]]; then
    name="projects/${PROJECT}/locations/${LOCATION}/pipelineJobs/${name}"
  fi

  local token
  if ${DRY_RUN}; then
    token="(dry-run-token)"
  else
    token=$(gcloud auth print-access-token)
  fi

  run_cmd curl -s -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "https://${LOCATION}-aiplatform.googleapis.com/v1/${name}:cancel" || true

  run_cmd curl -s -X DELETE \
    -H "Authorization: Bearer ${token}" \
    "https://${LOCATION}-aiplatform.googleapis.com/v1/${name}" || true
}

cancel_dataflow_jobs() {
  local ids
  if ${DRY_RUN}; then
    ids="(dry-run-skip)"
  else
    ids=$(gcloud dataflow jobs list \
      --project="${PROJECT}" \
      --region="${LOCATION}" \
      --filter="name:${DATAFLOW_PREFIX}" \
      --format="value(id)" || true)
  fi
  if [[ -z "${ids}" ]]; then
    echo "[info] no Dataflow jobs matching prefix ${DATAFLOW_PREFIX}"
    return
  fi
  for id in ${ids}; do
    run_cmd gcloud dataflow jobs cancel "${id}" --project="${PROJECT}" --region="${LOCATION}" || true
  done
}

delete_pipeline_jobs_by_prefix() {
  [[ -n "${PIPELINE_JOB}" ]] && return

  local token
  if ${DRY_RUN}; then
    token="(dry-run-token)"
  else
    token=$(gcloud auth print-access-token)
  fi

  local page_token=""
  local found=false

  while true; do
    local url="https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/${LOCATION}/pipelineJobs?pageSize=1000"
    if [[ -n "${page_token}" ]]; then
      url+="&pageToken=${page_token}"
    fi

    local list_json
    list_json=$(curl -s -H "Authorization: Bearer ${token}" "${url}")

    if [[ -z "${list_json}" ]]; then
      echo "[info] pipeline job list response empty"
      break
    fi

    local parsed
    parsed=$(PIPELINE_PREFIX="${PIPELINE_PREFIX}" python3 - <<'PY'
import json, os, sys
prefix = os.environ.get("PIPELINE_PREFIX", "")
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
data = json.loads(raw)
next_token = data.get("nextPageToken", "")
for job in data.get("pipelineJobs", []):
    name = job.get("name", "")
    disp = job.get("displayName", "")
    tail = name.split("/")[-1]
    if prefix and (disp.startswith(prefix) or tail.startswith(prefix)):
        print(name)
if next_token:
    print(f"__NEXT__{next_token}")
PY
)

    local names=""
    page_token=""
    while IFS= read -r line; do
      if [[ "${line}" == __NEXT__* ]]; then
        page_token="${line#__NEXT__}"
      elif [[ -n "${line}" ]]; then
        names+=" ${line}"
      fi
    done <<< "${parsed}"

    if [[ -n "${names}" ]]; then
      found=true
      for n in ${names}; do
        delete_pipeline_job "${n}"
      done
    fi

    [[ -z "${page_token}" ]] && break
  done

  if ! ${found}; then
    echo "[info] no pipeline jobs matching prefix ${PIPELINE_PREFIX}"
  fi
}

delete_bigquery() {
  run_cmd bq --location="${DEFAULT_DATASET_LOCATION}" rm -r -f "${PROJECT}:raw" || true
  run_cmd bq --location="${DEFAULT_DATASET_LOCATION}" rm -r -f "${PROJECT}:star" || true
}

delete_service_account() {
  # Only delete the runner SA if it is the default name and belongs to this project.
  local target_sa="${RUNNER_SA}"
  local default_sa="${RUNNER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
  if [[ "${target_sa}" != "${default_sa}" ]]; then
    echo "[info] skipping service account deletion (non-default or override): ${target_sa}"
    return
  fi
  if gcloud iam service-accounts describe "${target_sa}" >/dev/null 2>&1; then
    run_cmd gcloud iam service-accounts delete "${target_sa}" --quiet
  else
    echo "[info] service account not found: ${target_sa}"
  fi
}

delete_gcs_paths() {
  local staging_bucket
  staging_bucket="${STAGING_PREFIX}"
  if [[ -z "${staging_bucket}" ]]; then
    staging_bucket="dataflow-staging-${LOCATION}-$(get_project_number)"
  fi

  for path in \
    "gs://${BUCKET_NAME}/boston_star_p1_flex.json" \
    "gs://${BUCKET_NAME}/pipeline_root" \
    "gs://${BUCKET_NAME}/temp" \
    "gs://${staging_bucket}"; do
    if ${DRY_RUN}; then
      echo "[dry-run] gsutil -m rm -r ${path}"
      continue
    fi
    gsutil ls "${path}" >/dev/null 2>&1 || { echo "[info] skip missing ${path}"; continue; }
    run_cmd gsutil -m rm -r "${path}"
  done
}

delete_bucket() {
  ${KEEP_BUCKET} && { echo "[info] keep-bucket enabled; skipping bucket delete"; return; }
  local path="gs://${BUCKET_NAME}"
  gsutil ls -b "${path}" >/dev/null 2>&1 || { echo "[info] skip missing ${path}"; return; }
  run_cmd gsutil -m rm -r "${path}"
}

delete_artifact_image() {
  local image_uri="${ARTIFACT_REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/${ARTIFACT_IMAGE}"
  if ${KEEP_ARTIFACT_REPO}; then
    run_cmd gcloud artifacts docker images delete "${image_uri}" --project="${PROJECT}" --delete-tags --quiet || true
  else
    echo "[info] artifact repo will be deleted; skipping image delete"
  fi
}

delete_artifact_repo() {
  ${KEEP_ARTIFACT_REPO} && { echo "[info] keep-artifact-repo enabled; skipping repo delete"; return; }
  gcloud artifacts repositories describe "${ARTIFACT_REPO}" --project="${PROJECT}" --location="${ARTIFACT_REGION}" >/dev/null 2>&1 || {
    echo "[info] artifact repo ${ARTIFACT_REPO} not found in ${ARTIFACT_REGION}"; return; }
  run_cmd gcloud artifacts repositories delete "${ARTIFACT_REPO}" \
    --project="${PROJECT}" \
    --location="${ARTIFACT_REGION}" \
    --quiet || true
}

cleanup_local() {
  for path in ".venv" "__pycache__"; do
    if [[ -e "${ROOT_DIR}/${path}" ]]; then
      run_cmd rm -rf "${ROOT_DIR}/${path}"
    fi
  done
}

delete_local_csv() {
  local csv_path="${DATA_DIR}/boston_housing.csv"
  if [[ -f "${csv_path}" ]]; then
    run_cmd rm -f "${csv_path}"
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    rmdir "${DATA_DIR}" 2>/dev/null || true
  fi
}

echo "[info] project=${PROJECT} location=${LOCATION} artifact_region=${ARTIFACT_REGION} bucket=${BUCKET_NAME}"

cancel_pipeline_job
cancel_dataflow_jobs
delete_pipeline_jobs_by_prefix
delete_bigquery
delete_gcs_paths
delete_bucket
delete_artifact_image
delete_artifact_repo
cleanup_local
delete_local_csv
delete_service_account

echo "[info] cleanup completed"
