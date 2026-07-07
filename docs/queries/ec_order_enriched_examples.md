# `mart.ec_order_enriched` クエリ例集

横断分析の起点 wide fact table。注文 1 行 = 1 row、attribution + GA4 + 返金 + lifecycle 全部入り。

新しい問いは **このテーブルへの ad-hoc SQL** で答える前提。新しい mart は基本的に追加しない。

---

## 前提

- スキャンコスト抑制のため、必ず `WHERE order_date >= ...` で partition フィルタを付ける
- GA4 連携: BQ Export 開始 = 2026-05-01。それ以前の注文は `user_pseudo_id IS NULL`（リードタイム計算不可）
- channel 分類は `channel_classified` を使う（`email_klaviyo` / `google_paid` / `meta_paid` / `seo_google` / `instagram_organic` / `direct` / `other` 等）
- ⚠ `channel_classified = 'email_klaviyo'` は **実質ゼロ** (Klaviyo の link wrap で UTM 剥がれるため)。Klaviyo 貢献を含むチャネル別売上配分が欲しい場合は **組織標準の [`mart.ec_channel_attribution_weekly`](ec_channel_attribution_examples.md) を参照**。詳細仕様: [`docs/attribution-model.md`](../attribution-model.md)

---

## 1. バナー（utm_content）別 返金率

```sql
SELECT
  utm_campaign, utm_content,
  COUNT(*)                                                 AS orders,
  COUNTIF(is_refunded)                                     AS refunds,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)          AS refund_rate_pct,
  SUM(total_price)                                         AS gross_revenue_yen
FROM `campwill-ec.mart.ec_order_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
  AND utm_content IS NOT NULL
GROUP BY 1, 2
HAVING orders >= 10
ORDER BY refund_rate_pct DESC, orders DESC;
```

---

## 2. チャネル別 リードタイム中央値

```sql
SELECT
  channel_classified,
  COUNT(*)                                                 AS orders,
  APPROX_QUANTILES(lead_time_days, 100)[OFFSET(50)]        AS median_lead_time_days,
  ROUND(AVG(lead_time_days), 1)                             AS avg_lead_time_days,
  COUNTIF(lead_time_bucket = 'instant')                    AS instant,
  COUNTIF(lead_time_bucket = 'same_day')                   AS same_day,
  COUNTIF(lead_time_bucket = 'within_week')                AS within_week,
  COUNTIF(lead_time_bucket = 'within_month')               AS within_month,
  COUNTIF(lead_time_bucket = 'over_month')                 AS over_month
FROM `campwill-ec.mart.ec_order_enriched`
WHERE lead_time_bucket NOT IN ('unmatched_ga4', 'invalid')
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY 1
HAVING orders >= 10
ORDER BY median_lead_time_days ASC;
```

---

## 3. 「初回購入 × チャネル別」返金率

```sql
SELECT
  channel_classified,
  COUNTIF(is_first_order)                                  AS first_orders,
  COUNTIF(is_first_order AND is_refunded)                  AS first_order_refunds,
  ROUND(SAFE_DIVIDE(COUNTIF(is_first_order AND is_refunded),
                    COUNTIF(is_first_order)) * 100, 2)     AS first_order_refund_rate_pct,
  COUNTIF(NOT is_first_order)                              AS repeat_orders,
  ROUND(SAFE_DIVIDE(COUNTIF(NOT is_first_order AND is_refunded),
                    COUNTIF(NOT is_first_order)) * 100, 2) AS repeat_order_refund_rate_pct
FROM `campwill-ec.mart.ec_order_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 180 DAY)
GROUP BY 1
ORDER BY first_orders DESC;
```

---

## 4. デバイス × チャネル の返金率マトリクス

```sql
SELECT
  device_category,
  channel_classified,
  COUNT(*)                                                 AS orders,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)          AS refund_rate_pct,
  ROUND(AVG(total_price), 0)                                AS avg_order_value
FROM `campwill-ec.mart.ec_order_enriched`
WHERE device_category IS NOT NULL
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
GROUP BY 1, 2
HAVING orders >= 20
ORDER BY refund_rate_pct DESC;
```

---

## 5. リードタイムバケット別 AOV と返金率

```sql
SELECT
  lead_time_bucket,
  COUNT(*)                                                 AS orders,
  ROUND(AVG(total_price), 0)                                AS avg_order_value_yen,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)          AS refund_rate_pct
FROM `campwill-ec.mart.ec_order_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
GROUP BY 1
ORDER BY
  CASE lead_time_bucket
    WHEN 'instant'       THEN 1
    WHEN 'same_day'      THEN 2
    WHEN 'within_week'   THEN 3
    WHEN 'within_month'  THEN 4
    WHEN 'over_month'    THEN 5
    ELSE 99
  END;
```

---

## 6. 「first session のチャネル」と「purchase 時のチャネル」のクロス

最初に来た媒体と、最終的に購入した媒体の差（cross-channel journey）。

```sql
SELECT
  ga4_first_medium,
  channel_classified                                       AS purchase_channel,
  COUNT(*)                                                 AS orders,
  ROUND(AVG(total_price), 0)                                AS avg_order_value
FROM `campwill-ec.mart.ec_order_enriched`
WHERE ga4_first_medium IS NOT NULL
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY 1, 2
HAVING orders >= 5
ORDER BY orders DESC;
```

---

## 7. 特定 SKU を含む注文のチャネル内訳

```sql
SELECT
  channel_classified,
  COUNT(*)                                                 AS orders,
  SUM(total_price)                                         AS gross_revenue_yen
