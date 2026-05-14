# CAMPWILL AI-Ready システム設計仕様書

> このドキュメントはClaude Codeが読み取り、実装を進めるための設計仕様書です。
> 以降の構築作業はこのドキュメントを参照しながらClaude Codeで実行してください。

---

## 0. プロジェクト概要

| 項目 | 内容 |
|---|---|
| 目的 | 2人→3人体制で年商10億円を達成するためのAI-Ready化 |
| 現状 | 2人・年商2億円 |
| 期待効果 | 1人あたり生産性5倍・日次KPI転記作業ほぼゼロ化 |
| 主要ツール | Google BigQuery / n8n Pro / Claude API / Claude Code |
| ETLツール | n8n Pro（クラウド版・セルフホストなし） |
| 対象事業 | EC事業（CAMPWILL）/ 不動産事業 |

---

## 1. アーキテクチャ全体像

```
【データソース】
EC事業：Shopify / GA4 / Google広告 / Meta広告 / Yahoo!広告
        Microsoft広告 / Googleサーチコンソール
        Instagramオーガニック / Klaviyo / Backlog / Slack
不動産事業：問い合わせデータ / GA4 / 広告媒体 / Backlog / Slack
        ↓
【ETL】n8n Pro（クラウド版）
        ↓
【DWH】Google BigQuery（3プロジェクト構成）
        ↓
【AI分析】Claude API / Claude Code
        ↓
【アウトプット】Slack自動レポート / Looker Studio / Backlogタスク自動生成
```

---

## 2. Google Cloudプロジェクト構成

### 2.1 プロジェクト一覧

| プロジェクト名 | 用途 | リージョン |
|---|---|---|
| `campwill-ec` | EC事業専用 | asia-northeast1（東京）|
| `campwill-realestate` | 不動産事業専用 | asia-northeast1（東京）|
| `campwill-central` | 全社横断分析 | asia-northeast1（東京）|

> **重要:** リージョンは必ず `asia-northeast1`（東京）に統一すること。
> GA4 BigQueryエクスポートと同じリージョンでないとデータ結合できない。

### 2.2 IAM・サービスアカウント設計

```
サービスアカウント名：n8n-pipeline
付与する権限：
  - roles/bigquery.dataEditor（データ書き込み用）
  - roles/bigquery.jobUser（クエリ実行用）

サービスアカウント名：looker-studio-reader
付与する権限：
  - roles/bigquery.dataViewer（読み取り専用）
```

---

## 3. BigQueryデータセット・テーブル設計

### 3.1 campwill-ec（EC事業）

#### データセット構成

| データセット | 用途 |
|---|---|
| `raw` | 各ツールからの生データをそのまま保存 |
| `mart` | rawを整形・結合した分析用テーブル |
| `ga4_export` | GA4が自動生成（手動作成不要）|

#### rawテーブル一覧

##### `raw.ec_shopify_orders`（注文データ・1注文×1SKU=1行）

