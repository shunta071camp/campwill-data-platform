-- mart.ec_storage_cost_estimated: 日次推定保管費用
--
-- 設計:
--   inventory_daily.sku
--     → ec_openlogi_sku_size_map (sku → size_category 手動マッピング)
--     → ec_openlogi_storage_rate (size_category → 日額/月額) で料金照合
--
-- size_category マッピング無い SKU は cost NULL (集計から自動除外)。
-- 料金は日額ベースなので estimated_daily_cost = quantity × daily_rate_yen。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_storage_cost_estimated` AS
SELECT
  i.snapshot_date,
  i.sku,
  i.item_name,
  i.quantity                                                                AS stock_qty,
  m.size_category,
  r.daily_rate_yen,
  r.monthly_rate_yen,
  ROUND(i.quantity * r.daily_rate_yen, 2)                                   AS estimated_daily_cost_yen,
  ROUND(i.quantity * r.monthly_rate_yen, 0)                                 AS estimated_monthly_cost_yen,
  CURRENT_TIMESTAMP()                                                       AS generated_at
FROM `campwill-ec.raw.ec_openlogi_inventory_daily` i
LEFT JOIN `campwill-ec.mart.ec_openlogi_sku_size_map` m
  ON i.sku = m.sku
 AND i.snapshot_date BETWEEN m.valid_from AND m.valid_to
LEFT JOIN `campwill-ec.mart.ec_openlogi_storage_rate` r
  ON m.size_category = r.size_category
 AND i.snapshot_date BETWEEN r.valid_from AND r.valid_to
WHERE i.sku IS NOT NULL
ORDER BY i.snapshot_date DESC, estimated_daily_cost_yen DESC NULLS LAST;
