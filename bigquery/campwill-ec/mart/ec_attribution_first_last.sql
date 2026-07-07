-- mart.ec_attribution_first_last: 顧客 1 行の初回流入 vs 最終流入 (v2.0 準拠)
-- クロスチャネル journey の俯瞰用 (loyal_same_channel / cross_channel / one_time)
--
-- v2.0 (2026-07-07 refactor):
--   - 独自 CASE 分類を廃止し、mart.ec_order_enriched.channel_classified を採用
--     (ec_channel_roi / ec_channel_attribution_weekly と完全整合、v2.0 統一)
--   - Klaviyo 5 日 click carve (klaviyo_clicked_within_5d) も反映
--   - PII は ec_order_enriched の customer_email_hash をそのまま使用
--
-- 注: ec_order_enriched が先に再生成される前提 (順序: 22:30 enriched → 23:45 attribution_first_last)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_attribution_first_last` AS
WITH orders_with_channel AS (
  SELECT
    customer_email_hash,
    order_id,
    order_date,
    utm_campaign,
    CASE
      WHEN klaviyo_clicked_within_5d THEN 'email_klaviyo'
      ELSE channel_classified
    END AS channel
  FROM `campwill-ec.mart.ec_order_enriched`
  WHERE customer_email_hash IS NOT NULL
),
agg AS (
  SELECT
    customer_email_hash,
    MIN(order_date)                                                              AS first_order_date,
    MAX(order_date)                                                              AS last_order_date,
    COUNT(DISTINCT order_id)                                                     AS total_orders,
    ARRAY_AGG(channel ORDER BY order_date ASC LIMIT 1)[OFFSET(0)]                AS first_channel,
    ARRAY_AGG(channel ORDER BY order_date DESC LIMIT 1)[OFFSET(0)]               AS last_channel,
    ARRAY_AGG(utm_campaign IGNORE NULLS ORDER BY order_date ASC LIMIT 1)[SAFE_OFFSET(0)]  AS first_utm_campaign,
    ARRAY_AGG(utm_campaign IGNORE NULLS ORDER BY order_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS last_utm_campaign
  FROM orders_with_channel
  GROUP BY customer_email_hash
)
SELECT
  customer_email_hash,
  first_order_date,
  first_channel,
  first_utm_campaign,
  last_order_date,
  last_channel,
  last_utm_campaign,
  total_orders,
  first_channel = last_channel AS is_same_channel,
  CASE
    WHEN total_orders = 1                          THEN 'one_time'
    WHEN first_channel = last_channel              THEN 'loyal_same_channel'
    ELSE                                                'cross_channel'
  END AS journey_type,
  CURRENT_TIMESTAMP() AS generated_at
FROM agg;