```json
[
  {"name": "order_id",        "type": "STRING",    "mode": "REQUIRED", "description": "注文ID（主キー）"},
  {"name": "order_name",      "type": "STRING",    "mode": "NULLABLE", "description": "注文番号（#1001）"},
  {"name": "created_at",      "type": "TIMESTAMP", "mode": "REQUIRED", "description": "注文日時"},
  {"name": "order_date",      "type": "DATE",      "mode": "REQUIRED", "description": "注文日（集計用）"},
  {"name": "customer_id",     "type": "STRING",    "mode": "NULLABLE", "description": "顧客ID"},
  {"name": "customer_email",  "type": "STRING",    "mode": "REQUIRED", "description": "メールアドレス（Klaviyo結合キー・NOT NULL）"},
  {"name": "financial_status","type": "STRING",    "mode": "NULLABLE", "description": "支払状況（paid/refunded等）"},
  {"name": "total_price",     "type": "INTEGER",   "mode": "REQUIRED", "description": "注文合計金額（円）"},
  {"name": "subtotal_price",  "type": "INTEGER",   "mode": "NULLABLE", "description": "小計（送料・税抜き）"},
  {"name": "total_discounts", "type": "INTEGER",   "mode": "NULLABLE", "description": "割引合計額（円）"},
  {"name": "total_tax",       "type": "INTEGER",   "mode": "NULLABLE", "description": "税額（円）"},
  {"name": "line_item_id",    "type": "STRING",    "mode": "REQUIRED", "description": "行ID（主キー補助）"},
  {"name": "product_id",      "type": "STRING",    "mode": "NULLABLE", "description": "商品ID"},
  {"name": "variant_id",      "type": "STRING",    "mode": "NULLABLE", "description": "バリアントID"},
  {"name": "sku",             "type": "STRING",    "mode": "REQUIRED", "description": "SKUコード（原価マスタ結合キー）"},
  {"name": "sku_title",       "type": "STRING",    "mode": "NULLABLE", "description": "商品名"},
  {"name": "variant_title",   "type": "STRING",    "mode": "NULLABLE", "description": "バリアント名（黒/赤等）"},
  {"name": "quantity",        "type": "INTEGER",   "mode": "REQUIRED", "description": "購入数"},
  {"name": "unit_price",      "type": "INTEGER",   "mode": "REQUIRED", "description": "単価（円）"},
  {"name": "line_discount",   "type": "INTEGER",   "mode": "NULLABLE", "description": "行割引額（円）"},
  {"name": "is_refunded",     "type": "BOOLEAN",   "mode": "REQUIRED", "description": "返金済みフラグ"},
  {"name": "refund_date",     "type": "DATE",      "mode": "NULLABLE", "description": "返金日"},
  {"name": "refund_amount",   "type": "INTEGER",   "mode": "NULLABLE", "description": "返金額（円）"},
  {"name": "refund_reason",   "type": "STRING",    "mode": "NULLABLE", "description": "返金理由"},
  {"name": "source_name",     "type": "STRING",    "mode": "NULLABLE", "description": "流入元（web/pos等）"},
  {"name": "landing_site",    "type": "STRING",    "mode": "NULLABLE", "description": "ランディングページURL"},
  {"name": "referring_site",  "type": "STRING",    "mode": "NULLABLE", "description": "参照元URL"},
  {"name": "utm_source",      "type": "STRING",    "mode": "NULLABLE", "description": "UTM source（パース済み）"},
  {"name": "utm_medium",      "type": "STRING",    "mode": "NULLABLE", "description": "UTM medium（パース済み）"},
  {"name": "utm_campaign",    "type": "STRING",    "mode": "NULLABLE", "description": "UTM campaign（パース済み）"},
  {"name": "tags",            "type": "STRING",    "mode": "NULLABLE", "description": "注文タグ"},
  {"name": "inserted_at",     "type": "TIMESTAMP", "mode": "REQUIRED", "description": "BigQuery挿入日時"}
]
```

##### `raw.ec_shopify_customers`（顧客データ・1顧客1行）

```json
[
  {"name": "customer_id",       "type": "STRING",    "mode": "REQUIRED", "description": "顧客ID（主キー）"},
  {"name": "email",             "type": "STRING",    "mode": "REQUIRED", "description": "メールアドレス（Klaviyo結合キー）"},
  {"name": "created_at",        "type": "TIMESTAMP", "mode": "REQUIRED", "description": "初回購入日時"},
  {"name": "orders_count",      "type": "INTEGER",   "mode": "NULLABLE", "description": "累計注文回数"},
  {"name": "total_spent",       "type": "INTEGER",   "mode": "NULLABLE", "description": "累計購入金額（円）"},
  {"name": "accepts_marketing", "type": "BOOLEAN",   "mode": "NULLABLE", "description": "メール受信同意"},
  {"name": "tags",              "type": "STRING",    "mode": "NULLABLE", "description": "顧客タグ"},
  {"name": "inserted_at",       "type": "TIMESTAMP", "mode": "REQUIRED", "description": "BigQuery挿入日時"}
]
```

##### `raw.ec_google_ads`（Google広告・1日×1キャンペーン1行）

```json
[
  {"name": "date",           "type": "DATE",    "mode": "REQUIRED", "description": "日付（主キー1）"},
  {"name": "campaign_id",    "type": "STRING",  "mode": "REQUIRED", "description": "キャンペーンID（主キー2）"},
  {"name": "campaign_name",  "type": "STRING",  "mode": "NULLABLE", "description": "キャンペーン名"},
  {"name": "campaign_type",  "type": "STRING",  "mode": "NULLABLE", "description": "キャンペーンタイプ（SEARCH/SHOPPING/PMAX/DG）"},
  {"name": "ad_group_id",    "type": "STRING",  "mode": "NULLABLE", "description": "広告グループID"},
  {"name": "impressions",    "type": "INTEGER", "mode": "NULLABLE", "description": "インプレッション数"},
  {"name": "clicks",         "type": "INTEGER", "mode": "NULLABLE", "description": "クリック数"},
  {"name": "cost",           "type": "INTEGER", "mode": "NULLABLE", "description": "広告費（円）"},
  {"name": "conversions",    "type": "FLOAT",   "mode": "NULLABLE", "description": "CV数"},
  {"name": "revenue",        "type": "INTEGER", "mode": "NULLABLE", "description": "売上（円）"},
  {"name": "inserted_at",    "type": "TIMESTAMP","mode": "REQUIRED", "description": "BigQuery挿入日時"}
]
```

