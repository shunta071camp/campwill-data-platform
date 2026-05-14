# CAMPWILL AI-Ready / Data Platform

CAMPWILL の EC・不動産事業のデータ基盤。BigQuery + n8n + Claude API による AI 分析自動化の **Phase 1（データ基盤構築）** の成果物を管理する。

> 全社戦略・OKR は [campwill/](../campwill/) を参照。本リポジトリは How（実装）を扱う。

---

## ディレクトリ構成

| パス | 内容 |
|---|---|
| [docs/spec.md](docs/spec.md) | 元仕様書（CAMPWILL_AI_READY.md） |
| [docs/setup-gcp.md](docs/setup-gcp.md) | GCP セットアップ手順書 |
| [bigquery/campwill-ec/raw/](bigquery/campwill-ec/raw/) | EC 事業 raw テーブル スキーマ JSON（11 個） |
| [bigquery/campwill-ec/mart/](bigquery/campwill-ec/mart/) | EC 事業 mart テーブル スキーマ JSON / DDL SQL |
| [bigquery/campwill-realestate/](bigquery/campwill-realestate/) | 不動産事業（仕様未確定） |
| [bigquery/campwill-central/](bigquery/campwill-central/) | 全社横断（Phase 3） |
| [seeds/](seeds/) | 初期マスタデータ（送料・単価） |
| [scripts/](scripts/) | gcloud / bq セットアップスクリプト |

---

## セットアップ手順

詳細は [docs/setup-gcp.md](docs/setup-gcp.md) を参照。

```bash
# 0. 事前準備: gcloud CLI 認証 + 請求アカウント ID を取得
gcloud auth login
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"

# 1. GCP プロジェクト 3 つ + IAM + サービスアカウント作成
bash scripts/setup-gcp.sh

# 2. データセット作成 (asia-northeast1)
bash scripts/create-datasets.sh

# 3. raw テーブル 11 個作成
bash scripts/create-raw-tables.sh

# 4. mart テーブル作成 (cost_master / shipping_rules / ec_daily_pnl 等)
bash scripts/create-mart-tables.sh

# 5. 初期マスタ投入
bq query --use_legacy_sql=false < seeds/ec_shipping_rules_seed.sql
# 単価マスタは seeds/ec_cost_master_seed_template.csv に SKU を埋めてから:
# bq load --source_format=CSV --skip_leading_rows=1 \
#   campwill-ec:mart.ec_cost_master seeds/ec_cost_master.csv
```

---

## 重要ルール

- **リージョン**: 必ず `asia-northeast1`（東京）。GA4 BigQuery エクスポートと同一リージョンでないと結合不可。
- **サービスアカウント鍵**: `.keys/` 配下に出力。`.gitignore` で除外済み。
- **rawテーブル**: 上書き・追記のみ。削除しない。
- **martテーブル**: raw から何度でも再生成できる状態を維持。
- **結合キー**: 詳細は [docs/spec.md](docs/spec.md) §5.1 参照。

---

## 本プロジェクトの非対象

以下は後続フェーズで対応：
- n8n ワークフロー JSON（Phase 1 後半）
- 不動産事業の raw/mart スキーマ（仕様未確定）
- campwill-central の横断 mart（Phase 3）
- Claude API 週次レポート Python（Phase 2）
- Looker Studio 設定（Phase 2）
