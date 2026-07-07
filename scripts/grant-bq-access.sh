#!/usr/bin/env bash
# grant-bq-access.sh — campwill-ec BQ アクセスをメンバーに付与する
#
# データ階層の前提:
#   mart = PII ゼロ (customer_email は SHA256 hash 化済)。一般メンバーはこれで完結すべき
#   raw  = PII 原データ (email/phone/name 等)。Shopify 管理画面 PII 閲覧者と同等の信頼が必要
#          ※注: raw.oauth_tokens に n8n の refresh_token / client_secret が plaintext で含まれる
#                 raw 開放時は実質「これらシステム認証情報も見える」と認識すること
#   sandbox_<lastname> = 個人専用 dataset (OWNER)。本人専用の派生テーブル / ad-hoc 分析用
#
# 付与内容:
#   1. roles/bigquery.jobUser on project (クエリ実行 + 課金)
#   2. roles/serviceusage.serviceUsageConsumer on project (BQ API 利用に必要)
#   3. READER on dataset campwill-ec:mart (mart 閲覧 — PII ゼロ)
#   4. (オプション --with-raw)     READER on campwill-ec:raw (PII 原データ + oauth_tokens)
#   5. (オプション --with-sandbox) sandbox_<lastname> dataset 作成 + OWNER 付与
#
# Usage:
#   bash scripts/grant-bq-access.sh user@campwill.me
#   bash scripts/grant-bq-access.sh user@campwill.me --with-raw
#   bash scripts/grant-bq-access.sh user@campwill.me --with-raw --with-sandbox
#   bash scripts/grant-bq-access.sh user@campwill.me --with-sandbox
#
# sandbox 命名規則:
#   sandbox_<lastname>       (例: sandbox_nakamura)
#   sandbox_<lastname>_<i>   (同姓多数の場合、例: sandbox_nakamura_h)
#   この script は email の "@" 前 (例: h_nakamura → nakamura) を lastname として推定。
#   違う命名にしたい場合は手動作成 + access edit。
#
# 取り消し（手動）:
#   gcloud projects remove-iam-policy-binding campwill-ec \
#     --member="user:<email>" --role="roles/bigquery.jobUser"
#   # dataset access は bq show + 手動編集 + bq update で削除
#   # sandbox dataset 削除は: bq rm -r -f campwill-ec:sandbox_<lastname>
#
# 注: bq add-iam-policy-binding は allowlist 必要な alpha 機能のため未使用。
#      代わりに bq show --format=prettyjson + python で access 配列を編集 + bq update。

set -euo pipefail

PROJECT="campwill-ec"
EMAIL=""
WITH_RAW=0
WITH_SANDBOX=0

# 引数パース (--with-raw / --with-sandbox の順序不問)
for arg in "$@"; do
  case "$arg" in
    --with-raw)     WITH_RAW=1 ;;
    --with-sandbox) WITH_SANDBOX=1 ;;
    *@*)            EMAIL="$arg" ;;
    *)              echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 <user@campwill.me> [--with-raw] [--with-sandbox]"
  exit 1
fi

# Python 実行可能性確認
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install Python 3 or activate gcloud bundled python."
  exit 1
fi

# email の "@" 前から lastname 推定 (例: h_nakamura@... → nakamura)
LOCAL_PART="${EMAIL%@*}"
if [[ "$LOCAL_PART" == *_* ]]; then
  LASTNAME="${LOCAL_PART##*_}"
else
  LASTNAME="$LOCAL_PART"
fi
SANDBOX="sandbox_${LASTNAME}"

grant_dataset_access() {
  local dataset="$1"
  local role="$2"   # READER / OWNER
  local tmp=".${dataset}-access.json"

  echo "  - Reading current access for $PROJECT:$dataset ..."
  bq show --format=prettyjson "$PROJECT:$dataset" > "$tmp"

  python3 - <<PYEOF "$tmp" "$EMAIL" "$role"
import json, sys
path, email, role = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: d = json.load(f)
new_entry = {'role': role, 'userByEmail': email}
if new_entry not in d.get('access', []):
    d.setdefault('access', []).append(new_entry)
    print(f'  - Added {role} for {email}')
else:
    print(f'  - {email} already has {role} (no change)')
with open(path, 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  - Applying update ..."
  bq update --source "$tmp" "$PROJECT:$dataset" >/dev/null
  rm "$tmp"
  echo "  - Done: $PROJECT:$dataset $role granted to $EMAIL"
}

echo "=== Granting BQ access for $EMAIL on $PROJECT ==="
echo ""

echo "[1/3] roles/bigquery.jobUser on project $PROJECT ..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="user:$EMAIL" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet >/dev/null
echo "  - Done"

echo ""
echo "[2/3] roles/serviceusage.serviceUsageConsumer on project $PROJECT ..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="user:$EMAIL" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None \
  --quiet >/dev/null
echo "  - Done"

echo ""
echo "[3/3] READER on $PROJECT:mart ..."
grant_dataset_access "mart" "READER"

if [[ "$WITH_RAW" == "1" ]]; then
  echo ""
  echo "[OPT-RAW] READER on $PROJECT:raw (PII + oauth_tokens 含む) ..."
  grant_dataset_access "raw" "READER"
fi

if [[ "$WITH_SANDBOX" == "1" ]]; then
  echo ""
  echo "[OPT-SANDBOX] Create $PROJECT:$SANDBOX + OWNER 付与 ..."
  # dataset が無ければ作る (冪等)
  if ! bq show "$PROJECT:$SANDBOX" >/dev/null 2>&1; then
    bq --project_id="$PROJECT" mk -d --location=asia-northeast1 \
      --description="$EMAIL personal sandbox (OWNER)" \
      "$PROJECT:$SANDBOX"
    echo "  - Created $PROJECT:$SANDBOX"
  else
    echo "  - $PROJECT:$SANDBOX already exists"
  fi
  grant_dataset_access "$SANDBOX" "OWNER"
fi

echo ""
MSG_DS="mart"
[[ "$WITH_RAW"     == "1" ]] && MSG_DS="$MSG_DS + raw"
[[ "$WITH_SANDBOX" == "1" ]] && MSG_DS="$MSG_DS + $SANDBOX (OWNER)"
echo "=== Done. $EMAIL can now query: $MSG_DS ==="
echo ""
echo "Verification (run as $EMAIL):"
echo "  gcloud auth login"
echo "  gcloud config set project $PROJECT"
echo "  bq query --use_legacy_sql=false 'SELECT * FROM \`$PROJECT.mart.ec_daily_pnl\` LIMIT 5'"
if [[ "$WITH_SANDBOX" == "1" ]]; then
echo "  bq query --use_legacy_sql=false 'CREATE OR REPLACE TABLE \`$PROJECT.$SANDBOX.test\` AS SELECT 1 AS x'"
fi
