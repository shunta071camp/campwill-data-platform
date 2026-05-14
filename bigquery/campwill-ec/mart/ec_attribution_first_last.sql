-- mart.ec_attribution_first_last: 顧客 1 行の初回流入 vs 最終流入
-- クロスチャネル journey の俯瞰用 (loyal_same_channel / cross_channel / one_time)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_attribution_first_last` AS
WITH orders_with_channel AS (
  SELECT
    customer_email,
    order_id,
    order_date,
    COALESCE(utm_campaign, REGEXP_EXTRACT(landing_site, r'[?&]utm_campaign=([^&]+)')) AS utm_campaign_resolved,
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
      WHEN referring_site IS NULL AND utm_source IS NULL AND landing_site IS NULL THEN 'unknown'
      WHEN referring_site IS NULL AND utm_source IS NULL THEN 'direct'
      ELSE 'other'
    END AS channel
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
),
agg AS (
  SELECT
    customer_email,
    MIN(order_date)                                                              AS first_order_date,
    MAX(order_date)                                                              AS last_order_date,
    COUNT(DISTINCT order_id)                                                     AS total_orders,
    ARRAY_AGG(channel ORDER BY order_date ASC LIMIT 1)[OFFSET(0)]                AS first_channel,
    ARRAY_AGG(channel ORDER BY order_date DESC LIMIT 1)[OFFSET(0)]               AS last_channel,
    ARRAY_AGG(utm_campaign_resolved IGNORE NULLS ORDER BY order_date ASC LIMIT 1)[SAFE_OFFSET(0)]  AS first_utm_campaign,
    ARRAY_AGG(utm_campaign_resolved IGNORE NULLS ORDER BY order_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS last_utm_campaign
  FROM orders_with_channel
  GROUP BY customer_email
)
SELECT
  customer_email,
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
