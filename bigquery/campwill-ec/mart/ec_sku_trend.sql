-- mart.ec_sku_trend: SKU × 月次トレンド
-- 月次の売上・販売数・MoM/YoY 成長率・rising/declining 分類

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_sku_trend` AS
WITH monthly AS (
  SELECT
    DATE_TRUNC(o.order_date, MONTH)                            AS year_month,
    o.sku,
    ANY_VALUE(o.sku_title)                                     AS sku_title,
    SUM(o.quantity)                                            AS units_sold,
    ROUND(SUM(o.total_price))                                  AS revenue,
    COUNT(DISTINCT o.customer_email)                           AS unique_customers,
    ROUND(SUM(IFNULL(c.cost_price, 0) * o.quantity))           AS total_cost,
    ROUND(SUM(o.total_price) - SUM(IFNULL(c.cost_price, 0) * o.quantity)) AS gross_profit
  FROM `campwill-ec.raw.ec_shopify_orders` o
  LEFT JOIN `campwill-ec.mart.ec_cost_master` c
    ON o.sku = c.sku
    AND o.order_date BETWEEN c.valid_from AND c.valid_to
  WHERE o.sku IS NOT NULL AND o.sku != ''
  GROUP BY year_month, o.sku
),
with_growth AS (
  SELECT
    year_month,
    sku,
    sku_title,
    units_sold,
    revenue,
    unique_customers,
    total_cost,
    gross_profit,
    LAG(revenue, 1)  OVER (PARTITION BY sku ORDER BY year_month) AS prev_month_revenue,
    LAG(revenue, 12) OVER (PARTITION BY sku ORDER BY year_month) AS prev_year_revenue,
    AVG(revenue) OVER (PARTITION BY sku ORDER BY year_month ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS recent3_avg
  FROM monthly
)
SELECT
  year_month,
  sku,
  sku_title,
  units_sold,
  revenue,
  unique_customers,
  total_cost,
  IF(total_cost > 0, gross_profit, NULL) AS gross_profit,
  ROUND(SAFE_DIVIDE(revenue - prev_month_revenue, prev_month_revenue) * 100, 1) AS mom_growth_pct,
  ROUND(SAFE_DIVIDE(revenue - prev_year_revenue, prev_year_revenue) * 100, 1)   AS yoy_growth_pct,
  CASE
    WHEN recent3_avg IS NULL THEN 'unknown'
    WHEN revenue >= recent3_avg * 1.20 THEN 'rising'
    WHEN revenue <= recent3_avg * 0.80 THEN 'declining'
    ELSE 'stable'
  END AS trend_class,
  CURRENT_TIMESTAMP() AS generated_at
FROM with_growth;
