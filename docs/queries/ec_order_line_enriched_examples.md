# `mart.ec_order_line_enriched` クエリ例集

SKU 視点の起点 wide fact。line item 1 行 = 1 row（約 20k 行）、SKU/quantity/unit_price/line 返金 + channel + lifecycle 全部入り。

`ec_order_enriched` (注文 1 行 = 1 row) と使い分け:
- 注文 × 顧客 × チャネルの分析 → `ec_order_enriched`
- SKU × ... の分析 → **`ec_order_line_enriched`** (これ)

---

## 前提

- 必ず `WHERE order_date >= ...` で partition フィルタ
- cluster: `channel_classified, sku` → これらのフィルタが効く
- PII ゼロ。customer は `customer_email_hash` のみ

---

## 1. 週次 SKU 別売上

```sql
SELECT
  DATE_TRUNC(order_date, WEEK(MONDAY))             AS week,
  sku, sku_title,
  SUM(quantity)                                    AS units_sold,
  SUM(line_revenue_yen)                             AS revenue_yen,
  COUNTIF(is_refunded)                             AS refunded_lines,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)  AS refund_rate_pct
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
GROUP BY 1, 2, 3
ORDER BY week DESC, revenue_yen DESC;
```

---

## 2. SKU 別返品率 (直近 180 日、注文 10 件以上)

```sql
SELECT
  sku, sku_title,
  COUNT(*)                                          AS lines,
  SUM(quantity)                                     AS units,
  SUM(line_revenue_yen)                              AS revenue_yen,
  COUNTIF(is_refunded)                              AS refunded_lines,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)   AS refund_rate_pct
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 180 DAY)
GROUP BY 1, 2
HAVING lines >= 10
ORDER BY refund_rate_pct DESC;
```

---

## 3. SKU × チャネル の売上クロス

```sql
SELECT
  channel_classified, sku, sku_title,
  COUNT(DISTINCT order_id)                          AS orders,
  SUM(quantity)                                     AS units,
  SUM(line_revenue_yen)                              AS revenue_yen
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
GROUP BY 1, 2, 3
HAVING units >= 5
ORDER BY revenue_yen DESC;
```

---

## 4. 赤字 SKU 特定（`ec_cost_master` JOIN）

```sql
SELECT
  l.sku, l.sku_title,
  SUM(l.quantity)                                            AS units,
  SUM(l.line_revenue_yen)                                     AS revenue,
  SUM(l.quantity * c.cost_yen)                                AS cost,
  SUM(l.line_revenue_yen - l.quantity * c.cost_yen)          AS gross_profit,
  ROUND(SAFE_DIVIDE(SUM(l.line_revenue_yen - l.quantity * c.cost_yen),
                    SUM(l.line_revenue_yen)) * 100, 1)        AS gross_margin_pct
FROM `campwill-ec.mart.ec_order_line_enriched` l
LEFT JOIN `campwill-ec.mart.ec_cost_master` c USING (sku)
WHERE l.order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY 1, 2
HAVING gross_profit < 0
ORDER BY gross_profit ASC;
```

---

## 5. 「初回購入」で最も買われている SKU

```sql
SELECT
  sku, sku_title,
  COUNT(*)                                          AS first_order_lines,
  SUM(quantity)                                     AS first_order_units
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE is_first_order
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 180 DAY)
GROUP BY 1, 2
ORDER BY first_order_units DESC
LIMIT 30;
```

---

## 6. 「SKU × デバイス」の購入傾向

```sql
SELECT
  sku, device_category,
  SUM(quantity)                                     AS units,
  SUM(line_revenue_yen)                              AS revenue_yen
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE device_category IS NOT NULL
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
GROUP BY 1, 2
HAVING units >= 10
ORDER BY sku, units DESC;
```

---

## 7. リピート顧客が買い直す SKU トップ

```sql
SELECT
  sku, sku_title,
  COUNT(DISTINCT customer_email_hash)               AS repeat_customers,
  SUM(quantity)                                     AS repeat_units
FROM `campwill-ec.mart.ec_order_line_enriched`
WHERE order_index_per_customer >= 2
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 180 DAY)
GROUP BY 1, 2
ORDER BY repeat_units DESC
LIMIT 30;
```

---

## 列リファレンス

| 列 | 意味 |
|---|---|
| `order_date` | 注文日（partition 列、必ず WHERE に） |
| `sku` | SKU コード（cluster 列、フィルタ効く） |
| `channel_classified` | チャネル分類（cluster 列、フィルタ効く） |
| `line_item_id` | 行 ID |
| `order_id` / `order_name` | 注文 ID（同 order_id で複数 line） |
| `customer_email_hash` | 顧客ハッシュ（PII ゼロ） |
| `sku_title` / `variant_title` | 商品名・バリアント |
| `quantity` / `unit_price` / `line_discount` | 数量・単価・行割引 |
| `line_revenue_yen` | quantity × unit_price - line_discount |
| `is_refunded` / `refund_amount` / `refund_reason` | 返金 (raw では order 単位、line 配分は将来課題) |
| `total_price` / `subtotal_price` / `total_discounts` / `total_tax` | 注文全体の金額 |
| `utm_source` / `utm_medium` / `utm_campaign` / `utm_content` | UTM (ec_order_enriched から JOIN) |
| `landing_site` / `referring_site` / `source_name` | Attribution 詳細 |
| `user_pseudo_id` / `device_category` / `device_os` / `geo_country` | GA4 (ec_order_enriched 経由) |
| `lead_time_days` / `lead_time_bucket` | first session → purchase (single device) |
| `email_unified_lead_time_days` / `_bucket` | cross-device 真のリードタイム |
| `is_first_order` / `order_index_per_customer` / `customer_total_orders_lifetime` | 顧客ライフサイクル |
