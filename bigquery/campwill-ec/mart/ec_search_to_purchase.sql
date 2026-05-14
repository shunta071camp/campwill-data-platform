-- mart.ec_search_to_purchase: SC クエリ × Shopify 注文の統合
-- SC で来た人が実際に買ったか / どれくらい買ったかを月次集計
-- マッチロジック: SC の url path を抽出 → Shopify landing_site の path 前方一致

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_search_to_purchase` AS
WITH sc_monthly AS (
  SELECT
    DATE_TRUNC(data_date, MONTH)                                   AS year_month,
    query                                                          AS sc_query,
    REGEXP_EXTRACT(url, r'^https?://[^/]+(/.*)$')                  AS sc_path,
    SUM(clicks)                                                    AS sc_clicks,
    SUM(impressions)                                               AS sc_impressions,
    SAFE_DIVIDE(SUM(position * impressions), NULLIF(SUM(impressions), 0)) AS sc_avg_position
  FROM `campwill-ec.searchconsole.sc_history`
  WHERE query IS NOT NULL AND url IS NOT NULL
  GROUP BY year_month, sc_query, sc_path
),
shopify_monthly AS (
  SELECT
    DATE_TRUNC(order_date, MONTH)                                  AS year_month,
    REGEXP_EXTRACT(landing_site, r'^([^?]+)')                       AS shopify_path,
    COUNT(DISTINCT order_id)                                        AS orders,
    SUM(total_price)                                                AS revenue
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE landing_site IS NOT NULL
  GROUP BY year_month, shopify_path
)
SELECT
  s.year_month,
  s.sc_query,
  s.sc_path,
  s.sc_clicks,
  s.sc_impressions,
  ROUND(s.sc_avg_position, 1)                                       AS sc_avg_position,
  COALESCE(SUM(sh.orders), 0)                                       AS matched_orders,
  ROUND(COALESCE(SUM(sh.revenue), 0))                               AS matched_revenue,
  ROUND(SAFE_DIVIDE(COALESCE(SUM(sh.orders), 0), NULLIF(s.sc_clicks, 0)) * 100, 2) AS conversion_rate_pct,
  ROUND(SAFE_DIVIDE(COALESCE(SUM(sh.revenue), 0), NULLIF(s.sc_clicks, 0)))         AS revenue_per_click,
  CURRENT_TIMESTAMP()                                                AS generated_at
FROM sc_monthly s
LEFT JOIN shopify_monthly sh
  ON s.year_month = sh.year_month
  AND STARTS_WITH(sh.shopify_path, s.sc_path)
GROUP BY s.year_month, s.sc_query, s.sc_path, s.sc_clicks, s.sc_impressions, s.sc_avg_position;
