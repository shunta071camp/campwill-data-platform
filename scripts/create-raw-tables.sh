#!/usr/bin/env bash
# create-raw-tables.sh
# bigquery/campwill-ec/raw/*.json をループで読み込み、bq mk --table で 11 テーブル作成。
# 既存テーブルがあればスキップ（idempotent）。

set -euo pipefail

# Force UTF-8 mode for bundled Python (avoids cp932 decode error on Windows when
# reading JSON schema files containing Japanese descriptions).
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
PROJECT_ID="${PROJECT_PREFIX}-ec"
DATASET="raw"
SCHEMA_DIR="$(cd "$(dirname "$0")/.." && pwd)/bigquery/campwill-ec/raw"

if [[ ! -d "$SCHEMA_DIR" ]]; then
  echo "ERROR: Schema directory not found: $SCHEMA_DIR"
  exit 1
fi

echo "===> Creating raw tables in ${PROJECT_ID}:${DATASET}"
echo "===> Schema source: $SCHEMA_DIR"
echo

for SCHEMA_FILE in "$SCHEMA_DIR"/*.json; do
  TABLE_NAME="$(basename "$SCHEMA_FILE" .json)"
  FQN="${PROJECT_ID}:${DATASET}.${TABLE_NAME}"

  if bq --project_id="$PROJECT_ID" show "${PROJECT_ID}:${DATASET}.${TABLE_NAME}" &>/dev/null; then
    echo "  [skip] Table $FQN already exists"
  else
    echo "  [create] Table $FQN"
    bq --project_id="$PROJECT_ID" \
      mk --table "$FQN" "$SCHEMA_FILE"
  fi
done

echo
echo "===> Tables in ${PROJECT_ID}:${DATASET}:"
bq --project_id="$PROJECT_ID" ls "${PROJECT_ID}:${DATASET}"

echo
echo "===> create-raw-tables.sh completed."
echo "===> Next: bash scripts/create-mart-tables.sh"
