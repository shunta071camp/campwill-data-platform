-- mart.ec_cohort_ltv: コホート月 × 経過月の累計 LTV / リテンション
-- 顧客の初回購入月で cohort 化し、経過月ごとの累計売上 / アクティブ顧客率を集計

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_cohort_ltv` AS
WITH first_order AS (
  SELECT
    customer_email,
    DATE_TRUNC(MIN(order_date), MONTH) AS cohort_month
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
  GROUP BY customer_email
),
cohort_sizes AS (
  SELECT cohort_month, COUNT(DISTINCT customer_email) AS cohort_size
  FROM first_order
  GROUP BY cohort_month
),
orders_by_cohort_month AS (
  SELECT
    f.cohort_month,
    DATE_DIFF(DATE_TRUNC(o.order_date, MONTH), f.cohort_month, MONTH) AS months_since_first,
    COUNT(DISTINCT o.customer_email)                                  AS active_customers,
    COUNT(DISTINCT o.order_id)                                        AS month_orders,
    SUM(o.total_price)                                                AS month_revenue
  FROM `campwill-ec.raw.ec_shopify_orders` o
  JOIN first_order f USING (customer_email)
  WHERE o.customer_email IS NOT NULL
  GROUP BY f.cohort_month, months_since_first
),
with_cumulative AS (
  SELECT
    cohort_month,
    months_since_first,
    active_customers,
    month_orders,
    month_revenue,
    SUM(month_orders)  OVER (PARTITION BY cohort_month ORDER BY months_since_first) AS cumulative_orders,
    SUM(month_revenue) OVER (PARTITION BY cohort_month ORDER BY months_since_first) AS cumulative_revenue
  FROM orders_by_cohort_month
)
SELECT
  w.cohort_month,
  w.months_since_first,
  cs.cohort_size,
  w.active_customers,
  ROUND(SAFE_DIVIDE(w.active_customers, cs.cohort_size) * 100, 1) AS retention_pct,
  w.month_orders,
  ROUND(w.month_revenue)                                          AS month_revenue,
  w.cumulative_orders,
  ROUND(w.cumulative_revenue)                                     AS cumulative_revenue,
  ROUND(SAFE_DIVIDE(w.cumulative_revenue, cs.cohort_size))        AS cumulative_ltv,
  CURRENT_TIMESTAMP()                                              AS generated_at
FROM with_cumulative w
JOIN cohort_sizes cs USING (cohort_month);
