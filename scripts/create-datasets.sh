#!/usr/bin/env bash
# create-datasets.sh
# 仕様書 §3 のデータセット構成を bq mk で作成する。
#   - campwill-ec      : raw, mart, ga4_export
#   - campwill-realestate : raw, mart, ga4_export
#   - campwill-central : mart_all
#
# 全て asia-northeast1 リージョン（GA4 BigQuery エクスポートと一致が必須）

set -euo pipefail

PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
REGION="asia-northeast1"

create_dataset() {
  local PROJECT_ID="$1"
  local DATASET="$2"
  local FQN="${PROJECT_ID}:${DATASET}"

  if bq --project_id="$PROJECT_ID" ls --datasets 2>/dev/null \
    | awk '{print $1}' | grep -qx "$DATASET"; then
    echo "  [skip] Dataset $FQN already exists"
  else
    echo "  [create] Dataset $FQN (location: $REGION)"
    bq --location="$REGION" --project_id="$PROJECT_ID" \
      mk --dataset "$FQN"
  fi
}

echo "===== campwill-ec datasets ====="
PROJECT_EC="${PROJECT_PREFIX}-ec"
create_dataset "$PROJECT_EC" "raw"
create_dataset "$PROJECT_EC" "mart"
create_dataset "$PROJECT_EC" "ga4_export"

echo
echo "===== campwill-realestate datasets ====="
PROJECT_RE="${PROJECT_PREFIX}-realestate"
create_dataset "$PROJECT_RE" "raw"
create_dataset "$PROJECT_RE" "mart"
create_dataset "$PROJECT_RE" "ga4_export"

echo
echo "===== campwill-central datasets ====="
PROJECT_CENTRAL="${PROJECT_PREFIX}-central"
create_dataset "$PROJECT_CENTRAL" "mart_all"

echo
echo "===> create-datasets.sh completed."
echo "===> Next: bash scripts/create-raw-tables.sh"
