-- mart.ec_storage_cost_estimated: 日次推定保管費用
--
-- ロジック:
--   日次保管費用 = 在庫数 (quantity) × (該当 SKU の月額保管料 / 30)
--   = 1 SKU 1 個 1 日あたりの保管料 × 在庫数
--
-- 月次集計はこのテーブルから SUM すれば取れる。
-- mart.ec_openlogi_storage_rate に SKU 別単価マスタが入っている前提
-- (seed: seeds/ec_openlogi_storage_rate.csv、手動メンテ)。
--
-- 単価マスタに無い SKU は cost 0 で集計から除外。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_storage_cost_estimated` AS
SELECT
  i.snapshot_date,
  i.sku,
  i.item_name,
  i.quantity                                                        AS stock_qty,
  r.size_category,
  r.monthly_rate_yen,
  ROUND(r.monthly_rate_yen / 30.0, 2)                               AS daily_rate_yen,
  ROUND(i.quantity * r.monthly_rate_yen / 30.0, 0)                  AS estimated_daily_cost_yen,
  ROUND(i.quantity * r.monthly_rate_yen, 0)                         AS estimated_monthly_cost_yen,
  CURRENT_TIMESTAMP()                                               AS generated_at
FROM `campwill-ec.raw.ec_openlogi_inventory_daily` i
LEFT JOIN `campwill-ec.mart.ec_openlogi_storage_rate` r
  ON i.sku = r.sku
 AND i.snapshot_date BETWEEN r.valid_from AND r.valid_to
WHERE i.sku IS NOT NULL
ORDER BY i.snapshot_date DESC, estimated_daily_cost_yen DESC NULLS LAST;
