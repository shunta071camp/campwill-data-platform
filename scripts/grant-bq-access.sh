#!/usr/bin/env bash
# grant-bq-access.sh — campwill-ec BQ アクセスをメンバーに付与する
#
# 付与内容:
#   1. roles/bigquery.jobUser on project (クエリ実行 + 課金)
#   2. READER on dataset campwill-ec:mart (mart 閲覧)
#   3. (オプション --with-raw) READER on campwill-ec:raw (PII 含む)
#
# Usage:
#   bash scripts/grant-bq-access.sh user@campwill.me
#   bash scripts/grant-bq-access.sh user@campwill.me --with-raw
#
# 取り消し（手動）:
#   gcloud projects remove-iam-policy-binding campwill-ec \
#     --member="user:<email>" --role="roles/bigquery.jobUser"
#   # dataset access は bq show + 手動編集 + bq update で削除
#
# 注: bq add-iam-policy-binding は allowlist 必要な alpha 機能のため未使用。
#      代わりに bq show --format=prettyjson + python で access 配列を編集 + bq update。

set -euo pipefail

PROJECT="campwill-ec"
EMAIL="${1:-}"
WITH_RAW="${2:-}"

if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 <user@campwill.me> [--with-raw]"
  exit 1
fi

# Python 実行可能性確認
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install Python 3 or activate gcloud bundled python."
  exit 1
fi

grant_dataset_reader() {
  local dataset="$1"
  local tmp=".${dataset}-access.json"

  echo "  - Reading current access for $PROJECT:$dataset ..."
  bq show --format=prettyjson "$PROJECT:$dataset" > "$tmp"

  python3 - <<PYEOF "$tmp" "$EMAIL"
import json, sys
path, email = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
new_entry = {'role': 'READER', 'userByEmail': email}
if new_entry not in d['access']:
    d['access'].append(new_entry)
    print(f'  - Added READER for {email}')
else:
    print(f'  - {email} already has READER (no change)')
with open(path, 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF

  echo "  - Applying update ..."
  bq update --source "$tmp" "$PROJECT:$dataset" >/dev/null
  rm "$tmp"
  echo "  - Done: $PROJECT:$dataset READER granted to $EMAIL"
}

echo "=== Granting BQ access for $EMAIL on $PROJECT ==="
echo ""

echo "[1/2] roles/bigquery.jobUser on project $PROJECT ..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="user:$EMAIL" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet >/dev/null
echo "  - Done"

echo ""
echo "[2/2] READER on $PROJECT:mart ..."
grant_dataset_reader "mart"

if [[ "$WITH_RAW" == "--with-raw" ]]; then
  echo ""
  echo "[OPT] READER on $PROJECT:raw (PII included) ..."
  grant_dataset_reader "raw"
fi

echo ""
echo "=== Done. $EMAIL can now query mart$([ "${WITH_RAW:-}" == "--with-raw" ] && echo " + raw") ==="
echo ""
echo "Verification (run as $EMAIL):"
echo "  gcloud auth login"
echo "  gcloud config set project $PROJECT"
echo "  bq query --use_legacy_sql=false 'SELECT * FROM \`$PROJECT.mart.ec_daily_pnl\` LIMIT 5'"