##### `raw.ec_meta_ads`（Meta広告・同上構造）

```json
[
  {"name": "date",          "type": "DATE",    "mode": "REQUIRED"},
  {"name": "campaign_id",   "type": "STRING",  "mode": "REQUIRED"},
  {"name": "campaign_name", "type": "STRING",  "mode": "NULLABLE"},
  {"name": "ad_set_id",     "type": "STRING",  "mode": "NULLABLE"},
  {"name": "impressions",   "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "clicks",        "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "cost",          "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "conversions",   "type": "FLOAT",   "mode": "NULLABLE"},
  {"name": "revenue",       "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "inserted_at",   "type": "TIMESTAMP","mode": "REQUIRED"}
]
```

##### `raw.ec_yahoo_ads` / `raw.ec_microsoft_ads`（同上構造）

Google広告と同じスキーマを適用する。

##### `raw.ec_search_console`（SEO・1日×1記事×1クエリ1行）

```json
[
  {"name": "date",         "type": "DATE",    "mode": "REQUIRED", "description": "日付"},
  {"name": "page",         "type": "STRING",  "mode": "REQUIRED", "description": "記事URL（landing_siteとの結合キー）"},
  {"name": "query",        "type": "STRING",  "mode": "REQUIRED", "description": "検索クエリ"},
  {"name": "clicks",       "type": "INTEGER", "mode": "NULLABLE", "description": "クリック数"},
  {"name": "impressions",  "type": "INTEGER", "mode": "NULLABLE", "description": "表示回数"},
  {"name": "ctr",          "type": "FLOAT",   "mode": "NULLABLE", "description": "クリック率"},
  {"name": "position",     "type": "FLOAT",   "mode": "NULLABLE", "description": "平均掲載順位"},
  {"name": "inserted_at",  "type": "TIMESTAMP","mode": "REQUIRED"}
]
```

##### `raw.ec_instagram_organic`（Instagram投稿・1投稿×1日1行）

```json
[
  {"name": "post_id",          "type": "STRING",  "mode": "REQUIRED", "description": "投稿ID（主キー1）"},
  {"name": "date",             "type": "DATE",    "mode": "REQUIRED", "description": "集計日（主キー2）"},
  {"name": "post_url",         "type": "STRING",  "mode": "NULLABLE", "description": "投稿URL"},
  {"name": "media_type",       "type": "STRING",  "mode": "NULLABLE", "description": "投稿タイプ（IMAGE/CAROUSEL/REEL）"},
  {"name": "posted_at",        "type": "TIMESTAMP","mode": "NULLABLE", "description": "投稿日時"},
  {"name": "impressions",      "type": "INTEGER", "mode": "NULLABLE", "description": "インプレッション数"},
  {"name": "reach",            "type": "INTEGER", "mode": "NULLABLE", "description": "リーチ数"},
  {"name": "likes",            "type": "INTEGER", "mode": "NULLABLE", "description": "いいね数"},
  {"name": "comments",         "type": "INTEGER", "mode": "NULLABLE", "description": "コメント数"},
  {"name": "saves",            "type": "INTEGER", "mode": "NULLABLE", "description": "保存数"},
  {"name": "engagement_rate",  "type": "FLOAT",   "mode": "NULLABLE", "description": "エンゲージメント率"},
  {"name": "inserted_at",      "type": "TIMESTAMP","mode": "REQUIRED"}
]
```

##### `raw.ec_klaviyo_campaigns`（Klaviyoキャンペーン・1キャンペーン1行）

```json
[
  {"name": "campaign_id",     "type": "STRING",  "mode": "REQUIRED", "description": "キャンペーンID（主キー）"},
  {"name": "campaign_name",   "type": "STRING",  "mode": "NULLABLE", "description": "キャンペーン名"},
  {"name": "sent_at",         "type": "TIMESTAMP","mode": "NULLABLE", "description": "配信日時"},
  {"name": "sent_day_of_week","type": "STRING",  "mode": "NULLABLE", "description": "配信曜日"},
  {"name": "sent_hour",       "type": "INTEGER", "mode": "NULLABLE", "description": "配信時刻（時）"},
  {"name": "recipients",      "type": "INTEGER", "mode": "NULLABLE", "description": "配信数"},
  {"name": "opens",           "type": "INTEGER", "mode": "NULLABLE", "description": "開封数"},
  {"name": "open_rate",       "type": "FLOAT",   "mode": "NULLABLE", "description": "開封率"},
  {"name": "clicks",          "type": "INTEGER", "mode": "NULLABLE", "description": "クリック数"},
  {"name": "click_rate",      "type": "FLOAT",   "mode": "NULLABLE", "description": "クリック率"},
  {"name": "conversions",     "type": "INTEGER", "mode": "NULLABLE", "description": "CV数"},
  {"name": "revenue",         "type": "INTEGER", "mode": "NULLABLE", "description": "売上貢献額（円）"},
  {"name": "unsubscribes",    "type": "INTEGER", "mode": "NULLABLE", "description": "配信停止数"},
  {"name": "inserted_at",     "type": "TIMESTAMP","mode": "REQUIRED"}
]
```

