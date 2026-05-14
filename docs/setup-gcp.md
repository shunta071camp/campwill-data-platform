# GCP セットアップ手順

このドキュメントは仕様書 §2 の GCP プロジェクト構成を `gcloud` / `bq` CLI で構築する手順をまとめたもの。

---

## 0. 事前準備

### 0.1 gcloud CLI のインストール

```bash
# Windows (Chocolatey)
choco install gcloudsdk

# 認証
gcloud auth login
gcloud auth application-default login
```

### 0.2 請求アカウント ID の取得

```bash
gcloud beta billing accounts list
```

出力例：
```
ACCOUNT_ID            NAME                OPEN  MASTER_ACCOUNT_ID
01ABCD-234567-89EFGH  My Billing Account  True
```

`ACCOUNT_ID` を環境変数に設定：

```bash
export BILLING_ACCOUNT_ID="01ABCD-234567-89EFGH"
```

### 0.3 組織 / フォルダ ID（任意）

組織配下にプロジェクトを置く場合：

```bash
gcloud organizations list
export ORG_ID="123456789012"   # 任意
```

---

## 1. プロジェクト作成・IAM 設定

```bash
bash scripts/setup-gcp.sh
```

実行内容：
1. 3 つのプロジェクト作成（`campwill-ec`, `campwill-realestate`, `campwill-central`）
2. 各プロジェクトに請求アカウントをリンク
3. 必要 API の有効化（BigQuery API など）
4. サービスアカウント作成（`n8n-pipeline`, `looker-studio-reader`）
5. IAM ロール付与
6. サービスアカウント鍵を `.keys/` に出力

**注意**: プロジェクト ID はグローバルにユニークである必要がある。`campwill-ec` などが既に他組織で使われている場合は、`PROJECT_PREFIX` を変更すること（スクリプト先頭の環境変数）。

```bash
export PROJECT_PREFIX="campwill"   # 既定。ユニークでなければ変更
bash scripts/setup-gcp.sh
```

---

## 2. データセット作成

```bash
bash scripts/create-datasets.sh
```

実行内容（リージョンは `asia-northeast1` 固定）：
- `campwill-ec`: `raw`, `mart`, `ga4_export`
- `campwill-realestate`: `raw`, `mart`, `ga4_export`
- `campwill-central`: `mart_all`

**重要**: `ga4_export` データセットは GA4 側でエクスポートを設定すると自動でテーブルが作成されるため、手動でテーブルは作らない。

---

## 3. raw テーブル作成（EC 事業のみ）

```bash
bash scripts/create-raw-tables.sh
```

`bigquery/campwill-ec/raw/*.json` を `bq mk --table` で 11 個作成：
- ec_shopify_orders / ec_shopify_customers
- ec_google_ads / ec_meta_ads / ec_yahoo_ads / ec_microsoft_ads
- ec_search_console / ec_instagram_organic
- ec_klaviyo_campaigns / ec_klaviyo_profiles
- ec_backlog_issues

---

## 4. mart テーブル作成

```bash
bash scripts/create-mart-tables.sh
```

実行内容：
1. `mart.ec_cost_master` / `mart.ec_shipping_rules` をスキーマ JSON で作成
2. `mart.ec_daily_pnl` / `ec_channel_roi` / `ec_klaviyo_conversion` / `ec_weekly_summary` を SQL 実行で作成

mart の 4 テーブルは `CREATE OR REPLACE TABLE` で常に再生成可能。後日 BigQuery のスケジュールクエリに登録する想定。

---

## 5. 初期マスタ投入

### 送料マスタ

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  < seeds/ec_shipping_rules_seed.sql
```

仕様書通り `(2026-01-01, 2026-12-31, 1000円)` を 1 行 INSERT。送料変更時はこのテーブルに新しい期間で行を追加し、古い行の `valid_to` を更新する運用。

### 単価マスタ

`seeds/ec_cost_master_seed_template.csv` をコピーして SKU と単価を埋める：

```bash
cp seeds/ec_cost_master_seed_template.csv seeds/ec_cost_master.csv
# エディタで SKU,cost_price,valid_from,valid_to を埋める
# (ec_cost_master.csv は .gitignore で除外済み)

bq load \
  --source_format=CSV \
  --skip_leading_rows=1 \
  --project_id=campwill-ec \
  campwill-ec:mart.ec_cost_master \
  seeds/ec_cost_master.csv \
  bigquery/campwill-ec/mart/ec_cost_master.json
```

---

## 6. 動作確認

```bash
# raw テーブル一覧（11 個揃っているか）
bq ls --project_id=campwill-ec campwill-ec:raw

# mart テーブル一覧
bq ls --project_id=campwill-ec campwill-ec:mart

# 送料マスタ確認
bq query --use_legacy_sql=false --project_id=campwill-ec \
  'SELECT * FROM `campwill-ec.mart.ec_shipping_rules`'
```

---

## 7. トラブルシュート

### `Error: BillingAccount ... is not enabled`

請求アカウントが有効化されていない。GCP Console で `BillingAccount` の状態を確認。

### `Error: API ... has not been used in project ... before`

API 有効化直後はメタデータ伝播に数分かかることがある。`sleep 30` を挟んで再実行。

### `Error: Project ID ... already exists`

プロジェクト ID はグローバルにユニーク。`PROJECT_PREFIX` を変更（例: `campwill-2026`）して再実行。

### `Error: Permission denied on resource`

`gcloud auth login` 済みのアカウントに `Project Creator` ロールがない。組織管理者に依頼するか、個人アカウントの場合は `roles/owner` で代用。

---

## 8. 次フェーズへの引き継ぎ

このセットアップが完了したら：
1. **GA4 BigQuery エクスポート設定** — GA4 管理画面 → BigQuery のリンク → `campwill-ec` プロジェクトを選択
2. **n8n Pro の接続設定** — `.keys/n8n-pipeline-campwill-ec.json` を n8n の Credentials に登録
3. **Looker Studio** — `looker-studio-reader-campwill-ec.json` を使ってデータ接続
4. **n8n ワークフロー構築** — 仕様書 §4 のスケジュールで各データソースを raw に投入
