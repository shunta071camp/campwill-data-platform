-- mart.ec_competitor_gap: 競合のみが獲得していて自社が取れていないキーワード
--
-- 各キーワードについて:
--  - 競合何社が取れているか
--  - 自社 (ku-bell.com) は取れているか
--  - 月間 search volume / SEO 難易度
--  - 競合社名 (誰が取れているか)
--
-- ku-bell.com の rank または etv が NULL = 自社未獲得とみなす

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_competitor_gap` AS
WITH latest AS (
  -- 最新の取得日のみ使う
  SELECT MAX(fetched_date) AS d FROM `campwill-ec.raw.rakko_inflow_keywords`
),
self_kw AS (
  SELECT DISTINCT keyword
  FROM `campwill-ec.raw.rakko_inflow_keywords`
  WHERE target_url = 'https://ku-bell.com/'
    AND fetched_date = (SELECT d FROM latest)
),
competitor_kw AS (
  SELECT
    keyword,
    MAX(search_volume)   AS search_volume,
    MAX(seo_difficulty)  AS seo_difficulty,
    MAX(cpc)             AS cpc,
    COUNT(DISTINCT domain) AS competitor_count,
    STRING_AGG(DISTINCT domain ORDER BY domain) AS competitors
  FROM `campwill-ec.raw.rakko_inflow_keywords`
  WHERE target_url != 'https://ku-bell.com/'
    AND fetched_date = (SELECT d FROM latest)
    AND keyword IS NOT NULL AND keyword != ''
  GROUP BY keyword
)
SELECT
  c.keyword,
  c.search_volume,
  c.seo_difficulty,
  c.cpc,
  c.competitor_count,
  c.competitors,
  -- 推定機会: vol × CTR(top3=10%) × CV率(1.5%) × AOV
  ROUND(
    IFNULL(c.search_volume, 0) * 0.10 * 0.015 *
    (SELECT ROUND(AVG(total_price)) FROM `campwill-ec.raw.ec_shopify_orders`
     WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY))
  ) AS estimated_monthly_opportunity_yen,
  CURRENT_TIMESTAMP() AS generated_at
FROM competitor_kw c
LEFT JOIN self_kw s USING (keyword)
WHERE s.keyword IS NULL                                  -- 自社未獲得
  AND c.search_volume IS NOT NULL AND c.search_volume > 0
  AND c.competitor_count >= 2                            -- 2社以上の競合 = 業界トレンド
  AND c.search_volume BETWEEN 100 AND 30000              -- 巨大すぎる無関係クエリ除外
  AND c.seo_difficulty IS NOT NULL                       -- 競合性データあるもののみ
ORDER BY c.search_volume DESC, c.competitor_count DESC;
