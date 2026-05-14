-- mart.ec_inventory_health: SKU 別 在庫健全性
--
-- 直近の OPENLOGI 在庫スナップショット × 過去 7/30/90 日の販売実績を JOIN し、
-- 在庫切れリスク / 過剰在庫 / 回転率 を算出。
--
-- 判定ロジック:
--   - days_of_stock = available / 過去7日平均販売数
--   - status:
--       stockout         : available <= 0
--       at_risk_7d       : days_of_stock < 7 (1週間以内に枯渇)
--       at_risk_14d      : days_of_stock < 14
--       healthy          : 14 <= days_of_stock < 90
--       overstock        : days_of_stock >= 90 (3ヶ月以上の在庫)
--       no_recent_sales  : 過去 90 日販売 0 (死蔵)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_inventory_health` AS
WITH latest_snapshot AS (
  SELECT *
  FROM `campwill-ec.raw.ec_openlogi_inventory_daily`
  WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM `campwill-ec.raw.ec_openlogi_inventory_daily`)
    AND sku IS NOT NULL
),
-- ec_shopify_orders は 1 line item = 1 row のフラット設計のため UNNEST 不要
sales_7d AS (
  SELECT sku, SUM(quantity) AS sold_7d
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
    AND sku IS NOT NULL AND sku != ''
  GROUP BY sku
),
sales_30d AS (
  SELECT sku, SUM(quantity) AS sold_30d
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
    AND sku IS NOT NULL AND sku != ''
  GROUP BY sku
),
sales_90d AS (
  SELECT sku, SUM(quantity) AS sold_90d
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
    AND sku IS NOT NULL AND sku != ''
  GROUP BY sku
)
SELECT
  s.snapshot_date,
  s.sku,
  s.item_name,
  s.quantity                                                AS total_quantity,
  s.available                                               AS available,
  s.backordered                                             AS backordered,
  s.processing                                              AS processing,
  s.shipping                                                AS shipping,
  IFNULL(s7.sold_7d, 0)                                     AS sold_7d,
  IFNULL(s30.sold_30d, 0)                                   AS sold_30d,
  IFNULL(s90.sold_90d, 0)                                   AS sold_90d,
  ROUND(SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0), 1)  AS days_of_stock,
  ROUND(SAFE_DIVIDE(s30.sold_30d, NULLIF(s.available, 0)) * 100, 1) AS turnover_30d_pct,
  CASE
    WHEN s.available IS NULL OR s.available <= 0                            THEN 'stockout'
    WHEN IFNULL(s90.sold_90d, 0) = 0                                        THEN 'no_recent_sales'
    WHEN SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0) < 7          THEN 'at_risk_7d'
    WHEN SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0) < 14         THEN 'at_risk_14d'
    WHEN SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0) >= 90        THEN 'overstock'
    ELSE                                                                         'healthy'
  END                                                                          AS status,
  CURRENT_TIMESTAMP()                                                          AS generated_at
FROM latest_snapshot s
LEFT JOIN sales_7d  s7  ON s.sku = s7.sku
LEFT JOIN sales_30d s30 ON s.sku = s30.sku
LEFT JOIN sales_90d s90 ON s.sku = s90.sku
ORDER BY
  CASE
    WHEN s.available IS NULL OR s.available <= 0 THEN 1
    WHEN SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0) < 7  THEN 2
    WHEN SAFE_DIVIDE(s.available, NULLIF(s7.sold_7d, 0) / 7.0) < 14 THEN 3
    ELSE 99
  END,
  sold_30d DESC;
