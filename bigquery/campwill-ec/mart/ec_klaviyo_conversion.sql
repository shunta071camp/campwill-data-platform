-- mart.ec_klaviyo_conversion: Klaviyo メール送信 → Shopify 購買への転換 (v2 last-click 5d attribution)
--
-- v2 (2026-07-07 全面刷新):
--   - 旧版は「Klaviyo profile に登録されている email の 7 日以内 order を全部合算」する
--     単純 join だったため、Shopify 貢献が実 Klaviyo 報告値の 45-360 倍に膨張していた
--   - 正しい定義: Clicked Email event の 5 日以内 order を、last-click campaign に帰属
--   - 同 order が複数 campaign にまたがる click を持つ場合、直近 click の campaign のみ計上
--
-- データソース:
--   - raw.ec_klaviyo_campaigns_latest (dedup view) — campaign_id, campaign_name, sent_at, recipients, open_rate, click_rate, revenue
--   - raw.ec_klaviyo_events — Clicked Email event (email × campaign_id × event_ts)
--   - raw.ec_shopify_orders (order-grain dedup 必須、KUBELL-1101)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_klaviyo_conversion` AS
WITH
-- Shopify order は line-grain のため order 単位 dedup
orders_dedup AS (
  SELECT
    order_id,
    ANY_VALUE(LOWER(customer_email)) AS customer_email,
    ANY_VALUE(order_date)            AS order_date,
    ANY_VALUE(created_at)            AS created_at,
    ANY_VALUE(total_price)           AS total_price
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
  GROUP BY order_id
),
-- Klaviyo Clicked Email event (email lowercase 統一で JOIN 一致)
clicks AS (
  SELECT
    LOWER(email) AS email,
    campaign_id,
    event_ts
  FROM `campwill-ec.raw.ec_klaviyo_events`
  WHERE metric_name = 'Clicked Email'
    AND email IS NOT NULL AND campaign_id IS NOT NULL
),
-- 各 order について、created_at 前 5 日以内の click から last-click を選択
order_attribution AS (
  SELECT
    o.order_id,
    o.order_date,
    o.total_price,
    c.campaign_id AS attributed_campaign_id
  FROM orders_dedup o
  JOIN clicks c
    ON c.email = o.customer_email
    AND c.event_ts BETWEEN TIMESTAMP_SUB(o.created_at, INTERVAL 5 DAY) AND o.created_at
  QUALIFY ROW_NUMBER() OVER (PARTITION BY o.order_id ORDER BY c.event_ts DESC) = 1
),
campaign_shopify AS (
  SELECT
    attributed_campaign_id AS campaign_id,
    COUNT(DISTINCT order_id) AS shopify_orders,
    SUM(total_price)         AS shopify_revenue
  FROM order_attribution
  GROUP BY attributed_campaign_id
)
SELECT
  k.campaign_id,
  k.campaign_name,
  k.sent_at,
  k.recipients,
  k.open_rate,
  k.click_rate,
  k.revenue                                                                    AS klaviyo_revenue,
  IFNULL(cs.shopify_orders, 0)                                                 AS shopify_orders,
  IFNULL(cs.shopify_revenue, 0)                                                AS shopify_revenue,
  ROUND(SAFE_DIVIDE(IFNULL(cs.shopify_orders, 0), k.recipients) * 100, 2)      AS purchase_rate_pct
FROM `campwill-ec.raw.ec_klaviyo_campaigns_latest` k
LEFT JOIN campaign_shopify cs USING (campaign_id)
WHERE k.sent_at IS NOT NULL AND k.sent_at <= CURRENT_TIMESTAMP();
