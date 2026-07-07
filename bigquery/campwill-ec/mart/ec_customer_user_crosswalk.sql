-- mart.ec_customer_user_crosswalk: customer_email × GA4 user_pseudo_id の対応マップ
--
-- 目的:
--   GA4 は cookie/device 単位で user_pseudo_id を発行するため、同一人物が複数 device を使うと
--   別 user として扱われる。Shopify 側は customer_email で個人を識別できる。
--   両者の crosswalk = 「あるメールアドレスに紐づく全 user_pseudo_id 群」を保持。
--
-- 紐付け原理:
--   GA4 purchase event の transaction_id (= Shopify order_id) を使い、
--     ec_shopify_orders.order_id ↔ ec_ga4_purchase.transaction_id で email を引き当てる
--   1 customer_email に複数 user_pseudo_id が紐付くこと多々あり (cross-device)
--   逆向き (1 user_pseudo_id に複数 email) は通常 1:1 だが、共有 device で発生し得る
--
-- 用途:
--   ec_order_enriched で「customer_email の最も古い first_session_ts」を引いて
--   cross-device リードタイムを正しく計算する

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_customer_user_crosswalk`
CLUSTER BY customer_email_hash, user_pseudo_id
AS
WITH order_to_email AS (
  -- order_id (string) ← email
  SELECT DISTINCT
    CAST(order_id AS STRING) AS order_id_str,
    customer_email
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
),
email_pseudo_pairs AS (
  -- GA4 purchase event ↔ Shopify order ↔ email
  SELECT
    o.customer_email,
    p.user_pseudo_id,
    MIN(p.event_ts) AS first_purchase_ts_of_pair,
    COUNT(*)        AS purchase_event_count
  FROM `campwill-ec.raw.ec_ga4_purchase` p
  JOIN order_to_email o
    ON p.transaction_id = o.order_id_str
  WHERE p.user_pseudo_id IS NOT NULL
  GROUP BY 1, 2
),
session_stats AS (
  -- 各 user_pseudo_id の session_start ベースのライフタイム
  SELECT
    user_pseudo_id,
    first_session_ts,
    first_session_date,
    first_source,
    first_medium,
    first_campaign,
    first_device_category,
    first_geo_country
  FROM `campwill-ec.raw.ec_ga4_user_first_session`
)
SELECT
  TO_HEX(SHA256(LOWER(pair.customer_email))) AS customer_email_hash,
  pair.user_pseudo_id,
  pair.purchase_event_count,
  pair.first_purchase_ts_of_pair,
  s.first_session_ts,
  s.first_session_date,
  s.first_source,
  s.first_medium,
  s.first_campaign,
  s.first_device_category,
  s.first_geo_country,
  -- email 単位での集約 (window 関数で後でも引けるように冗長持ち)
  COUNT(*)                     OVER (PARTITION BY pair.customer_email) AS customer_known_devices_count,
  MIN(s.first_session_ts)      OVER (PARTITION BY pair.customer_email) AS customer_earliest_first_session_ts,
  MAX(s.first_session_ts)      OVER (PARTITION BY pair.customer_email) AS customer_latest_first_session_ts,
  CURRENT_TIMESTAMP() AS generated_at
FROM email_pseudo_pairs pair
LEFT JOIN session_stats s
  USING (user_pseudo_id);
