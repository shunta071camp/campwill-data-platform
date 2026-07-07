#!/usr/bin/env bash
# CAMPWILL BQ アナリスト プロキシ Cloud Run デプロイスクリプト
# 前提:
#   1. gcloud auth login 済み
#   2. gcloud config set project campwill-ec 済み
#   3. Secret Manager に以下 2 本を作成済み
#      - bq-analyst-anthropic-key  (Anthropic API キー)
#      - bq-analyst-shared-secret  (HTML 利用者向けの共有秘密)
#   4. SA looker-studio-reader@campwill-ec.iam.gserviceaccount.com が存在し、
#      mart dataset の READER + bigquery.jobUser を保有
#
# 実行: bash bq-proxy/deploy.sh

set -euo pipefail

REGION="asia-northeast1"
PROJECT="campwill-ec"
SERVICE="bq-analyst-proxy"
SA="looker-studio-reader@${PROJECT}.iam.gserviceaccount.com"

cd "$(dirname "$0")"

echo "→ Deploying ${SERVICE} to Cloud Run (${REGION})..."
gcloud run deploy "${SERVICE}" \
  --source . \
  --region "${REGION}" \
  --project "${PROJECT}" \
  --service-account "${SA}" \
  --allow-unauthenticated \
  --memory 512Mi \
  --cpu 1 \
  --timeout 120 \
  --max-instances 5 \
  --min-instances 0 \
  --update-secrets "ANTHROPIC_API_KEY=bq-analyst-anthropic-key:latest,SHARED_SECRET=bq-analyst-shared-secret:latest" \
  --set-env-vars "BQ_PROJECT=${PROJECT},BQ_LOCATION=${REGION},MAX_BYTES_BILLED=5368709120,ANTHROPIC_MODEL=claude-haiku-4-5"

echo ""
echo "→ Deployed. Service URL:"
gcloud run services describe "${SERVICE}" \
  --region "${REGION}" \
  --project "${PROJECT}" \
  --format "value(status.url)"

echo ""
echo "→ X-API-Key (HTML 利用者向け配布):"
gcloud secrets versions access latest --secret=bq-analyst-shared-secret --project="${PROJECT}"
echo ""
echo "(値は社内のみで配布してください)"
