-- mart.ec_customer_profile: 顧客 1 行のプロファイル
-- 初回・最終購入、累計、休眠フラグ、初回/最終チャネル、推定コホート、ギフト購買回数
--
-- 注意: raw.ec_shopify_orders は line_item grain (1 order = N rows)
--   - SUM/AVG on total_price や COUNTIF on tags は order 単位 dedup 必須
--   - SKU 関連 (sku_rank) は line grain 保持
--   - 対策: orders_with_channel は line-grain のまま、orders_dedup を新設して集計は dedup 経由
--
-- channel は独自 CASE を持たず ec_order_enriched.channel_classified + Klaviyo 5d carve を参照
-- (v2.1 統一。順序: 22:30 enriched → 23:20 customer_profile)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_customer_profile` AS
WITH order_channel AS (
  SELECT
    order_id,
    CASE WHEN klaviyo_clicked_within_5d THEN 'email_klaviyo' ELSE channel_classified END AS channel
  FROM `campwill-ec.mart.ec_order_enriched`
),
orders_with_channel AS (
  SELECT
    s.customer_email,
    s.customer_id,
    s.order_id,
    s.order_date,
    s.total_price,
    s.sku,
    s.tags,
    oc.channel
  FROM `campwill-ec.raw.ec_shopify_orders` s
  LEFT JOIN order_channel oc USING (order_id)
  WHERE s.customer_email IS NOT NULL
),
sku_rank AS (
  SELECT
    customer_email,
    sku,
    COUNT(*) AS sku_count,
    ROW_NUMBER() OVER (PARTITION BY customer_email ORDER BY COUNT(*) DESC) AS rn
  FROM orders_with_channel
  WHERE sku IS NOT NULL
  GROUP BY customer_email, sku
),
first_last_channel AS (
  SELECT
    customer_email,
    ARRAY_AGG(channel ORDER BY order_date ASC LIMIT 1)[OFFSET(0)] AS first_channel,
    ARRAY_AGG(channel ORDER BY order_date DESC LIMIT 1)[OFFSET(0)] AS last_channel
  FROM orders_with_channel
  GROUP BY customer_email
),
-- order 単位 (1 order = 1 row) の dedup CTE。revenue/avg/tags 集計はここから。
orders_dedup AS (
  SELECT
    customer_email,
    order_id,
    ANY_VALUE(customer_id)  AS customer_id,
    ANY_VALUE(order_date)   AS order_date,
    ANY_VALUE(total_price)  AS total_price,
    ANY_VALUE(tags)         AS tags
  FROM orders_with_channel
  GROUP BY customer_email, order_id
)
SELECT
  TO_HEX(SHA256(LOWER(o.customer_email))) AS customer_email_hash,
  ANY_VALUE(o.customer_id)                                               AS customer_id,
  MIN(o.order_date)                                                       AS first_order_date,
  MAX(o.order_date)                                                       AS last_order_date,
  COUNT(DISTINCT o.order_id)                                              AS total_orders,
  ROUND(SUM(o.total_price))                                               AS total_revenue,
  ROUND(AVG(o.total_price))                                               AS avg_order_value,
  DATE_DIFF(CURRENT_DATE('Asia/Tokyo'), MAX(o.order_date), DAY)           AS days_since_last_order,
  DATE_TRUNC(MIN(o.order_date), MONTH)                                    AS cohort_month,
  DATE_DIFF(CURRENT_DATE('Asia/Tokyo'), MAX(o.order_date), DAY) >= 180    AS is_dormant,
  COUNT(DISTINCT o.order_id) >= 2                                         AS is_repeater,
  flc.first_channel,
  flc.last_channel,
  ANY_VALUE(IF(sr.rn = 1, sr.sku, NULL))                                  AS favorite_sku,
  COUNTIF(o.tags LIKE '%ギフト設定%')                                     AS gift_purchase_count,
  CURRENT_TIMESTAMP()                                                     AS generated_at
FROM orders_dedup o
LEFT JOIN first_last_channel flc USING (customer_email)
LEFT JOIN sku_rank sr ON sr.customer_email = o.customer_email AND sr.rn = 1
GROUP BY o.customer_email, flc.first_channel, flc.last_channel;
