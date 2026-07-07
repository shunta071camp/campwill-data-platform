-- mart.ec_weekly_summary: 週次サマリ（Claude API 投入用）
-- 月曜起算の週ごとに売上・注文数・顧客数・AOV・返品率を集計。
--
-- 注意: raw.ec_shopify_orders は line_item grain (1 order = N rows) のため
-- SUM/AVG 前に order_id で dedup 必須 (未 dedup だと revenue が line 数分過大集計、平均 x1.35)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_weekly_summary` AS
WITH orders AS (
  SELECT
    order_id,
    ANY_VALUE(order_date)     AS order_date,
    ANY_VALUE(total_price)    AS total_price,
    ANY_VALUE(customer_email) AS customer_email,
    ANY_VALUE(is_refunded)    AS is_refunded
  FROM `campwill-ec.raw.ec_shopify_orders`
  GROUP BY order_id
)
SELECT
  DATE_TRUNC(order_date, WEEK(MONDAY))                                        AS week_start,
  SUM(total_price)                                                            AS weekly_revenue,
  COUNT(DISTINCT order_id)                                                    AS weekly_orders,
  COUNT(DISTINCT customer_email)                                              AS weekly_customers,
  ROUND(AVG(total_price), 0)                                                  AS avg_order_value,
  COUNTIF(is_refunded)                                                        AS refund_count,
  ROUND(SAFE_DIVIDE(COUNTIF(is_refunded), COUNT(DISTINCT order_id)) * 100, 1) AS refund_rate_pct
FROM orders
GROUP BY week_start
ORDER BY week_start DESC;
