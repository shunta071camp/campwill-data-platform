-- mart.ec_order_line_enriched: 注文 line item 1 行 = 1 row の wide fact
--
-- 用途: SKU レベル分析の起点。週次 SKU 別売上 / SKU 別返品率 / SKU × チャネル 売上クロス
--       / 赤字 SKU 特定など、ec_order_enriched (order 単位) では出せない問いに答える。
--
-- ⚠️ **line-grain 設計上の注意 (SUM/AVG 時に必読)**:
--   - `line_revenue_yen` = quantity * unit_price - line_discount → line-level ✅ **売上集計はこれ**
--   - `total_price` は order.total_price を全 line に複製 → **naive SUM は line 数分過大集計** (avg x1.5、実測 6/25-7/7)
--   - order-level 合計が必要なら: SELECT SUM(x) FROM (SELECT order_id, ANY_VALUE(total_price) AS x FROM ec_order_line_enriched GROUP BY order_id)
--     または ec_order_enriched を使う (すでに 1 order = 1 row)
--
-- 設計:
--   - raw.ec_shopify_orders (1 line item = 1 row) をベースに
--   - 注文単位の attribution / channel / GA4 / lifecycle は mart.ec_order_enriched から JOIN
--     (channel 分類 CASE 文の重複定義回避)
--   - customer_email は SHA256 hash 化 (mart = PII ゼロ)
--
-- 注: ec_order_enriched が先に再生成される前提 (順序: 22:30 enriched → 22:35 line_enriched)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_order_line_enriched`
PARTITION BY order_date
CLUSTER BY channel_classified, sku
AS
WITH lines AS (
  SELECT
    -- ===== Line item 基本 =====
    line_item_id,
    order_id,
    order_name,
    created_at,
    order_date,
    sku,
    sku_title,
    variant_title,
    product_id,
    variant_id,
    quantity,
    unit_price,
    line_discount,
    quantity * unit_price - IFNULL(line_discount, 0)         AS line_revenue_yen,

    -- ===== Line 返金 (raw は order 単位の refund_amount で持つので注意) =====
    is_refunded,
    refund_date,
    refund_amount,
    refund_reason,

    -- ===== 注文サマリ =====
    customer_id,
    TO_HEX(SHA256(LOWER(customer_email)))                    AS customer_email_hash,
    financial_status,
    total_price,
    subtotal_price,
    total_discounts,
    total_tax,
    tags
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE customer_email IS NOT NULL
    AND sku IS NOT NULL AND sku != ''
)
SELECT
  l.*,

  -- ===== Attribution / channel / GA4 / lifecycle: ec_order_enriched から JOIN =====
  oe.utm_source,
  oe.utm_medium,
  oe.utm_campaign,
  oe.utm_content,
  oe.channel_classified,
  oe.source_name,
  oe.landing_site,
  oe.referring_site,
  oe.user_pseudo_id,
  oe.device_category,
  oe.device_os,
  oe.geo_country,
  oe.lead_time_days,
  oe.lead_time_bucket,
  oe.email_unified_lead_time_days,
  oe.email_unified_lead_time_bucket,
  oe.order_index_per_customer,
  oe.is_first_order,
  oe.customer_total_orders_lifetime,

  CURRENT_TIMESTAMP() AS generated_at
FROM lines l
LEFT JOIN `campwill-ec.mart.ec_order_enriched` oe
  USING (order_id);
