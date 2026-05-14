-- mart.ec_cost_master : Shopify products daily snapshot から valid_from/valid_to 自動導出
--
-- 仕組み:
--   raw.ec_shopify_products_daily に SKU × 日次 で cost_price snapshot
--   → LAG window 関数で前日との差分検出
--   → 同じ cost_price が続く期間を group 化 → 1 行に集約
--   → valid_to は次の change point - 1 日 (最新は 2099-12-31)
--
-- ec_daily_pnl の JOIN シグネチャ (sku, valid_from BETWEEN, valid_to) と互換

CREATE OR REPLACE VIEW `campwill-ec.mart.ec_cost_master` AS
WITH snapshots AS (
  SELECT
    sku,
    cost_price,
    fetched_date,
    LAG(cost_price) OVER (PARTITION BY sku ORDER BY fetched_date) AS prev_cost
  FROM `campwill-ec.raw.ec_shopify_products_daily`
  WHERE cost_price IS NOT NULL
    AND sku IS NOT NULL
    AND sku != ''
),
change_groups AS (
  SELECT
    sku,
    cost_price,
    fetched_date,
    SUM(CASE WHEN prev_cost IS NULL OR prev_cost != cost_price THEN 1 ELSE 0 END)
      OVER (PARTITION BY sku ORDER BY fetched_date) AS group_id
  FROM snapshots
),
periods AS (
  SELECT
    sku,
    cost_price,
    MIN(fetched_date) AS valid_from
  FROM change_groups
  GROUP BY sku, cost_price, group_id
)
SELECT
  sku,
  cost_price,
  -- 最初の period の valid_from は遡らせる (過去注文にも適用するため)
  IF(
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY valid_from) = 1,
    DATE('2020-01-01'),
    valid_from
  ) AS valid_from,
  COALESCE(
    DATE_SUB(LEAD(valid_from) OVER (PARTITION BY sku ORDER BY valid_from), INTERVAL 1 DAY),
    DATE('2099-12-31')
  ) AS valid_to
FROM periods;
