#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_REGION="us-central1"

PROJECT_ID=""
REGION="${DEFAULT_REGION}"
ARTIFACT_REPO=""
TEMPLATE_GCS_PATH=""

usage() {
  cat <<'EOF'
Usage:
  build_boston_star_flex_template.sh --project PROJECT_ID [--region REGION] [--artifact-repo REPO] [--template-gcs-path GCS_PATH]
  build_boston_star_flex_template.sh PROJECT_ID [REGION] [ARTIFACT_REPO] [TEMPLATE_GCS_PATH]

Defaults:
  REGION: us-central1
  ARTIFACT_REPO: dataflow-<PROJECT_ID>
  TEMPLATE_GCS_PATH: gs://dataflow-<PROJECT_ID>
EOF
  exit 1
}

# 引数パース（ロングオプション推奨、従来の位置引数も許容）
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|-p) PROJECT_ID="$2"; shift 2 ;;
    --project=*)  PROJECT_ID="${1#*=}"; shift ;;
    --region|-r)  REGION="$2"; shift 2 ;;
    --region=*)   REGION="${1#*=}"; shift ;;
    --artifact-repo) ARTIFACT_REPO="$2"; shift 2 ;;
    --artifact-repo=*) ARTIFACT_REPO="${1#*=}"; shift ;;
    --template-gcs-path) TEMPLATE_GCS_PATH="$2"; shift 2 ;;
    --template-gcs-path=*) TEMPLATE_GCS_PATH="${1#*=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# 位置引数の後続も取得
if [[ -z "${PROJECT_ID}" ]] && [[ ${#POSITIONAL[@]} -ge 1 ]]; then PROJECT_ID="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then REGION="${POSITIONAL[1]}"; fi
if [[ ${#POSITIONAL[@]} -ge 3 ]]; then ARTIFACT_REPO="${POSITIONAL[2]}"; fi
if [[ ${#POSITIONAL[@]} -ge 4 ]]; then TEMPLATE_GCS_PATH="${POSITIONAL[3]}"; fi

if [[ -z "${PROJECT_ID}" ]]; then
  usage
fi

ARTIFACT_REPO="${ARTIFACT_REPO:-dataflow-${PROJECT_ID}}"
TEMPLATE_GCS_PATH="${TEMPLATE_GCS_PATH:-gs://dataflow-${PROJECT_ID}}"

IMAGE_NAME="boston-star-p1-flex"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${IMAGE_NAME}:latest"
TEMPLATE_PATH="${TEMPLATE_GCS_PATH}/boston_star_p1_flex.json"

echo "[info] building image: ${IMAGE_URI}"
docker build -f "${ROOT_DIR}/docker/Dockerfile.dataflow" -t "${IMAGE_URI}" "${ROOT_DIR}"
docker push "${IMAGE_URI}"

echo "[info] building flex template: ${TEMPLATE_PATH}"
gcloud dataflow flex-template build "${TEMPLATE_PATH}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE_URI}" \
  --sdk-language="PYTHON" \
  --metadata-file="${ROOT_DIR}/config/pipelines/boston_star_flex_template_metadata.json"