##### `raw.ec_klaviyo_profiles`（Klaviyo顧客・1顧客1行）

```json
[
  {"name": "profile_id",      "type": "STRING",  "mode": "REQUIRED", "description": "KlaviyoプロフィールID（主キー）"},
  {"name": "email",           "type": "STRING",  "mode": "REQUIRED", "description": "メールアドレス（Shopify結合キー）"},
  {"name": "first_name",      "type": "STRING",  "mode": "NULLABLE"},
  {"name": "last_name",       "type": "STRING",  "mode": "NULLABLE"},
  {"name": "total_revenue",   "type": "INTEGER", "mode": "NULLABLE", "description": "Klaviyo経由累計売上（円）"},
  {"name": "created_at",      "type": "TIMESTAMP","mode": "NULLABLE"},
  {"name": "inserted_at",     "type": "TIMESTAMP","mode": "REQUIRED"}
]
```

##### `raw.ec_backlog_issues`（Backlog課題・1課題1行）

```json
[
  {"name": "issue_id",      "type": "STRING",    "mode": "REQUIRED", "description": "課題ID（主キー）"},
  {"name": "project_id",    "type": "STRING",    "mode": "NULLABLE"},
  {"name": "issue_type",    "type": "STRING",    "mode": "NULLABLE"},
  {"name": "title",         "type": "STRING",    "mode": "NULLABLE"},
  {"name": "status",        "type": "STRING",    "mode": "NULLABLE", "description": "未対応/処理中/完了等"},
  {"name": "priority",      "type": "STRING",    "mode": "NULLABLE"},
  {"name": "assignee",      "type": "STRING",    "mode": "NULLABLE"},
  {"name": "due_date",      "type": "DATE",      "mode": "NULLABLE"},
  {"name": "created_at",    "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "updated_at",    "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "resolved_at",   "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "inserted_at",   "type": "TIMESTAMP", "mode": "REQUIRED"}
]
```

#### martテーブル一覧

##### `mart.ec_cost_master`（原価マスタ・月次手動入力）

```json
[
  {"name": "sku",         "type": "STRING",  "mode": "REQUIRED", "description": "SKUコード（ec_shopify_ordersとの結合キー）"},
  {"name": "cost_price",  "type": "INTEGER", "mode": "REQUIRED", "description": "原価（円）"},
  {"name": "valid_from",  "type": "DATE",    "mode": "REQUIRED", "description": "適用開始日"},
  {"name": "valid_to",    "type": "DATE",    "mode": "REQUIRED", "description": "適用終了日"}
]
```

##### `mart.ec_shipping_rules`（送料マスタ・手動定義）

```json
[
  {"name": "valid_from",              "type": "DATE",    "mode": "REQUIRED"},
  {"name": "valid_to",                "type": "DATE",    "mode": "REQUIRED"},
  {"name": "shipping_fee_per_order",  "type": "INTEGER", "mode": "REQUIRED", "description": "1注文あたり送料（円）・現在1000円"}
]
```

**初期データ:**
```sql
INSERT INTO mart.ec_shipping_rules VALUES
  (DATE('2026-01-01'), DATE('2026-12-31'), 1000);
```

##### `mart.ec_daily_pnl`（日次収支・スケジュールクエリで自動生成）

