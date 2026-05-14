#!/usr/bin/env bash
# setup-gcp.sh
# 仕様書 §2 の GCP プロジェクト構成を gcloud で構築する。
#   - 3 プロジェクト作成 (campwill-ec / campwill-realestate / campwill-central)
#   - 請求アカウントリンク
#   - BigQuery API 有効化
#   - サービスアカウント (n8n-pipeline, looker-studio-reader) 作成 + IAM 付与
#   - サービスアカウント鍵を .keys/ に出力
#
# 事前準備:
#   gcloud auth login
#   export BILLING_ACCOUNT_ID="01ABCD-234567-89EFGH"
#   (任意) export PROJECT_PREFIX="campwill"   # 衝突したら別の名前に変更
#   (任意) export ORG_ID="123456789012"

set -euo pipefail

# ===== 設定 =====
PROJECT_PREFIX="${PROJECT_PREFIX:-campwill}"
PROJECTS=("ec" "realestate" "central")
REGION="asia-northeast1"
KEYS_DIR="$(cd "$(dirname "$0")/.." && pwd)/.keys"

if [[ -z "${BILLING_ACCOUNT_ID:-}" ]]; then
  echo "ERROR: BILLING_ACCOUNT_ID is not set."
  echo "  Run: gcloud beta billing accounts list  →  export BILLING_ACCOUNT_ID=\"...\""
  exit 1
fi

mkdir -p "$KEYS_DIR"
echo "===> Service account keys will be written to: $KEYS_DIR"
echo "===> Project prefix: $PROJECT_PREFIX"
echo

# ===== プロジェクト作成・請求リンク・API 有効化 =====
for SUFFIX in "${PROJECTS[@]}"; do
  PROJECT_ID="${PROJECT_PREFIX}-${SUFFIX}"
  echo "========================================="
  echo "Project: $PROJECT_ID"
  echo "========================================="

  # 既存チェック (idempotent)
  if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
    echo "  [skip] Project $PROJECT_ID already exists"
  else
    echo "  [create] Project $PROJECT_ID"
    if [[ -n "${ORG_ID:-}" ]]; then
      gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"
    else
      gcloud projects create "$PROJECT_ID"
    fi
  fi

  # 請求アカウントリンク
  CURRENT_BILLING="$(gcloud beta billing projects describe "$PROJECT_ID" \
    --format='value(billingAccountName)' 2>/dev/null || true)"
  if [[ "$CURRENT_BILLING" == *"$BILLING_ACCOUNT_ID"* ]]; then
    echo "  [skip] Billing already linked"
  else
    echo "  [link] Billing account $BILLING_ACCOUNT_ID"
    gcloud beta billing projects link "$PROJECT_ID" \
      --billing-account="$BILLING_ACCOUNT_ID"
  fi

  # API 有効化
  echo "  [enable] APIs (bigquery, iam)"
  gcloud services enable \
    bigquery.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

  # サービスアカウント: n8n-pipeline (write)
  SA_N8N="n8n-pipeline@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$SA_N8N" --project="$PROJECT_ID" &>/dev/null; then
    echo "  [skip] SA n8n-pipeline already exists"
  else
    echo "  [create] SA n8n-pipeline"
    gcloud iam service-accounts create "n8n-pipeline" \
      --project="$PROJECT_ID" \
      --display-name="n8n ETL Pipeline"
  fi
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_N8N" \
    --role="roles/bigquery.dataEditor" \
    --condition=None --quiet >/dev/null
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_N8N" \
    --role="roles/bigquery.jobUser" \
    --condition=None --quiet >/dev/null

  # サービスアカウント: looker-studio-reader (read)
  SA_LOOKER="looker-studio-reader@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$SA_LOOKER" --project="$PROJECT_ID" &>/dev/null; then
    echo "  [skip] SA looker-studio-reader already exists"
  else
    echo "  [create] SA looker-studio-reader"
    gcloud iam service-accounts create "looker-studio-reader" \
      --project="$PROJECT_ID" \
      --display-name="Looker Studio Reader"
  fi
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_LOOKER" \
    --role="roles/bigquery.dataViewer" \
    --condition=None --quiet >/dev/null
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_LOOKER" \
    --role="roles/bigquery.jobUser" \
    --condition=None --quiet >/dev/null

  # 鍵 JSON 出力 (既存があればスキップ)
  KEY_N8N="$KEYS_DIR/n8n-pipeline-${PROJECT_ID}.json"
  if [[ -f "$KEY_N8N" ]]; then
    echo "  [skip] Key already exists: $KEY_N8N"
  else
    echo "  [create-key] $KEY_N8N"
    gcloud iam service-accounts keys create "$KEY_N8N" \
      --iam-account="$SA_N8N" \
      --project="$PROJECT_ID"
  fi

  KEY_LOOKER="$KEYS_DIR/looker-studio-reader-${PROJECT_ID}.json"
  if [[ -f "$KEY_LOOKER" ]]; then
    echo "  [skip] Key already exists: $KEY_LOOKER"
  else
    echo "  [create-key] $KEY_LOOKER"
    gcloud iam service-accounts keys create "$KEY_LOOKER" \
      --iam-account="$SA_LOOKER" \
      --project="$PROJECT_ID"
  fi

  echo
done

echo "===> setup-gcp.sh completed."
echo "===> Next: bash scripts/create-datasets.sh"
