#!/usr/bin/env bash
# create-mart-tables.sh
# mart テーブルを作成する：
#   1. cost_master / shipping_rules : スキーマ JSON で空テーブル作成
#   2. ec_daily_pnl / ec_channel_roi / ec_klaviyo_conversion / ec_weekly_summary :
#      CREATE OR REPLACE TABLE AS SELECT で raw から再生成
#
# 注意: 2 のクエリは raw テーブルにデータが無いと SELECT が空になるが、
# テーブル自体は CREATE OR REPLACE で正しく作成される。

set -euo pipefail

# Force UTF-8 mode for bundled Python (avoids cp932 decode error on Windows when
# reading JSON schema files / SQL files containing Japanese).
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
PROJECT_ID="${PROJECT_PREFIX}-ec"
DATASET="mart"
MART_DIR="$(cd "$(dirname "$0")/.." && pwd)/bigquery/campwill-ec/mart"

if [[ ! -d "$MART_DIR" ]]; then
  echo "ERROR: Mart directory not found: $MART_DIR"
  exit 1
fi

echo "===> Creating mart tables in ${PROJECT_ID}:${DATASET}"
echo

# --- Step 1: スキーマ JSON で作成するテーブル ---
SCHEMA_TABLES=("ec_cost_master" "ec_shipping_rules")
for TABLE_NAME in "${SCHEMA_TABLES[@]}"; do
  SCHEMA_FILE="${MART_DIR}/${TABLE_NAME}.json"
  FQN="${PROJECT_ID}:${DATASET}.${TABLE_NAME}"

  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "ERROR: Schema not found: $SCHEMA_FILE"
    exit 1
  fi

  if bq --project_id="$PROJECT_ID" show "$FQN" &>/dev/null; then
    echo "  [skip] $FQN already exists"
  else
    echo "  [create] $FQN (from schema)"
    bq --project_id="$PROJECT_ID" mk --table "$FQN" "$SCHEMA_FILE"
  fi
done

echo

# --- Step 2: SQL で CREATE OR REPLACE するテーブル ---
SQL_TABLES=("ec_daily_pnl" "ec_channel_roi" "ec_klaviyo_conversion" "ec_weekly_summary")
for TABLE_NAME in "${SQL_TABLES[@]}"; do
  SQL_FILE="${MART_DIR}/${TABLE_NAME}.sql"
  FQN="${PROJECT_ID}.${DATASET}.${TABLE_NAME}"

  if [[ ! -f "$SQL_FILE" ]]; then
    echo "ERROR: SQL not found: $SQL_FILE"
    exit 1
  fi

  echo "  [run] $FQN <- $SQL_FILE"
  bq --project_id="$PROJECT_ID" \
    query --use_legacy_sql=false --quiet \
    < "$SQL_FILE"
done

echo
echo "===> Tables in ${PROJECT_ID}:${DATASET}:"
bq --project_id="$PROJECT_ID" ls "${PROJECT_ID}:${DATASET}"

echo
echo "===> create-mart-tables.sh completed."
echo "===> Next: load shipping_rules seed:"
echo "      bq query --use_legacy_sql=false --project_id=${PROJECT_ID} < seeds/ec_shipping_rules_seed.sql"
