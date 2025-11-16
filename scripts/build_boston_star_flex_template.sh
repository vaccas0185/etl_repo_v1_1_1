#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
REGION="${2:-}"
ARTIFACT_REPO="${3:-}"
TEMPLATE_GCS_PATH="${4:-}"

if [[ -z "${PROJECT_ID}" || -z "${REGION}" || -z "${ARTIFACT_REPO}" || -z "${TEMPLATE_GCS_PATH}" ]]; then
  echo "Usage: $0 PROJECT_ID REGION ARTIFACT_REPO TEMPLATE_GCS_PATH" >&2
  exit 1
fi

IMAGE_NAME="boston-star-p1-flex"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${IMAGE_NAME}:latest"
TEMPLATE_PATH="${TEMPLATE_GCS_PATH}/boston_star_p1_flex.json"

docker build -f docker/Dockerfile.dataflow -t "${IMAGE_URI}" .
docker push "${IMAGE_URI}"

gcloud dataflow flex-template build "${TEMPLATE_PATH}"   --project="${PROJECT_ID}"   --image="${IMAGE_URI}"   --sdk-language="PYTHON"   --metadata-file="config/pipelines/boston_star_flex_template_metadata.json"