```sql
CREATE OR REPLACE TABLE mart.ec_daily_pnl AS
SELECT
  o.order_date,
  o.order_id,
  o.sku,
  o.quantity,
  o.unit_price,
  o.total_price                                         AS revenue,
  c.cost_price,
  c.cost_price * o.quantity                             AS total_cost,
  o.total_price - (c.cost_price * o.quantity)           AS gross_profit,
  s.shipping_fee_per_order,
  o.total_price - (c.cost_price * o.quantity)
    - s.shipping_fee_per_order                          AS actual_gross_profit,
  ROUND(
    (o.total_price - (c.cost_price * o.quantity)
      - s.shipping_fee_per_order)
    / o.total_price * 100, 1
  )                                                     AS actual_margin_pct,
  o.is_refunded,
  o.refund_amount
FROM `campwill-ec.raw.ec_shopify_orders` o
LEFT JOIN `campwill-ec.mart.ec_cost_master` c
  ON o.sku = c.sku
  AND o.order_date BETWEEN c.valid_from AND c.valid_to
CROSS JOIN `campwill-ec.mart.ec_shipping_rules` s
WHERE s.valid_from <= o.order_date
  AND s.valid_to   >= o.order_date;
```

##### `mart.ec_channel_attribution`（チャネル判定ロジック）

```sql
-- チャネル判定ルール（UTM有無の両方に対応）
CASE
  WHEN utm_source = 'klaviyo'
    THEN 'email_klaviyo'
  WHEN utm_medium IN ('cpc', 'paid', 'paidsearch', 'ppc')
    AND utm_source = 'google'
    THEN 'google_paid'
  WHEN utm_medium IN ('cpc', 'paid')
    AND utm_source IN ('facebook', 'instagram')
    THEN 'meta_paid'
  WHEN utm_medium IN ('cpc', 'paid')
    AND utm_source = 'yahoo'
    THEN 'yahoo_paid'
  WHEN utm_medium IN ('cpc', 'paid')
    AND utm_source IN ('bing', 'microsoft')
    THEN 'microsoft_paid'
  -- オーガニック（UTMなし・referring_siteで判定）
  WHEN referring_site LIKE '%instagram.com%'
    AND utm_medium IS NULL
    THEN 'instagram_organic'
  WHEN referring_site LIKE '%google.com%'
    AND utm_medium IS NULL
    THEN 'seo_google'
  WHEN referring_site LIKE '%yahoo.co.jp%'
    AND utm_medium IS NULL
    THEN 'seo_yahoo'
  WHEN referring_site IS NULL AND utm_source IS NULL
    THEN 'direct'
  ELSE 'other'
END AS channel
```

##### `mart.ec_channel_roi`（チャネル別ROI）

```sql
CREATE OR REPLACE TABLE mart.ec_channel_roi AS
SELECT
  order_date,
  CASE
    WHEN utm_source = 'klaviyo' THEN 'email_klaviyo'
    WHEN utm_medium IN ('cpc','paid') AND utm_source = 'google' THEN 'google_paid'
    WHEN utm_medium IN ('cpc','paid') AND utm_source IN ('facebook','instagram') THEN 'meta_paid'
    WHEN utm_medium IN ('cpc','paid') AND utm_source = 'yahoo' THEN 'yahoo_paid'
    WHEN utm_medium IN ('cpc','paid') AND utm_source IN ('bing','microsoft') THEN 'microsoft_paid'
    WHEN referring_site LIKE '%instagram.com%' AND utm_medium IS NULL THEN 'instagram_organic'
    WHEN referring_site LIKE '%google.com%' AND utm_medium IS NULL THEN 'seo_google'
    WHEN referring_site IS NULL AND utm_source IS NULL THEN 'direct'
    ELSE 'other'
  END                                                     AS channel,
  COUNT(DISTINCT order_id)                                AS orders,
  COUNT(DISTINCT customer_email)                          AS unique_customers,
  SUM(total_price)                                        AS revenue,
  COUNTIF(is_refunded)                                    AS refund_count,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 1)         AS refund_rate_pct,
  SUM(total_price) / COUNT(DISTINCT customer_email)       AS ltv
FROM `campwill-ec.raw.ec_shopify_orders`
GROUP BY order_date, channel;
```

##### `mart.ec_klaviyo_conversion`（メール→購買転換）

```sql
CREATE OR REPLACE TABLE mart.ec_klaviyo_conversion AS
SELECT
  k.campaign_id,
  k.campaign_name,
  k.sent_at,
  k.recipients,
  k.open_rate,
  k.click_rate,
  k.revenue                                             AS klaviyo_revenue,
  COUNT(DISTINCT o.order_id)                            AS shopify_orders,
  SUM(o.total_price)                                    AS shopify_revenue,
  ROUND(COUNT(DISTINCT o.order_id) / k.recipients * 100, 2) AS purchase_rate_pct
FROM `campwill-ec.raw.ec_klaviyo_campaigns` k
LEFT JOIN `campwill-ec.raw.ec_shopify_orders` o
  ON o.customer_email IN (
    SELECT email FROM `campwill-ec.raw.ec_klaviyo_profiles`
  )
  AND o.order_date BETWEEN DATE(k.sent_at)
    AND DATE_ADD(DATE(k.sent_at), INTERVAL 7 DAY)
GROUP BY
  k.campaign_id, k.campaign_name, k.sent_at,
  k.recipients, k.open_rate, k.click_rate, k.revenue;
```

