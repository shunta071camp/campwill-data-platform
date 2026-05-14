#!/usr/bin/env bash
# grant-bq-access.sh — campwill-ec BQ アクセスをメンバーに付与する
#
# 付与内容:
#   1. roles/bigquery.jobUser on project (クエリ実行 + 課金)
#   2. roles/bigquery.dataViewer on dataset campwill-ec:mart (mart 閲覧)
#   3. (オプション --with-raw) roles/bigquery.dataViewer on campwill-ec:raw (PII 含む)
#
# Usage:
#   bash scripts/grant-bq-access.sh user@campwill.me
#   bash scripts/grant-bq-access.sh user@campwill.me --with-raw
#
# 取り消し:
#   gcloud projects remove-iam-policy-binding campwill-ec \
#     --member="user:<email>" --role="roles/bigquery.jobUser"
#   bq remove-iam-policy-binding \
#     --member="user:<email>" --role="roles/bigquery.dataViewer" campwill-ec:mart
#   (raw 付与時は raw も同様に remove)

set -euo pipefail

PROJECT="campwill-ec"
EMAIL="${1:-}"
WITH_RAW="${2:-}"

if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 <user@campwill.me> [--with-raw]"
  exit 1
fi

echo "=== Granting BQ access for $EMAIL on $PROJECT ==="
echo ""

echo "[1/2] roles/bigquery.jobUser on project ..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="user:$EMAIL" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet

echo ""
echo "[2/2] roles/bigquery.dataViewer on $PROJECT:mart ..."
bq add-iam-policy-binding \
  --member="user:$EMAIL" \
  --role="roles/bigquery.dataViewer" \
  "$PROJECT:mart"

if [[ "$WITH_RAW" == "--with-raw" ]]; then
  echo ""
  echo "[OPT] roles/bigquery.dataViewer on $PROJECT:raw (PII included) ..."
  bq add-iam-policy-binding \
    --member="user:$EMAIL" \
    --role="roles/bigquery.dataViewer" \
    "$PROJECT:raw"
fi

echo ""
echo "=== Done. $EMAIL can now query mart$([ "${WITH_RAW:-}" == "--with-raw" ] && echo " + raw") ==="
echo ""
echo "Verification (run as $EMAIL):"
echo "  gcloud auth login"
echo "  gcloud config set project $PROJECT"
echo "  bq query --use_legacy_sql=false 'SELECT * FROM \`$PROJECT.mart.ec_daily_pnl\` LIMIT 5'"
