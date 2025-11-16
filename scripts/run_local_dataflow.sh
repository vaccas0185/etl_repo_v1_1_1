#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
INPUT_TABLE="${2:-}"
OUTPUT_TABLE="${3:-}"

if [[ -z "${PROJECT_ID}" || -z "${INPUT_TABLE}" || -z "${OUTPUT_TABLE}" ]]; then
  echo "Usage: $0 PROJECT_ID INPUT_TABLE OUTPUT_TABLE" >&2
  exit 1
fi

docker run --rm -it   -v "$PWD":/app   -w /app   -v "$HOME/.config/gcloud:/root/.config/gcloud:ro"   etl-dev   bash -lc "
    uv sync &&     uv run python dataflow/star_schema/boston_star_pipeline.py       --runner=DirectRunner       --project=${PROJECT_ID}       --input_table=${INPUT_TABLE}       --output_table=${OUTPUT_TABLE}
  "
