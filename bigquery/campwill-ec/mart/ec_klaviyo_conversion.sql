-- mart.ec_klaviyo_conversion: Klaviyo メール送信 → Shopify 購買への転換
-- 各キャンペーンの送信日から7日以内に発生した、Klaviyo プロフィール顧客の Shopify 注文を集計。
--
-- 実装メモ: BigQuery は JOIN 述語内の IN サブクエリを許可しないため、
-- Klaviyo メールと一致する Shopify 注文を CTE で先に絞り込んでから JOIN する。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_klaviyo_conversion` AS
WITH klaviyo_emails AS (
  SELECT DISTINCT email
  FROM `campwill-ec.raw.ec_klaviyo_profiles`
),
klaviyo_orders AS (
  SELECT o.order_id, o.customer_email, o.order_date, o.total_price
  FROM `campwill-ec.raw.ec_shopify_orders` o
  INNER JOIN klaviyo_emails ke
    ON o.customer_email = ke.email
)
SELECT
  k.campaign_id,
  k.campaign_name,
  k.sent_at,
  k.recipients,
  k.open_rate,
  k.click_rate,
  k.revenue                                                         AS klaviyo_revenue,
  COUNT(DISTINCT o.order_id)                                        AS shopify_orders,
  SUM(o.total_price)                                                AS shopify_revenue,
  ROUND(
    SAFE_DIVIDE(COUNT(DISTINCT o.order_id), k.recipients) * 100, 2
  )                                                                 AS purchase_rate_pct
FROM `campwill-ec.raw.ec_klaviyo_campaigns` k
LEFT JOIN klaviyo_orders o
  ON o.order_date BETWEEN DATE(k.sent_at)
    AND DATE_ADD(DATE(k.sent_at), INTERVAL 7 DAY)
GROUP BY
  k.campaign_id, k.campaign_name, k.sent_at,
  k.recipients, k.open_rate, k.click_rate, k.revenue;
