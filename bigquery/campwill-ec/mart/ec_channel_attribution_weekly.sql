-- mart.ec_channel_attribution_weekly: 組織標準の単一チャネル別売上貢献 + 費用対効果マート
--
-- 詳細仕様: docs/attribution-model.md (v2.0 / 2026-05-19 制定)
--
-- 設計サマリ (v2.0):
--   1. 各注文の channel は Shopify last-touch (channel_classified) を基底
--   2. **per-order override**: 注文前 5日以内に同 email が Klaviyo メールを click していたら
--      その注文を email_klaviyo に再分類 (`ec_order_enriched.klaviyo_clicked_within_5d`)
--   3. 集約後の direct/other/unknown carve は廃止 (per-order が正)
--   4. 各 paid チャネルは raw 広告から ad_cost を JOIN
--   5. ROAS = revenue / ad_cost, CPA = ad_cost / orders
--   6. 結果: 週次合計は Shopify 注文金額と一致 (差 0)
--
-- 注意:
--   - Klaviyo Events 取り込み開始 (2026-05-19 / 90日 backfill) 以降のみ正確
--   - 取り込み前の期間は email_klaviyo = 0 表示 (raw.ec_klaviyo_events_latest が空のため)
--   - share_pct は週内合計が 100%
--   - email_klaviyo の ad_cost / cpa = NULL (subscription cost 未計上)
--   - organic/direct/unknown も ad_cost = NULL (集客 cost ゼロと仮定)
--   - net_revenue_after_ad_cost = revenue - IFNULL(ad_cost, 0) — paid の真の貢献額

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_channel_attribution_weekly`
PARTITION BY week_start
CLUSTER BY channel
AS
WITH shopify_weekly AS (
  SELECT
    DATE_TRUNC(order_date, WEEK(MONDAY)) AS week_start,
    CASE
      WHEN klaviyo_clicked_within_5d THEN 'email_klaviyo'
      ELSE channel_classified
    END                                  AS channel,
    COUNT(DISTINCT order_id)             AS orders,
    SUM(total_price)                     AS revenue
  FROM `campwill-ec.mart.ec_order_enriched`
  GROUP BY 1, 2
),
-- Yahoo / Microsoft ads は n8n が「昨日+今日」の 2 日 lookback で毎日 INSERT するため
-- 同じ (date, campaign_id) が重複堆積 (Yahoo +20.5%, MS +11.4% 過大集計) → 最新 inserted_at で dedup
yahoo_dedup AS (
  SELECT date, cost FROM `campwill-ec.raw.ec_yahoo_ads`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY date, campaign_id ORDER BY inserted_at DESC) = 1
),
microsoft_dedup AS (
  SELECT date, cost FROM `campwill-ec.raw.ec_microsoft_ads`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY date, campaign_id ORDER BY inserted_at DESC) = 1
),
ad_costs_weekly AS (
  SELECT week_start, channel, ROUND(SUM(cost)) AS ad_cost
  FROM (
    SELECT DATE_TRUNC(date, WEEK(MONDAY)) AS week_start, 'google_paid'    AS channel, cost FROM `campwill-ec.raw.ec_google_ads`
    UNION ALL
    SELECT DATE_TRUNC(date, WEEK(MONDAY)),                  'meta_paid',      cost FROM `campwill-ec.raw.ec_meta_ads`
    UNION ALL
    SELECT DATE_TRUNC(date, WEEK(MONDAY)),                  'yahoo_paid',     cost FROM yahoo_dedup
    UNION ALL
    SELECT DATE_TRUNC(date, WEEK(MONDAY)),                  'microsoft_paid', cost FROM microsoft_dedup
    UNION ALL
    SELECT DATE_TRUNC(date, WEEK(MONDAY)),                  'tiktok_paid',    cost FROM `campwill-ec.raw.ec_tiktok_ads_latest`
  )
  GROUP BY week_start, channel
)
SELECT
  s.week_start,
  s.channel,
  s.orders,
  CAST(s.revenue AS INT64)                                   AS revenue,
  ROUND(s.revenue / SUM(s.revenue) OVER (PARTITION BY s.week_start) * 100, 2) AS share_pct,
  CAST(c.ad_cost AS INT64)                                   AS ad_cost,
  ROUND(SAFE_DIVIDE(s.revenue, c.ad_cost), 2)                AS roas,
  CAST(ROUND(SAFE_DIVIDE(c.ad_cost, s.orders)) AS INT64)     AS cpa,
  CAST(s.revenue - IFNULL(c.ad_cost, 0) AS INT64)            AS net_revenue_after_ad_cost,
  CURRENT_TIMESTAMP()                                        AS generated_at
FROM shopify_weekly s
LEFT JOIN ad_costs_weekly c USING (week_start, channel);
