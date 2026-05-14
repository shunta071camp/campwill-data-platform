#!/usr/bin/env bash
# create-realestate-mart.sh
# campwill-realestate の mart 5 テーブル (CREATE OR REPLACE TABLE AS SELECT) を実行。
# raw に最初のデータが入った後に手動 or n8n から呼ぶ。
# Scheduled Query 登録後はこのスクリプトは初回検証用のみ。

set -euo pipefail

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
PROJECT_ID="${PROJECT_PREFIX}-realestate"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MART_DIR="$ROOT/bigquery/campwill-realestate/mart"

# 実行順序: 依存関係を考慮 (lead_funnel → weekly_summary)
ORDER=(
  "re_lead_funnel.sql"
  "re_case_pipeline.sql"
  "re_seo_inquiry_attribution.sql"
  "re_property_performance.sql"
  "re_weekly_summary.sql"
)

if [[ ! -d "$MART_DIR" ]]; then
  echo "ERROR: Mart directory not found: $MART_DIR"
  exit 1
fi

echo "===> Running mart SQL on ${PROJECT_ID}"
for SQL_FILE in "${ORDER[@]}"; do
  FULL="$MART_DIR/$SQL_FILE"
  if [[ ! -f "$FULL" ]]; then
    echo "  [skip] $SQL_FILE not found"
    continue
  fi
  echo "  [run]  $SQL_FILE"
  bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --max_rows=0 < "$FULL" || {
    echo "  [ERROR] $SQL_FILE failed"
    exit 1
  }
done

echo
echo "===> Tables in ${PROJECT_ID}:mart:"
bq --project_id="$PROJECT_ID" ls "${PROJECT_ID}:mart"

echo
echo "===> create-realestate-mart.sh completed."
