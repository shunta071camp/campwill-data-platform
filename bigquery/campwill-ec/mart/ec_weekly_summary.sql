-- mart.ec_weekly_summary: 週次サマリ（Claude API 投入用）
-- 月曜起算の週ごとに売上・注文数・顧客数・AOV・返品率を集計。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_weekly_summary` AS
SELECT
  DATE_TRUNC(order_date, WEEK(MONDAY))                          AS week_start,
  SUM(total_price)                                              AS weekly_revenue,
  COUNT(DISTINCT order_id)                                      AS weekly_orders,
  COUNT(DISTINCT customer_email)                                AS weekly_customers,
  ROUND(AVG(total_price), 0)                                    AS avg_order_value,
  COUNTIF(is_refunded)                                          AS refund_count,
  ROUND(SAFE_DIVIDE(COUNTIF(is_refunded), COUNT(*)) * 100, 1)   AS refund_rate_pct
FROM `campwill-ec.raw.ec_shopify_orders`
GROUP BY week_start
ORDER BY week_start DESC;