##### `mart.ec_weekly_summary`（週次サマリー・Claude API用）

```sql
CREATE OR REPLACE TABLE mart.ec_weekly_summary AS
SELECT
  DATE_TRUNC(order_date, WEEK(MONDAY))                  AS week_start,
  SUM(total_price)                                      AS weekly_revenue,
  COUNT(DISTINCT order_id)                              AS weekly_orders,
  COUNT(DISTINCT customer_email)                        AS weekly_customers,
  ROUND(AVG(total_price), 0)                            AS avg_order_value,
  COUNTIF(is_refunded)                                  AS refund_count,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 1)       AS refund_rate_pct
FROM `campwill-ec.raw.ec_shopify_orders`
GROUP BY week_start
ORDER BY week_start DESC;
```

### 3.2 campwill-realestate（不動産事業）

#### データセット構成

| データセット | テーブル名 | 内容 |
|---|---|---|
| `raw` | `re_inquiries` | 問い合わせデータ |
| `raw` | `re_ads` | 広告媒体データ |
| `raw` | `re_backlog_issues` | Backlog課題 |
| `mart` | `re_lead_analysis` | リード分析 |
| `mart` | `re_ad_performance` | 広告パフォーマンス |
| `mart` | `re_weekly_summary` | 週次サマリー |
| `ga4_export` | `events_*` | GA4自動エクスポート |

> 不動産事業のスキーマ詳細は事業データの整備状況に合わせて追加する。

