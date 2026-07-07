-- mart.ec_daily_pnl: 日次粗利テーブル
-- 1注文 × 1SKU = 1行で粗利・実質粗利・粗利率を計算する。
--
-- ⚠️ **line-grain 設計上の注意 (SUM/AVG 時に必読)**:
--   - `revenue` 列は order.total_price (order-level) を全 SKU 行に複製している
--   - `SUM(revenue) GROUP BY order_date` は line 数分過大集計 (avg x1.35 倍)
--   - 正しい方法: `SELECT order_date, SUM(revenue) FROM (SELECT DISTINCT order_id, order_date, revenue FROM ec_daily_pnl) GROUP BY order_date`
--   - あるいは line-level 実質売上が必要なら `unit_price * quantity - line_discount` を別途計算する
--   - 同様に gross_profit / actual_gross_profit も line 単位で意味を成さない (SKU 別 cost - order 全体 revenue)
--
-- 運用前提:
--   - mart.ec_shipping_rules は同時に「1行のみ有効」であることが必須。
--     送料を変更する場合は古い行の valid_to を更新してから新行を追加する。
--     (複数行が同期間で重複すると CROSS JOIN が直積になり、行数が膨れる)
--   - 後日 BigQuery のスケジュールクエリに登録して毎日 AM6:00 に再生成する想定。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_daily_pnl` AS
SELECT
  o.order_date,
  o.order_id,
  o.sku,
  o.quantity,
  o.unit_price,
  o.total_price                                           AS revenue,
  c.cost_price,
  c.cost_price * o.quantity                               AS total_cost,
  o.total_price - (c.cost_price * o.quantity)             AS gross_profit,
  s.shipping_fee_per_order,
  o.total_price - (c.cost_price * o.quantity)
    - s.shipping_fee_per_order                            AS actual_gross_profit,
  ROUND(
    SAFE_DIVIDE(
      o.total_price - (c.cost_price * o.quantity)
        - s.shipping_fee_per_order,
      o.total_price
    ) * 100, 1
  )                                                       AS actual_margin_pct,
  o.is_refunded,
  o.refund_amount
FROM `campwill-ec.raw.ec_shopify_orders` o
LEFT JOIN `campwill-ec.mart.ec_cost_master` c
  ON o.sku = c.sku
  AND o.order_date BETWEEN c.valid_from AND c.valid_to
CROSS JOIN `campwill-ec.mart.ec_shipping_rules` s
WHERE s.valid_from <= o.order_date
  AND s.valid_to   >= o.order_date;
