-- mart.ec_channel_roi: チャネル別 日次 売上 / 広告cost / ROAS / CPA / LTV / 返品率
--
-- v2.0 準拠 (2026-07-07):
--   - 元 raw の utm 判定を廃止し、mart.ec_order_enriched の channel_classified を採用
--   - 注文前 5 日以内 Klaviyo click があれば email_klaviyo に per-order override
--     (ec_channel_attribution_weekly の Klaviyo carve と完全整合)
--   - seo_bing / unknown / meta_paid の判定漏れを解消 (ec_order_enriched の CASE 参照)
--   - 各広告 raw (Google/Meta/Yahoo/MS) は unchanged で ad_cost を JOIN

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_channel_roi` AS
WITH
-- Yahoo / Microsoft ads は n8n が「昨日+今日」の 2 日 lookback で毎日 INSERT するため
-- 同じ (date, campaign_id) が重複堆積 → 最新 inserted_at で dedup
yahoo_dedup AS (
  SELECT date, campaign_id, cost
  FROM `campwill-ec.raw.ec_yahoo_ads`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY date, campaign_id ORDER BY inserted_at DESC) = 1
),
microsoft_dedup AS (
  SELECT date, campaign_id, cost
  FROM `campwill-ec.raw.ec_microsoft_ads`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY date, campaign_id ORDER BY inserted_at DESC) = 1
),
ad_costs AS (
  SELECT date, 'google_paid'    AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_google_ads`    GROUP BY date
  UNION ALL
  SELECT date, 'meta_paid'      AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_meta_ads`      GROUP BY date
  UNION ALL
  SELECT date, 'yahoo_paid'     AS channel, SUM(cost) AS ad_cost FROM yahoo_dedup                       GROUP BY date
  UNION ALL
  SELECT date, 'microsoft_paid' AS channel, SUM(cost) AS ad_cost FROM microsoft_dedup                   GROUP BY date
),
-- ec_order_enriched を source に (v2.0 channel_classified + Klaviyo carve と統一)
shopify_by_channel AS (
  SELECT
    order_date,
    CASE
      WHEN klaviyo_clicked_within_5d THEN 'email_klaviyo'
      ELSE channel_classified
    END                                                                       AS channel,
    COUNT(DISTINCT order_id)                                                  AS orders,
    COUNT(DISTINCT customer_email_hash)                                       AS unique_customers,
    SUM(total_price)                                                          AS revenue,
    COUNTIF(is_refunded)                                                      AS refund_count,
    ROUND(SAFE_DIVIDE(COUNTIF(is_refunded), COUNT(DISTINCT order_id)) * 100, 1) AS refund_rate_pct,
    SAFE_DIVIDE(SUM(total_price), COUNT(DISTINCT customer_email_hash))        AS ltv
  FROM `campwill-ec.mart.ec_order_enriched`
  GROUP BY order_date, channel
)
SELECT
  COALESCE(s.order_date, c.date)                                     AS date,
  COALESCE(s.channel, c.channel)                                     AS channel,
  s.orders,
  s.unique_customers,
  s.revenue,
  c.ad_cost,
  -- ROAS = revenue / ad_cost (倍率, 例 2.5 = 1円投資で2.5円売上)
  ROUND(SAFE_DIVIDE(s.revenue, c.ad_cost), 2)                        AS roas,
  -- CPA = ad_cost / orders (1注文あたり広告費)
  ROUND(SAFE_DIVIDE(c.ad_cost, s.orders), 0)                         AS cpa,
  s.refund_count,
  s.refund_rate_pct,
  s.ltv
FROM shopify_by_channel s
FULL OUTER JOIN ad_costs c
  ON s.order_date = c.date
  AND s.channel = c.channel;