**【2026-05 更新】** Phase 1 実装完了:
- raw 5 テーブル (`re_tenants` / `re_deals` / `re_activities` / `re_properties` / `re_owners`) + `re_search_console` VIEW
- mart 5 テーブル (`re_lead_funnel` / `re_case_pipeline` / `re_seo_inquiry_attribution` / `re_property_performance` / `re_weekly_summary`)
- 案件管理ソース: 自社開発 [tenant-leasing](https://tenant-leasing.onrender.com) (React Router v7 + Prisma + PostgreSQL on Render) の `/api/export/*` を Bearer token で日次 fetch
- 詳細: [bigquery/campwill-realestate/README.md](../bigquery/campwill-realestate/README.md)

### 3.3 campwill-central（全社横断）

| データセット | テーブル名 | 内容 |
|---|---|---|
| `mart_all` | `all_revenue_summary` | 全事業売上サマリー |
| `mart_all` | `all_ad_comparison` | 事業間広告費比較 |
| `mart_all` | `all_channel_roi` | 全チャネルROI比較 |
| `mart_all` | `all_cost_summary` | 全社コストサマリー |
| `mart_all` | `company_kpi` | 全社KPIダッシュボード用 |

---

## 4. データ接続構成（n8n → BigQuery）

| データソース | n8n実装方法 | 認証 | 実行時刻 | 取得データ |
|---|---|---|---|---|
| Google広告 | Google Ads node | OAuth2 | 毎日AM3:00 | キャンペーン別日次実績 |
| Meta広告 | Facebook Graph API node | OAuth2 | 毎日AM3:10 | キャンペーン別日次実績 |
| Yahoo!広告 | HTTP Request | APIキー | 毎日AM3:20 | キャンペーン別日次実績 |
| Microsoft広告 | Microsoft Ads node | OAuth2 | 毎日AM3:30 | キャンペーン別日次実績 |
| Googleサーチコンソール | Google Search Console node | OAuth2 | 毎日AM3:30 | ページ×クエリ別日次実績 |
| Instagramオーガニック | Meta Graph API（HTTP） | OAuth2 | 毎日AM3:40 | 投稿別エンゲージメント |
| Klaviyo | HTTP Request（Klaviyo API v2024） | APIキー | 毎日AM4:00 | キャンペーン実績・顧客データ |
| Shopify | Shopify node | APIキー | 毎日AM4:30 | 注文・返金・顧客・SKU |
| GA4 | BigQueryエクスポート（Google標準） | 自動 | 日次自動 | 全イベントデータ |
| Backlog | HTTP Request（Backlog API） | APIキー | 毎日AM5:00 | 課題・ドキュメント |
| Slack | Slack node（通知送信） | Bot Token | 随時 | レポート・アラート送信 |

### n8nパイプライン実行順序

```
AM3:00  有料広告パイプライン（Google/Meta/Yahoo!/Microsoft）
AM3:30  オーガニックパイプライン（Search Console/Instagram）
AM4:00  Klaviyoパイプライン
AM4:30  Shopifyパイプライン（注文・返金・顧客）
AM5:00  Backlogパイプライン
AM6:00  martテーブル生成（スケジュールクエリ・BigQuery側で実行）
AM8:00  AIレポートパイプライン（週次・月曜のみ）
AM9:00  異常値アラートパイプライン（日次）
```

---

## 5. 重要な設計ルール

### 5.1 結合キー

| 結合 | キー | 注意 |
|---|---|---|
| Shopify注文 × Klaviyo顧客 | `customer_email` = `email` | NOT NULL必須 |
| Shopify注文 × 原価マスタ | `sku` | 完全一致必須 |
| Shopify注文 × 送料マスタ | `order_date` BETWEEN `valid_from` AND `valid_to` | 期間管理 |
| 広告データ × Shopify注文 | `utm_campaign` | 有料広告のみ |
| SEO × Shopify注文 | `landing_site` LIKE `page` | URLの正規化注意 |

### 5.2 UTMパラメータの扱い

- 有料広告：全媒体でUTMパラメータ設定済み → `utm_source` / `utm_medium` / `utm_campaign` をパースして保存
- オーガニック：UTMなし → `referring_site` で判定
- n8nでShopifyデータ取得時に `landing_site` URLをパースしてUTMカラムに分割して保存すること

### 5.3 rawデータの保持ルール

- rawは加工・集計せずそのまま保存する
- rawのデータは削除しない（上書き・追記のみ）
- martはrawから何度でも再生成できる状態を維持する

### 5.4 初回データ取得

- Shopifyは創業時からの全注文を初回一括取得する（全件フル取得 → 以降は日次差分）
- 広告媒体は取得可能な最大期間（Google/Metaは最大36ヶ月）を初回取得する
- GA4は設定翌日から自動取得開始（過去データは遡及不可）

---

## 6. AIエージェント構成

### 6.1 技術スタック

| 役割 | ツール |
|---|---|
| スケジュール実行トリガー | n8n Pro |
| AI分析・示唆生成 | Claude API（claude-sonnet-4-6）|
| インタラクティブな構築・分析 | Claude Code（CLI）|
| データアクセス | BigQuery API（Google Cloud SDK）|

### 6.2 エージェント一覧

| エージェント名 | 参照テーブル | 出力 | 頻度 |
|---|---|---|---|
| 広告分析 | `ec_ad_performance` | 媒体別ROAS・予算配分推奨 | 週次 |
| コンテンツ分析 | `ec_content_attribution` | SEO/Instagram→売上貢献 | 週次 |
| Klaviyo分析 | `ec_klaviyo_conversion` | メール開封→購買転換率 | 週次 |
| チャネルROI | `ec_channel_roi` / `ec_channel_ltv` | チャネル別ROI・LTV・返金率 | 週次 |
| 全社レポート | `company_kpi` | EC＋不動産KPI・Slack投稿 | 週次月曜AM8時 |
| コンテンツ生成 | 過去投稿・商品データ | SNS文章・メール・LP草稿 | 随時 |
| 返金分析 | `ec_refund_analysis` | 媒体・SKU別返金率・実質ROAS | 週次 |
| Backlogタスク生成 | 全分析結果 | 推奨アクションのタスク自動登録 | 週次 |

### 6.3 週次Slackレポートのプロンプトテンプレート

```
以下のBigQueryデータを分析して、今週の事業サマリーと推奨アクションを日本語で出力してください。

【広告パフォーマンス】
{ec_ad_performance の直近7日間データ}

【チャネル別ROI】
{ec_channel_roi の直近7日間データ}

【Klaviyo】
{ec_klaviyo_conversion の直近キャンペーンデータ}

【売上・返金】
{ec_weekly_summary の直近2週間データ}

出力形式：
1. 今週のハイライト（3点）
2. 媒体別広告パフォーマンス分析と予算配分推奨
3. チャネル別ROI比較
4. Klaviyo開封→購買分析
5. 推奨アクション（優先度順・担当者・期限付き）
```

---

## 7. 月額コスト

| サービス | 用途 | 月額 |
|---|---|---|
| Google BigQuery（3プロジェクト） | DWH | 無料枠内（〜10GB） |
| GA4 BigQueryエクスポート | GA4自動連携 | 無料 |
| Looker Studio | ダッシュボード | 無料 |
| n8n Pro | ETL・自動化 | 約8,000円 |
| Claude API | AI分析・生成 | 約3,000〜5,000円 |
| **合計** | | **約11,000〜13,000円/月** |

---

## 8. 実装ロードマップ

### Phase 1：データ基盤構築（Q1）

```
[ ] Google Cloudプロジェクト3つ作成（campwill-ec / campwill-realestate / campwill-central）
[ ] BigQuery有効化・データセット作成（raw / mart / ga4_export）※リージョン：asia-northeast1
[ ] IAM・サービスアカウント設定（n8n-pipeline / looker-studio-reader）
[ ] GA4 BigQueryエクスポート設定（EC・不動産 両方）
[ ] n8n ProへのUpgrade
[ ] rawテーブルスキーマ作成（本ドキュメントのJSONを使用）
[ ] 原価マスタ・送料マスタの初期データ投入
[ ] Shopify初回全件取得→rawに格納
[ ] 広告媒体（Google/Meta/Yahoo!/Microsoft）初回取得→rawに格納
[ ] KlaviyoのAPIキー発行・初回取得
[ ] Search Console・Instagram初回取得
```

### Phase 2：AI自動化（Q2）

```
[ ] martテーブルSQL作成・動作確認（ec_daily_pnl / ec_channel_roi / ec_klaviyo_conversion）
[ ] BigQueryスケジュールクエリ設定（毎日AM6:00）
[ ] Looker Studioダッシュボード作成
[ ] Slack週次レポートパイプライン構築（n8n + Claude API）
[ ] Backlog自動タスク生成パイプライン構築
[ ] 異常値アラートパイプライン構築
```

### Phase 3：意思決定自動化（Q3-Q4）

```
[ ] チャネルROI・LTV分析の深化
[ ] 広告予算最適化提案エージェントの精度向上
[ ] 在庫・トレンド異常検知の実装
[ ] 全社横断KPI（campwill-central）の整備
[ ] 不動産事業データの本格連携
[ ] 3人目採用に向けた業務量データの整備
```

---

## 9. Claude Codeでの実装手順

### インストール

```bash
npm install -g @anthropic-ai/claude-code
claude
```

### 推奨する実装順序

1. Google Cloud SDKのインストール・認証設定
2. BigQueryプロジェクト・データセット・テーブルの作成
3. サービスアカウント・JSONキーの発行
4. n8nとBigQueryの接続設定
5. Shopify初回全件取得ワークフローの構築
6. 広告媒体ワークフローの構築
7. martテーブルSQLの作成・スケジュール設定
8. Slack通知パイプラインの構築

### Claude Codeへの指示例

```bash
# BigQueryテーブル作成
> このドキュメントのスキーマを使って
  campwill-ecプロジェクトのrawデータセットに
  ec_shopify_ordersテーブルを作成して

# n8nワークフロー生成
> ShopifyからBigQueryのraw.ec_shopify_ordersに
  注文データを転送するn8nワークフローJSONを生成して
  UTMパラメータはlanding_siteからパースすること

# データ検証
> raw.ec_shopify_ordersでcustomer_emailが
  NULLの注文が何件あるか確認して

# mart生成
> ec_daily_pnlのSQLをBigQueryで実行して
  直近7日間の実質粗利益率を確認して
```

---

## 10. 参照情報・APIキー管理

### 取得が必要なAPIキー一覧

| サービス | 取得場所 | 用途 |
|---|---|---|
| Google Cloud サービスアカウントJSON | GCP Console → IAM → サービスアカウント | n8n→BigQuery接続 |
| Shopify APIキー | Shopify管理画面 → アプリ → APIキー | 注文・顧客データ取得 |
| Meta Business APIキー | Meta Business Suite → 設定 → APIアクセス | 広告・Instagram取得 |
| Klaviyo Private APIキー | Klaviyo → Account → Settings → API Keys | キャンペーン・顧客取得 |
| Google Search Console OAuth | Google Cloud → APIとサービス → 認証情報 | SEOデータ取得 |
| Yahoo! Ads APIキー | Yahoo!広告管理画面 → アカウント設定 | Yahoo!広告取得 |
| Microsoft Ads OAuth | Microsoft Advertising → ツール → API | Microsoft広告取得 |
| Backlog APIキー | Backlog → 個人設定 → API | 課題データ取得 |
| Slack Bot Token | Slack API → アプリ → Bot Token | レポート通知 |
| Claude API Key | console.anthropic.com | AI分析・生成 |

> **セキュリティ:** APIキーはn8nのCredentials機能で管理し、コードや設定ファイルに直接記載しないこと。

---

*このドキュメントはCAMPWILL AI-Readyプロジェクトの設計仕様書です。実装の進捗に合わせて随時更新してください。*
*最終更新：2026年4月*
