# CAMPWILL Data Platform — Claude Code / Codex 利用ガイド

このリポジトリは CAMPWILL の EC・不動産事業のデータ基盤（BigQuery + n8n + Claude API）。Claude Code / Codex で BigQuery を扱うときの前提を以下にまとめる。

---

## プロジェクト構成

| GCP プロジェクト | 用途 | 状態 |
|---|---|---|
| `campwill-ec` | EC 事業（kubell）— raw 15 + mart 12 テーブル、Scheduled Query 12 本稼働中 | **稼働中** |
| `campwill-realestate` | 不動産事業（クラスラ）— raw 5 + mart 5、自社案件管理 (tenant-leasing) + GA4 + SC | **構築中** |
| `campwill-central` | 全社横断（Phase 3） | placeholder |

- ロケーション: **`asia-northeast1`**（東京）固定。GA4 Export と一致が必須
- 日次バッチは UTC 23:00–23:55（JST 08:00–08:55）に集中

---

## データセットの使い分け

### `campwill-ec.raw` — 生データ（PII 含む、扱い注意）

| テーブル | 内容 | 注意 |
|---|---|---|
| `ec_shopify_orders` | Shopify 注文 | **email / phone 等 PII** |
| `ec_shopify_customers` | Shopify 顧客 | **PII** |
| `ec_shopify_products_daily` | 商品+原価日次スナップショット | |
| `ec_klaviyo_campaigns` / `ec_klaviyo_profiles` | Klaviyo メール配信 | **PII** |
| `ec_meta_ads` (VIEW) | Meta 広告 — BQ DTS 経由 | |
| `ec_google_ads` (VIEW) | Google 広告 — BQ DTS 経由 | |
| `ec_search_console` (VIEW) | GSC — Bulk Export 経由 | |
| `ec_yahoo_ads` / `ec_microsoft_ads` | Yahoo / MS 広告 | |
| `ec_instagram_organic` | Instagram オーガニック | |
| `ec_backlog_issues` | Backlog 課題 | |
| `rakko_inflow_keywords` | ラッコ KW（自社+競合 7URL × 週次） | |
| `oauth_tokens` / `oauth_tokens_history` | n8n の OAuth refresh_token 管理 | **secret** |

### `campwill-realestate.raw` — 不動産生データ（PII 含む）

| テーブル | 内容 | ソース |
|---|---|---|
| `re_tenants` | テナント (=問い合わせ起点) | tenant-leasing `/api/export/tenants` |
| `re_deals` | 案件 (DealStatus enum) | tenant-leasing `/api/export/deals` |
| `re_activities` | 活動履歴 | tenant-leasing `/api/export/activities` |
| `re_properties` | 物件 | tenant-leasing `/api/export/properties` |
| `re_owners` | オーナー | tenant-leasing `/api/export/owners` |
| `re_search_console` (VIEW) | krasula.jp の SC | SC Bulk Export |

### `campwill-realestate.mart` — 不動産分析用

| テーブル | 用途 |
|---|---|
| `re_lead_funnel` | 日次ファネル: 流入 → 問合せ → 案件化 → 成約 |
| `re_case_pipeline` | 現時点パイプライン (status 別件数 / 平均経過日数) |
| `re_seo_inquiry_attribution` | SC 検索クエリ × 問合せ貢献 |
| `re_property_performance` | 物件別 KPI (案件数 / 成約率 / リードタイム) |
| `re_weekly_summary` | 週次サマリ + WoW 比較 |

詳細は [bigquery/campwill-realestate/README.md](bigquery/campwill-realestate/README.md) 参照。

### `campwill-ec.mart` — 分析用集計済データ（PII 除去済、これを使う）

| テーブル | 用途 |
|---|---|
| `ec_daily_pnl` | 日次 PnL（売上・原価・送料・粗利） |
| `ec_channel_roi` | チャネル別 ROI（広告 vs オーガニック） |
| `ec_klaviyo_conversion` | Klaviyo メール起点 CV |
| `ec_weekly_summary` | 週次サマリ |
| `ec_customer_profile` | 顧客 1 行（休眠フラグ・お気に入り SKU 等、180 日休眠定義） |
| `ec_cohort_ltv` | コホート × 月次 LTV |
| `ec_repeat_pattern` | リピート order_index 1-10 + 間隔分析 |
| `ec_sku_trend` | SKU の MoM/YoY + rising/declining 分類 |
| `ec_search_to_purchase` | SC 検索 → 購入導線 |
| `ec_attribution_first_last` | ファースト/ラストアトリビューション |
| `ec_seo_opportunity` | SEO 機会金額化（SC × Rakko 統合） |
| `ec_competitor_gap` | 競合のみ獲得 KW（自社未獲得） |
| `ec_cost_master` (VIEW) | SKU 単価マスタ（Shopify products から自動派生） |
| `ec_shipping_rules` | 送料マスタ（seed） |

---

## コスト・ガードレール（必読）

