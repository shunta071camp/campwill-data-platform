-- mart.ec_channel_roi: チャネル別 売上 / 広告cost / ROAS / CPA / LTV / 返品率
-- UTM (raw 列 OR landing_site URL から REGEXP 抽出) と referring_site から流入チャネル判定
-- 各広告 raw (Google/Meta/Yahoo/MS) から cost を取得 → ROAS / CPA を算出
-- 注: 現状 raw.ec_shopify_orders.utm_* 列は NULL のため landing_site から都度 parse する設計

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_channel_roi` AS
WITH ad_costs AS (
  SELECT date, 'google_paid'    AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_google_ads`    GROUP BY date
  UNION ALL
  SELECT date, 'meta_paid'      AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_meta_ads`      GROUP BY date
  UNION ALL
  SELECT date, 'yahoo_paid'     AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_yahoo_ads`     GROUP BY date
  UNION ALL
  SELECT date, 'microsoft_paid' AS channel, SUM(cost) AS ad_cost FROM `campwill-ec.raw.ec_microsoft_ads` GROUP BY date
),
orders_with_utm AS (
  -- raw 列が NULL なら landing_site URL から REGEXP で抽出
  SELECT
    order_id,
    customer_email,
    order_date,
    total_price,
    is_refunded,
    referring_site,
    COALESCE(utm_source, REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)'))   AS utm_source,
    COALESCE(utm_medium, REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)'))   AS utm_medium,
    COALESCE(utm_campaign, REGEXP_EXTRACT(landing_site, r'[?&]utm_campaign=([^&]+)')) AS utm_campaign
  FROM `campwill-ec.raw.ec_shopify_orders`
),
shopify_by_channel AS (
  SELECT
    order_date,
    CASE
      WHEN utm_source = 'klaviyo'                                                       THEN 'email_klaviyo'
      WHEN utm_medium IN ('cpc','paid','paidsearch','ppc','dg')
        AND utm_source = 'google'                                                       THEN 'google_paid'
      WHEN utm_medium IN ('cpc','paid')
        AND utm_source IN ('facebook','instagram','meta')                               THEN 'meta_paid'
      WHEN utm_medium IN ('cpc','paid')
        AND utm_source = 'yahoo'                                                        THEN 'yahoo_paid'
      WHEN utm_medium IN ('cpc','paid')
        AND utm_source IN ('bing','microsoft')                                          THEN 'microsoft_paid'
      WHEN referring_site LIKE '%instagram.com%' AND utm_medium IS NULL                 THEN 'instagram_organic'
      WHEN referring_site LIKE '%google.com%'    AND utm_medium IS NULL                 THEN 'seo_google'
      WHEN referring_site LIKE '%yahoo.co.jp%'   AND utm_medium IS NULL                 THEN 'seo_yahoo'
      WHEN referring_site LIKE '%youtube.com%'   AND utm_medium IS NULL                 THEN 'social_youtube'
      WHEN referring_site IS NULL AND utm_source IS NULL                                THEN 'direct'
      ELSE 'other'
    END                                                              AS channel,
    COUNT(DISTINCT order_id)                                         AS orders,
    COUNT(DISTINCT customer_email)                                   AS unique_customers,
    SUM(total_price)                                                 AS revenue,
    COUNTIF(is_refunded)                                             AS refund_count,
    ROUND(SAFE_DIVIDE(COUNTIF(is_refunded), COUNT(*)) * 100, 1)      AS refund_rate_pct,
    SAFE_DIVIDE(SUM(total_price), COUNT(DISTINCT customer_email))    AS ltv
  FROM orders_with_utm
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