FROM `campwill-ec.mart.ec_order_enriched`
WHERE '24IFLU' IN UNNEST(sku_array)  -- 任意の SKU
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 180 DAY)
GROUP BY 1
ORDER BY orders DESC;
```

---

## 8. 返金理由 × チャネルのクロス分析

```sql
SELECT
  refund_reason,
  channel_classified,
  COUNT(*)                                                 AS refunds,
  SUM(refund_amount)                                       AS refund_amount_yen
FROM `campwill-ec.mart.ec_order_enriched`
WHERE is_refunded
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY)
GROUP BY 1, 2
ORDER BY refunds DESC
LIMIT 50;
```

---

## 9. 「N 回目の購入」リピート率と平均間隔

```sql
SELECT
  order_index_per_customer                                 AS order_index,
  COUNT(*)                                                 AS customers,
  ROUND(AVG(days_since_customer_first_order), 1)            AS avg_days_since_first_order,
  ROUND(AVG(total_price), 0)                                AS avg_order_value
FROM `campwill-ec.mart.ec_order_enriched`
WHERE order_index_per_customer <= 10
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY)
GROUP BY 1
ORDER BY 1;
```

---

## 10. 「Mobile × Instagram organic」の挙動

```sql
SELECT
  COUNT(*)                                                 AS orders,
  COUNTIF(is_first_order)                                  AS first_orders,
  COUNTIF(is_refunded)                                     AS refunds,
  ROUND(COUNTIF(is_refunded) / COUNT(*) * 100, 2)          AS refund_rate_pct,
  ROUND(AVG(total_price), 0)                                AS avg_order_value,
  APPROX_QUANTILES(lead_time_days, 100)[OFFSET(50)]        AS median_lead_time_days
FROM `campwill-ec.mart.ec_order_enriched`
WHERE device_category = 'mobile'
  AND channel_classified = 'instagram_organic'
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY);
```

---

## 11. Cross-device 真のリードタイム（crosswalk 経由）

`lead_time_*` は purchase event 時の単一 device しか見ないが、`email_unified_lead_time_*` は同じ `customer_email` の **全 GA4 device の最古 first session** を起点にする。複数デバイス使うユーザーで真のリードタイムが見える。

```sql
SELECT
  channel_classified,
  COUNT(*) AS orders,
  -- 単一 device 視点
  APPROX_QUANTILES(lead_time_days, 100)[OFFSET(50)]              AS median_lt_single_device,
  -- cross-device 視点 (crosswalk 経由)
  APPROX_QUANTILES(email_unified_lead_time_days, 100)[OFFSET(50)] AS median_lt_cross_device,
  ROUND(AVG(email_device_count), 2)                                AS avg_devices_per_customer
FROM `campwill-ec.mart.ec_order_enriched`
WHERE email_unified_lead_time_bucket IN ('instant','same_day','within_week','within_month','over_month')
  AND order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY 1
HAVING orders >= 10
ORDER BY median_lt_cross_device ASC;
```

> **`email_unified_lead_time_bucket` の値**:
> - `instant` / `same_day` / `within_week` / `within_month` / `over_month` — 通常の経過時間
> - `unmatched_email` — 同 email の GA4 紐付けがまだ無い（initial purchase 含めて GA4 未捕捉）
> - `pre_ga4_export` — 注文が 2026-05-01 (GA4 export 開始) より前 → 起点が取れない歴史的注文
> - `session_after_order` — 注文時刻より後の session しか同 email で見つからない（注文に使った device は GA4 未捕捉、その後別 device で再来訪したケース）。**注文後の再エンゲージ** シグナルとしては有用

---

## 列リファレンス（よく使うもの）

| 列 | 意味 |
|---|---|
| `order_date` | 注文日（partition 列、必ず WHERE に） |
| `channel_classified` | チャネル分類（cluster 列、フィルタが効く） |
| `customer_email_hash` | 顧客識別（cluster 列、SHA256 hash 済で PII ゼロ） |
| `is_refunded` / `refund_amount` / `refund_reason` | 返金 |
| `utm_source` / `utm_medium` / `utm_campaign` / `utm_content` | UTM（landing_site fallback 済） |
| `user_pseudo_id` | GA4 user 識別（NULL = GA4 未マッチ） |
| `lead_time_hours` / `lead_time_days` / `lead_time_bucket` | first session → purchase の経過時間 |
| `is_first_order` / `order_index_per_customer` | 顧客単位の購入回数 |
| `customer_first_order_date` / `customer_total_orders_lifetime` | 顧客の生涯履歴 |
| `device_category` / `device_os` / `device_browser` | GA4 デバイス情報 |
| `geo_country` / `geo_region` | GA4 地理 |
| `ga4_first_source` / `ga4_first_medium` / `ga4_first_campaign` | first session のチャネル（注文時 user_pseudo_id の device のみ） |
| `email_unified_first_session_ts` | **同 customer_email の全 GA4 device の最古 first session**（cross-device 起点、crosswalk 経由） |
| `email_device_count` | 同顧客の GA4 で観測された device 数 |
| `email_unified_first_source` / `_medium` / `_campaign` | cross-device 最古 session のチャネル |
| `email_unified_lead_time_hours` / `_days` / `_bucket` | cross-device リードタイム（bucket: instant/same_day/within_week/within_month/over_month + unmatched_email/pre_ga4_export/session_after_order） |
| `sku_array` | 注文に含まれる SKU 配列（`'X' IN UNNEST(sku_array)` で検索） |

---

## GA4 マッチ率の現状

- GA4 BQ Export 開始: **2026-05-01**
- これ以前の注文は `user_pseudo_id IS NULL` → リードタイム計算不可
- GA4 期間内マッチ率: **~93%**（残り 7% は GA4 タグ未送信 / cookie 拒否ユーザー等）
- 古い注文の分析は GA4 列を使わず `channel_classified` と `utm_*` だけで実施可能