BigQuery on-demand: **$6.25/TB スキャン**。誤クエリで TB 飛ばないよう以下を遵守:

1. **`maximum_bytes_billed` を必ず付ける**（10 GB 上限）
   ```bash
   bq query --use_legacy_sql=false --maximum_bytes_billed=10737418240 "SELECT ..."
   ```
   `~/.bigqueryrc` に `--maximum_bytes_billed=10737418240` 設定済なら不要。

2. **partition / cluster を意識**: 日付フィルタを必ず付ける
   ```sql
   -- BAD: full scan
   SELECT * FROM `campwill-ec.raw.ec_shopify_orders`

   -- GOOD: partition 効く
   SELECT * FROM `campwill-ec.raw.ec_shopify_orders`
   WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
   ```

3. **本番クエリの前に dry-run**:
   ```bash
   bq query --use_legacy_sql=false --dry_run "SELECT ..."
   # → 「This query will process X bytes.」を確認
   ```

4. **raw を直接叩く前に mart で代替できないか確認**: mart は集計済で軽い

5. プロジェクト全体に **1 TB/user/day の Custom Quota 設定済**（暴発時は強制ブロック）

---

## やってはいけないこと

- ❌ raw の email / phone を Slack や外部に送信（PII 漏洩）
- ❌ mart テーブルへの INSERT/UPDATE/DELETE（DataViewer 権限のみ）
- ❌ `.keys/` 配下のファイルを git add（既に `.gitignore` 除外、絶対に外さない）
- ❌ `SELECT *` を partition フィルタなしで叩く（コスト爆発）
- ❌ `--maximum_bytes_billed` 無しのクエリ
- ❌ raw からの集計を独自に量産（mart に同等のロジックがあるか先に確認）

---

## ローカル環境（Windows 前提）

```
gcloud パス: C:\Users\<user>\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd
bq パス:    C:\Users\<user>\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\bq.cmd
```

### Bash で bq / gcloud 実行時の必須環境変数

日本語 description のスキーマ JSON が cp932 で読めずクラッシュするため:

```bash
export PATH="/c/Users/<user>/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/<user>/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
```

### 認証（初回のみ）

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project campwill-ec
```

---

## 典型クエリ例

```sql
-- 直近 7 日の PnL
SELECT * FROM `campwill-ec.mart.ec_daily_pnl`
WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
ORDER BY date DESC;

-- チャネル別 ROI（直近 30 日）
SELECT channel, SUM(revenue) AS rev, SUM(ad_cost) AS cost,
       SAFE_DIVIDE(SUM(revenue), SUM(ad_cost)) AS roas
FROM `campwill-ec.mart.ec_channel_roi`
WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY channel
ORDER BY roas DESC;

-- SEO 機会 Top 20（推定損失額順）
SELECT keyword, opportunity_type, estimated_monthly_loss_yen, sc_recent_position
FROM `campwill-ec.mart.ec_seo_opportunity`
WHERE estimated_monthly_loss_yen > 0
ORDER BY estimated_monthly_loss_yen DESC
LIMIT 20;

-- 休眠顧客 Top 100（180 日購入なし）
SELECT email_hash, last_order_date, total_orders, total_spent
FROM `campwill-ec.mart.ec_customer_profile`
WHERE is_dormant = TRUE
ORDER BY total_spent DESC
LIMIT 100;
```

---

## n8n ワークフロー（参考）

`n8n/workflows/` 配下に 12 本の JSON。Active 中:
- `shopify-orders-incremental` (毎日 04:30 JST)
- `shopify-products-daily` (毎日 02:00 JST)
- `klaviyo-{campaigns,profiles}` (毎日 03:00 JST)
- `instagram-organic` (毎日 03:30 JST)
- `microsoft-ads-incremental` (毎日 03:10 JST)
- `yahoo-ads-incremental` (毎日 03:20 JST)
- `rakko-inflow-weekly` (月曜 04:00 JST)
- `error-handler` (Error Trigger → Slack #n8n_alert)

詳細は `n8n/docs/` 配下。

---

## ローカルフォルダ名と repo 名の差異

- **GitHub repo 名**: `campwill-data-platform`（新規 clone はこの名前のフォルダ）
- **既存運用者ローカル**: `campwill-ai-ready/`（OneDrive sync 都合で初期名のまま据え置き）

両者は同一リポジトリ。新規メンバーは `campwill-data-platform/` フォルダで運用される。

---

## 参考

- セットアップ手順: [docs/onboarding.md](docs/onboarding.md)
- 元仕様書: [docs/spec.md](docs/spec.md)
- GCP 初期セットアップ: [docs/setup-gcp.md](docs/setup-gcp.md)
- BQ Scheduled Queries: [n8n/docs/bq-scheduled-queries.md](n8n/docs/bq-scheduled-queries.md)
- 各種クレデンシャル設定: [n8n/docs/credentials-setup.md](n8n/docs/credentials-setup.md)
