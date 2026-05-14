-- mart.ec_repeat_pattern: 注文間隔の分布 (第N回 → 第N+1回)
-- 「初回購入から平均何日でリピートするか」「90日以内リピート率」などを可視化

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_repeat_pattern` AS
WITH ordered AS (
  SELECT
    customer_email,
    order_date,
    ROW_NUMBER() OVER (PARTITION BY customer_email ORDER BY order_date) AS order_index
  FROM (
    SELECT DISTINCT customer_email, order_date
    FROM `campwill-ec.raw.ec_shopify_orders`
    WHERE customer_email IS NOT NULL
  )
),
intervals AS (
  SELECT
    o1.order_index AS order_index,
    DATE_DIFF(o2.order_date, o1.order_date, DAY) AS days_to_next
  FROM ordered o1
  JOIN ordered o2
    ON o1.customer_email = o2.customer_email
    AND o2.order_index = o1.order_index + 1
)
SELECT
  order_index,
  COUNT(*)                                                                          AS customer_count,
  ROUND(AVG(days_to_next))                                                          AS avg_days_to_next,
  CAST(APPROX_QUANTILES(days_to_next, 4)[OFFSET(1)] AS INT64)                       AS p25_days,
  CAST(APPROX_QUANTILES(days_to_next, 4)[OFFSET(2)] AS INT64)                       AS median_days,
  CAST(APPROX_QUANTILES(days_to_next, 4)[OFFSET(3)] AS INT64)                       AS p75_days,
  ROUND(COUNTIF(days_to_next <=  30) / COUNT(*) * 100, 1)                           AS pct_within_30d,
  ROUND(COUNTIF(days_to_next <=  60) / COUNT(*) * 100, 1)                           AS pct_within_60d,
  ROUND(COUNTIF(days_to_next <=  90) / COUNT(*) * 100, 1)                           AS pct_within_90d,
  ROUND(COUNTIF(days_to_next <= 180) / COUNT(*) * 100, 1)                           AS pct_within_180d,
  CURRENT_TIMESTAMP()                                                                AS generated_at
FROM intervals
WHERE order_index <= 10  -- 第10回まで集計（それ以降はサンプル少なすぎ）
GROUP BY order_index
ORDER BY order_index;
