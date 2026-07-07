# `mart.ec_channel_attribution_weekly` クエリ例

組織標準のチャネル別売上貢献マート。詳細仕様: [`docs/attribution-model.md`](../attribution-model.md)

---

## 列リファレンス

| 列 | 説明 |
|---|---|
| `week_start` | 月曜起点の週開始日 (`DATE_TRUNC(order_date, WEEK(MONDAY))`) |
| `channel` | チャネル分類: `google_paid` / `meta_paid` / `yahoo_paid` / `microsoft_paid` / `seo_google` / `seo_yahoo` / `seo_bing` / `instagram_organic` / `social_youtube` / `email_klaviyo` / `direct` / `other` / `unknown` |
| `orders` | 注文数 (v2.0 から `email_klaviyo` も per-order でカウント) |
| `revenue` | 円。`klaviyo_clicked_within_5d` の注文は email_klaviyo に override 済 |
| `share_pct` | 週内シェア (週合計 = 100%) |
| `ad_cost` | 週次広告費 (円)。paid 4 種のみ、organic/direct/klaviyo は NULL |
| `roas` | revenue / ad_cost (倍率)。例 3.0 = ¥1 投資で ¥3 売上 |
| `cpa` | ad_cost / orders (1注文あたり広告費、円) |
| `net_revenue_after_ad_cost` | revenue - IFNULL(ad_cost, 0)。広告費控除後の取り分 |
| `generated_at` | マート再生成時刻 |

> **⚠ v2.0 (2026-05-19 以降) のみ正確**: Klaviyo Events 取り込み開始日以前は `email_klaviyo` = 0。詳細: [`docs/attribution-model.md`](../attribution-model.md)
> **⚠ Klaviyo / SEO / Direct** の cost は未計上 (subscription cost 未計上、人件費は経営判断として除外)

---

## 1. 直近 8 週のチャネル別売上トレンド

```sql
SELECT
  week_start,
  channel,
  revenue,
  share_pct
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 56 DAY)
ORDER BY week_start DESC, revenue DESC;
```

---

## 2. チャネル × 週 ピボット (横展開)

```sql
SELECT
  week_start,
  ROUND(SUM(IF(channel = "google_paid",       revenue, 0))) AS google_paid,
  ROUND(SUM(IF(channel = "meta_paid",         revenue, 0))) AS meta_paid,
  ROUND(SUM(IF(channel = "yahoo_paid",        revenue, 0))) AS yahoo_paid,
  ROUND(SUM(IF(channel = "microsoft_paid",    revenue, 0))) AS microsoft_paid,
  ROUND(SUM(IF(channel = "seo_google",        revenue, 0))) AS seo_google,
  ROUND(SUM(IF(channel = "seo_yahoo",         revenue, 0))) AS seo_yahoo,
  ROUND(SUM(IF(channel = "seo_bing",          revenue, 0))) AS seo_bing,
  ROUND(SUM(IF(channel = "instagram_organic", revenue, 0))) AS instagram_organic,
  ROUND(SUM(IF(channel = "email_klaviyo",     revenue, 0))) AS email_klaviyo,
  ROUND(SUM(IF(channel = "direct",            revenue, 0))) AS direct,
  ROUND(SUM(IF(channel IN ("other","unknown"), revenue, 0))) AS other_unknown,
  ROUND(SUM(revenue))                                       AS total
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 84 DAY)
GROUP BY week_start
ORDER BY week_start DESC;
```

---

## 3. 月次に集約 (週次 → 月次)

```sql
SELECT
  DATE_TRUNC(week_start, MONTH)                           AS month_start,
  channel,
  SUM(revenue)                                            AS revenue,
  ROUND(SUM(revenue) / SUM(SUM(revenue)) OVER (PARTITION BY DATE_TRUNC(week_start, MONTH)) * 100, 2) AS share_pct
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 180 DAY)
GROUP BY 1, 2
ORDER BY 1 DESC, revenue DESC;
```

---

## 4. Klaviyo の貢献トレンド (週次)

```sql
SELECT
  week_start,
  revenue                                                 AS klaviyo_revenue,
  share_pct                                               AS klaviyo_share_pct,
  klaviyo_uncapped_excess
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE channel = "email_klaviyo"
  AND week_start >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 180 DAY)
ORDER BY week_start DESC;
```

---

## 5. Klaviyo cap が発動した週の監視

