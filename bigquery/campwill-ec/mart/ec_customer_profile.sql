-- mart.ec_customer_profile: 顧客 1 行のプロファイル
-- 初回・最終購入、累計、休眠フラグ、初回/最終チャネル、推定コホート、ギフト購買回数

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_customer_profile` AS
WITH orders_with_channel AS (
  SELECT
    customer_email,
    customer_id,
    order_id,
    order_date,
    total_price,
    sku,
    tags,
    CASE
      WHEN COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)')) = 'klaviyo' THEN 'email_klaviyo'
      WHEN COALESCE(utm_medium, REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)')) IN ('cpc','paid','paidsearch','ppc','dg','pmx')
        AND COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)')) = 'google' THEN 'google_paid'
      WHEN COALESCE(utm_medium, REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)')) IN ('cpc','paid','social','organic_social')
        AND COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)')) IN ('facebook','fb','instagram','ig','meta','ig.me') THEN 'meta_paid'
      WHEN COALESCE(utm_medium, REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)')) IN ('cpc','paid','dsa')
        AND COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)')) = 'yahoo' THEN 'yahoo_paid'
      WHEN COALESCE(utm_medium, REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)')) IN ('cpc','paid')
        AND COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)')) IN ('bing','microsoft') THEN 'microsoft_paid'
      WHEN referring_site LIKE '%instagram.com%' AND utm_medium IS NULL THEN 'instagram_organic'
      WHEN referring_site LIKE '%google.com%'    AND utm_medium IS NULL THEN 'seo_google'
      WHEN referring_site LIKE '%yahoo.co.jp%'   AND utm_medium IS NULL THEN 'seo_yahoo'
      WHEN referring_site LIKE '%bing.com%'      AND utm_medium IS NULL THEN 'seo_bing'
      WHEN referring_site LIKE '%youtube.com%'   AND utm_medium IS NULL THEN 'social_youtube'
      WHEN referring_site IS NULL AND utm_source IS NULL THEN 'direct'
      ELSE 'other'
    END AS channel
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
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
)
SELECT
  o.customer_email,
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
FROM orders_with_channel o
LEFT JOIN first_last_channel flc USING (customer_email)
LEFT JOIN sku_rank sr ON sr.customer_email = o.customer_email AND sr.rn = 1
GROUP BY o.customer_email, flc.first_channel, flc.last_channel;
