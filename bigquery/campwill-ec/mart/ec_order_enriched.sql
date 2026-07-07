-- mart.ec_order_enriched: 注文 1 行 = 1 row の wide fact table
--
-- 横断分析の起点。新しい問いは ec_order_enriched に対する ad-hoc SQL で答える前提。
-- 含まれるもの: Shopify 注文 + 返金 + UTM/landing/referrer + channel 分類 + GA4 紐付け
--             + first session (リードタイム) + 顧客ライフサイクル (初回/N回目/累計)
--
-- 設計:
--   raw.ec_shopify_orders (1 line item = 1 row) → order_id で集約 (1 order = 1 row)
--   raw.ec_ga4_purchase (transaction_id = order_id 数字 13 桁) で LEFT JOIN
--   raw.ec_ga4_user_first_session (user_pseudo_id) で LEFT JOIN → リードタイム
--   ROW_NUMBER OVER customer_email で order_index_per_customer

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_order_enriched`
PARTITION BY order_date
CLUSTER BY channel_classified, customer_email_hash
AS
WITH order_agg AS (
  SELECT
    order_id,
    ANY_VALUE(order_name)        AS order_name,
    ANY_VALUE(created_at)        AS created_at,
    ANY_VALUE(order_date)        AS order_date,
    ANY_VALUE(customer_id)       AS customer_id,
    ANY_VALUE(customer_email)    AS customer_email,
    ANY_VALUE(financial_status)  AS financial_status,
    ANY_VALUE(total_price)       AS total_price,
    ANY_VALUE(subtotal_price)    AS subtotal_price,
    ANY_VALUE(total_discounts)   AS total_discounts,
    ANY_VALUE(total_tax)         AS total_tax,
    COUNT(*)                     AS line_item_count,
    ARRAY_AGG(DISTINCT sku IGNORE NULLS) AS sku_array,
    SUM(quantity)                AS total_quantity,
    LOGICAL_OR(is_refunded)      AS is_refunded,
    ANY_VALUE(refund_date)       AS refund_date,
    MAX(refund_amount)           AS refund_amount,
    ANY_VALUE(refund_reason)     AS refund_reason,
    ANY_VALUE(source_name)       AS source_name,
    ANY_VALUE(landing_site)      AS landing_site,
    ANY_VALUE(referring_site)    AS referring_site,
    ANY_VALUE(utm_source)        AS utm_source,
    ANY_VALUE(utm_medium)        AS utm_medium,
    ANY_VALUE(utm_campaign)      AS utm_campaign,
    ANY_VALUE(utm_content)       AS utm_content,
    ANY_VALUE(tags)              AS tags
  FROM `campwill-ec.raw.ec_shopify_orders`
  GROUP BY order_id
),
order_resolved AS (
  -- landing_site からの fallback パース (UTM が直接列に無い古い注文や、Shopify 未パースケース対応)
  SELECT
    *,
    COALESCE(utm_source,   REGEXP_EXTRACT(landing_site, r'[?&]utm_source=([^&]+)'))   AS utm_source_resolved,
    COALESCE(utm_medium,   REGEXP_EXTRACT(landing_site, r'[?&]utm_medium=([^&]+)'))   AS utm_medium_resolved,
    COALESCE(utm_campaign, REGEXP_EXTRACT(landing_site, r'[?&]utm_campaign=([^&]+)')) AS utm_campaign_resolved,
    COALESCE(utm_content,  REGEXP_EXTRACT(landing_site, r'[?&]utm_content=([^&]+)'))  AS utm_content_resolved
  FROM order_agg
),
order_with_channel AS (
  -- ec_attribution_first_last:11-29 と同じ channel 分類ロジック
  SELECT
    *,
    CASE
      WHEN utm_source_resolved = 'klaviyo'                                              THEN 'email_klaviyo'
      WHEN utm_medium_resolved IN ('cpc','paid','paidsearch','ppc','dg','pmx')
        AND utm_source_resolved = 'google'                                              THEN 'google_paid'
      WHEN utm_medium_resolved IN ('cpc','paid','social','organic_social')
        AND utm_source_resolved IN ('facebook','fb','instagram','ig','meta','ig.me')   THEN 'meta_paid'
      WHEN utm_medium_resolved IN ('cpc','paid','dsa')
        AND utm_source_resolved = 'yahoo'                                               THEN 'yahoo_paid'
      WHEN utm_medium_resolved IN ('cpc','paid')
        AND utm_source_resolved IN ('bing','microsoft')                                 THEN 'microsoft_paid'
      WHEN referring_site LIKE '%instagram.com%' AND utm_medium_resolved IS NULL        THEN 'instagram_organic'
      WHEN referring_site LIKE '%google.com%'    AND utm_medium_resolved IS NULL        THEN 'seo_google'
      WHEN referring_site LIKE '%yahoo.co.jp%'   AND utm_medium_resolved IS NULL        THEN 'seo_yahoo'
      WHEN referring_site LIKE '%bing.com%'      AND utm_medium_resolved IS NULL        THEN 'seo_bing'
      WHEN referring_site LIKE '%youtube.com%'   AND utm_medium_resolved IS NULL        THEN 'social_youtube'
      WHEN referring_site IS NULL AND utm_source_resolved IS NULL AND landing_site IS NULL THEN 'unknown'
      WHEN referring_site IS NULL AND utm_source_resolved IS NULL                       THEN 'direct'
      ELSE 'other'
    END AS channel_classified
  FROM order_resolved
),
ga_purchases AS (
  -- 1 transaction_id に複数 purchase event 入ることがあるので最初のみ採用
  SELECT
    transaction_id,
    ANY_VALUE(user_pseudo_id    HAVING MIN event_ts) AS user_pseudo_id,
    MIN(event_ts)               AS purchase_ts_ga4,
    ANY_VALUE(device_category   HAVING MIN event_ts) AS device_category,
    ANY_VALUE(device_os         HAVING MIN event_ts) AS device_os,
    ANY_VALUE(device_browser    HAVING MIN event_ts) AS device_browser,
    ANY_VALUE(geo_country       HAVING MIN event_ts) AS geo_country,
    ANY_VALUE(geo_region        HAVING MIN event_ts) AS geo_region,
    ANY_VALUE(session_source    HAVING MIN event_ts) AS session_source,
    ANY_VALUE(session_medium    HAVING MIN event_ts) AS session_medium,
    ANY_VALUE(session_campaign  HAVING MIN event_ts) AS session_campaign,
    ANY_VALUE(session_content   HAVING MIN event_ts) AS session_content,
    ANY_VALUE(page_location     HAVING MIN event_ts) AS purchase_page_location
  FROM `campwill-ec.raw.ec_ga4_purchase`
  WHERE transaction_id IS NOT NULL
  GROUP BY transaction_id
),
customer_history AS (
  -- 同じ customer_email の中での順位 (1 = 初回注文)
  SELECT
    order_id,
    ROW_NUMBER() OVER (PARTITION BY customer_email ORDER BY created_at ASC) AS order_index_per_customer,
    MIN(order_date) OVER (PARTITION BY customer_email)                       AS customer_first_order_date,
    COUNT(*)        OVER (PARTITION BY customer_email)                       AS customer_total_orders_lifetime
  FROM order_agg
  WHERE customer_email IS NOT NULL
),
email_unified_first_session AS (
  -- crosswalk 経由で同 email の全 user_pseudo_id の最古 first_session を取る
  -- (cross-device journey の真の起点 = device 横断で最初に来た時刻)
  -- crosswalk は customer_email_hash で持つので、order 側も hash 化して JOIN
  SELECT
    cw.customer_email_hash,
    MIN(fs.first_session_ts)              AS email_unified_first_session_ts,
    COUNT(DISTINCT cw.user_pseudo_id)     AS email_device_count,
    ARRAY_AGG(STRUCT(fs.first_source AS src, fs.first_medium AS med, fs.first_campaign AS cam)
              ORDER BY fs.first_session_ts ASC LIMIT 1)[OFFSET(0)] AS earliest_attribution
  FROM `campwill-ec.mart.ec_customer_user_crosswalk` cw
  JOIN `campwill-ec.raw.ec_ga4_user_first_session` fs
    USING (user_pseudo_id)
  GROUP BY cw.customer_email_hash
),
klaviyo_clicks AS (
  -- 各 email × 各 click event の timestamp。Klaviyo Events API (Clicked Email) 経由。
  SELECT
    LOWER(email)        AS email,
    event_ts            AS click_ts,
    campaign_id         AS click_campaign_id
  FROM `campwill-ec.raw.ec_klaviyo_events_latest`
  WHERE metric_name = 'Clicked Email'
    AND email IS NOT NULL
)
SELECT
  -- ===== 注文基本 =====
  o.order_id,
  o.order_name,
  o.order_date,
  o.created_at,
  o.customer_id,
  TO_HEX(SHA256(LOWER(o.customer_email))) AS customer_email_hash,
  o.financial_status,

  -- ===== 金額 =====
  o.total_price,
  o.subtotal_price,
  o.total_discounts,
  o.total_tax,

  -- ===== 商品 =====
  o.line_item_count,
  o.total_quantity,
  o.sku_array,

  -- ===== 返金 =====
  o.is_refunded,
  o.refund_date,
  o.refund_amount,
  o.refund_reason,
  ROUND(SAFE_DIVIDE(o.refund_amount, o.total_price) * 100, 2) AS refund_amount_pct,
  IF(o.is_refunded AND o.refund_date IS NOT NULL,
     DATE_DIFF(o.refund_date, o.order_date, DAY), NULL)        AS days_to_refund,

  -- ===== Attribution (Shopify + landing_site fallback) =====
  o.source_name,
  o.landing_site,
  o.referring_site,
  o.utm_source_resolved   AS utm_source,
  o.utm_medium_resolved   AS utm_medium,
  o.utm_campaign_resolved AS utm_campaign,
  o.utm_content_resolved  AS utm_content,
  o.channel_classified,
  o.tags,

  -- ===== GA4 紐付け (purchase event 経由) =====
  p.user_pseudo_id,
  p.purchase_ts_ga4,
  p.device_category,
  p.device_os,
  p.device_browser,
  p.geo_country,
  p.geo_region,
  p.purchase_page_location,
  p.session_source        AS ga4_session_source,
  p.session_medium        AS ga4_session_medium,
  p.session_campaign      AS ga4_session_campaign,
  p.session_content       AS ga4_session_content,

  -- ===== GA4 first session (リードタイム) =====
  fs.first_session_ts,
  fs.first_session_date,
  fs.first_source         AS ga4_first_source,
  fs.first_medium         AS ga4_first_medium,
  fs.first_campaign       AS ga4_first_campaign,
  fs.first_device_category AS ga4_first_device_category,
  TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, HOUR) AS lead_time_hours,
  TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, DAY)  AS lead_time_days,
  CASE
    WHEN p.purchase_ts_ga4 IS NULL OR fs.first_session_ts IS NULL                THEN 'unmatched_ga4'
    WHEN TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, HOUR) < 0        THEN 'invalid'
    WHEN TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, HOUR) < 1        THEN 'instant'
    WHEN TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, HOUR) < 24       THEN 'same_day'
    WHEN TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, DAY)  < 7        THEN 'within_week'
    WHEN TIMESTAMP_DIFF(p.purchase_ts_ga4, fs.first_session_ts, DAY)  < 30       THEN 'within_month'
    ELSE                                                                              'over_month'
  END AS lead_time_bucket,

  -- ===== 顧客ライフサイクル =====
  ch.order_index_per_customer,
  ch.order_index_per_customer = 1               AS is_first_order,
  ch.customer_first_order_date,
  ch.customer_total_orders_lifetime,
  DATE_DIFF(o.order_date, ch.customer_first_order_date, DAY) AS days_since_customer_first_order,

  -- ===== Cross-device 真のリードタイム (email crosswalk 経由) =====
  -- 同 customer_email の全 user_pseudo_id を crosswalk で集めて最古の first_session を起点に
  -- 1 つの device の lead_time よりこちらが「真の」lead time (cross-device journey 起点)
  eu.email_unified_first_session_ts,
  eu.email_device_count,
  eu.earliest_attribution.src      AS email_unified_first_source,
  eu.earliest_attribution.med      AS email_unified_first_medium,
  eu.earliest_attribution.cam      AS email_unified_first_campaign,
  TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, HOUR) AS email_unified_lead_time_hours,
  TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, DAY)  AS email_unified_lead_time_days,
  CASE
    WHEN eu.email_unified_first_session_ts IS NULL                                       THEN 'unmatched_email'
    -- 注文が GA4 export 開始 (2026-05-01) より前 → first_session を引いても起点として無意味
    WHEN o.order_date < DATE '2026-05-01'                                                THEN 'pre_ga4_export'
    -- 注文時刻が引いた first_session より前 = 1 回目購入時には session 未記録 (GA4 タグ未発火等)
    WHEN TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, HOUR) < 0       THEN 'session_after_order'
    WHEN TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, HOUR) < 1       THEN 'instant'
    WHEN TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, HOUR) < 24      THEN 'same_day'
    WHEN TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, DAY)  < 7       THEN 'within_week'
    WHEN TIMESTAMP_DIFF(o.created_at, eu.email_unified_first_session_ts, DAY)  < 30      THEN 'within_month'
    ELSE                                                                                       'over_month'
  END AS email_unified_lead_time_bucket,

  -- ===== Klaviyo click attribution =====
  -- 注文前 5 日以内に同 email が Klaviyo メール click をしていたら true
  -- (Klaviyo 内 last-click 5 日 attribution window と整合)
  -- これが true の注文は ec_channel_attribution_weekly v2.0 で email_klaviyo に override される
  EXISTS (
    SELECT 1 FROM klaviyo_clicks kc
    WHERE kc.email = LOWER(o.customer_email)
      AND kc.click_ts BETWEEN TIMESTAMP_SUB(o.created_at, INTERVAL 5 DAY) AND o.created_at
  ) AS klaviyo_clicked_within_5d,

  CURRENT_TIMESTAMP() AS generated_at
FROM order_with_channel o
LEFT JOIN ga_purchases p
  ON p.transaction_id = CAST(o.order_id AS STRING)
LEFT JOIN `campwill-ec.raw.ec_ga4_user_first_session` fs
  ON fs.user_pseudo_id = p.user_pseudo_id
LEFT JOIN customer_history ch
  USING (order_id)
LEFT JOIN email_unified_first_session eu
  ON eu.customer_email_hash = TO_HEX(SHA256(LOWER(o.customer_email)));