```sql
SELECT DISTINCT
  week_start,
  klaviyo_uncapped_excess,
  -- pool 不足の説明: その週の direct + other + unknown 合計
  (SELECT SUM(revenue) FROM `campwill-ec.mart.ec_channel_attribution_weekly` AS t2
   WHERE t2.week_start = t1.week_start AND t2.channel IN ("direct","other","unknown")) AS pool_revenue
FROM `campwill-ec.mart.ec_channel_attribution_weekly` AS t1
WHERE klaviyo_uncapped_excess > 0
ORDER BY week_start DESC;
```

> `klaviyo_uncapped_excess > 0` の週は Klaviyo 売上が表示値より大きい可能性。governance doc の Known Gaps 参照。

---

## 6. 費用対効果 横並び比較 (直近 4 週、paid 4 種)

```sql
SELECT
  channel,
  SUM(orders)                                    AS orders,
  SUM(revenue)                                   AS revenue,
  SUM(ad_cost)                                   AS ad_cost,
  ROUND(SAFE_DIVIDE(SUM(revenue), SUM(ad_cost)), 2) AS roas,
  CAST(ROUND(SAFE_DIVIDE(SUM(ad_cost), SUM(orders))) AS INT64) AS cpa,
  SUM(net_revenue_after_ad_cost)                 AS net_after_ad
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start >= DATE_SUB(DATE_TRUNC(CURRENT_DATE("Asia/Tokyo"), WEEK(MONDAY)), INTERVAL 21 DAY)
  AND channel IN ("google_paid","meta_paid","yahoo_paid","microsoft_paid")
GROUP BY channel
ORDER BY net_after_ad DESC;
```

---

## 7. 全チャネル + ROAS + 残高ランキング (1 週分)

```sql
SELECT
  channel,
  orders,
  revenue,
  ad_cost,
  roas,
  cpa,
  net_revenue_after_ad_cost
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start = DATE_TRUNC(CURRENT_DATE("Asia/Tokyo"), WEEK(MONDAY)) - INTERVAL 7 DAY
ORDER BY net_revenue_after_ad_cost DESC;
```

---

## 8. 有料広告 vs 無料 (organic+klaviyo+direct) の構成比

```sql
WITH categorized AS (
  SELECT
    week_start,
    CASE
      WHEN channel IN ("google_paid","meta_paid","yahoo_paid","microsoft_paid") THEN "paid"
      WHEN channel = "email_klaviyo"                                              THEN "klaviyo"
      WHEN channel LIKE "seo_%" OR channel IN ("instagram_organic","social_youtube") THEN "organic"
      ELSE "direct_unknown"
    END AS category,
    revenue
  FROM `campwill-ec.mart.ec_channel_attribution_weekly`
  WHERE week_start >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 84 DAY)
)
SELECT
  week_start,
  ROUND(SUM(IF(category = "paid",           revenue, 0))) AS paid,
  ROUND(SUM(IF(category = "klaviyo",        revenue, 0))) AS klaviyo,
  ROUND(SUM(IF(category = "organic",        revenue, 0))) AS organic,
  ROUND(SUM(IF(category = "direct_unknown", revenue, 0))) AS direct_unknown,
  ROUND(SUM(revenue))                                     AS total
FROM categorized
GROUP BY week_start
ORDER BY week_start DESC;
```

---

## 9. Klaviyo click → 購入の per-order 詳細 (v2.0 デバッグ用)

```sql
SELECT
  order_date,
  customer_email_hash,
  channel_classified                 AS shopify_last_touch,
  total_price,
  klaviyo_clicked_within_5d
FROM `campwill-ec.mart.ec_order_enriched`
WHERE order_date >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL 30 DAY)
  AND klaviyo_clicked_within_5d
ORDER BY order_date DESC
LIMIT 50;
```

→ 出力: 過去 30日で Klaviyo click 経由と判定された注文一覧。各注文の Shopify last-touch も併記 (どの channel から奪われたかを確認できる)。

---

## 10. 合計整合性の自己チェック (回帰テスト)

```sql
WITH att AS (
  SELECT week_start, SUM(revenue) AS att_total
  FROM `campwill-ec.mart.ec_channel_attribution_weekly`
  GROUP BY week_start
),
oe AS (
  SELECT DATE_TRUNC(order_date, WEEK(MONDAY)) AS week_start, SUM(total_price) AS oe_total
  FROM `campwill-ec.mart.ec_order_enriched`
  GROUP BY 1
)
SELECT
  att.week_start,
  att.att_total,
  oe.oe_total,
  ROUND(att.att_total - oe.oe_total) AS delta
FROM att JOIN oe USING (week_start)
WHERE ABS(att.att_total - oe.oe_total) > 1
ORDER BY week_start DESC;
```

> 期待: 結果 0 行 (差 1 円以下の丸め誤差のみ)
