#!/usr/bin/env bash
# create-realestate-tables.sh
# campwill-realestate の raw 5 テーブル + SC view を作成。
#
# mart テーブルは raw に最初のデータが入ってから別途実行する
# (CREATE OR REPLACE TABLE AS SELECT は実行時に raw を参照するため)。

set -euo pipefail

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
PROJECT_ID="${PROJECT_PREFIX}-realestate"
DATASET_RAW="raw"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="$ROOT/bigquery/campwill-realestate/raw"

if [[ ! -d "$RAW_DIR" ]]; then
  echo "ERROR: Schema directory not found: $RAW_DIR"
  exit 1
fi

echo "===> Creating raw tables in ${PROJECT_ID}:${DATASET_RAW}"
for SCHEMA_FILE in "$RAW_DIR"/*.json; do
  TABLE_NAME="$(basename "$SCHEMA_FILE" .json)"
  FQN="${PROJECT_ID}:${DATASET_RAW}.${TABLE_NAME}"

  if bq --project_id="$PROJECT_ID" show "$FQN" &>/dev/null; then
    echo "  [skip] $FQN already exists"
  else
    echo "  [create] $FQN"
    bq --project_id="$PROJECT_ID" mk --table "$FQN" "$SCHEMA_FILE"
  fi
done

echo
echo "===> Creating SC view (re_search_console)"
SC_VIEW="$RAW_DIR/re_search_console.view.sql"
if [[ -f "$SC_VIEW" ]]; then
  bq --project_id="$PROJECT_ID" query --use_legacy_sql=false < "$SC_VIEW" || \
    echo "  [warn] SC view creation failed — Search Console Bulk Export がまだ未設定の可能性"
fi

echo
echo "===> Tables in ${PROJECT_ID}:${DATASET_RAW}:"
bq --project_id="$PROJECT_ID" ls "${PROJECT_ID}:${DATASET_RAW}"

echo
echo "===> create-realestate-tables.sh (raw) completed."
echo "===> Next: n8n workflow で raw にデータ投入後、bash scripts/create-realestate-mart.sh"
