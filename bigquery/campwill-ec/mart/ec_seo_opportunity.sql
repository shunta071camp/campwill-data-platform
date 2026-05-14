-- mart.ec_seo_opportunity: SC × Rakko 統合で SEO 機会を金額化
--
-- 各クエリについて:
--  - SC: 直近 30 日 vs 前年同期の clicks / 順位
--  - Rakko: 月間 search volume / SEO 難易度 / CPC
--
-- 出力カラム:
--  - keyword, volume, difficulty
--  - sc_recent_clicks, sc_baseline_clicks, click_decline
--  - sc_recent_position, sc_baseline_position
--  - opportunity_type: 損失 / 機会 / 維持
--  - estimated_monthly_loss_yen: (旧 clicks - 新 clicks) × 推定 CV率(1.5%) × 平均単価
--
-- 注: 平均単価は raw.ec_shopify_orders から動的算出 (AOV)
-- CV率は仮定 1.5% (Shopify 業界平均)

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_seo_opportunity` AS
WITH aov AS (
  -- 直近 30 日の平均注文単価
  SELECT
    ROUND(AVG(total_price)) AS avg_order_value,
    1.5 AS cv_rate_pct
  FROM `campwill-ec.raw.ec_shopify_orders`
  WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
),
sc_recent AS (
  -- 直近 30 日の SC データ
  SELECT
    query                                                                                AS keyword,
    SUM(clicks)                                                                          AS clicks,
    SUM(impressions)                                                                     AS impressions,
    SAFE_DIVIDE(SUM(position * impressions), NULLIF(SUM(impressions), 0))                AS avg_position
  FROM `campwill-ec.searchconsole.sc_history`
  WHERE data_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
    AND query IS NOT NULL
  GROUP BY keyword
),
sc_baseline AS (
  -- 前年同期 (30-60 日前 same month) の SC データ
  SELECT
    query                                                                                AS keyword,
    SUM(clicks)                                                                          AS clicks,
    SAFE_DIVIDE(SUM(position * impressions), NULLIF(SUM(impressions), 0))                AS avg_position
  FROM `campwill-ec.searchconsole.sc_history`
  WHERE data_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY)
                      AND DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 335 DAY)
    AND query IS NOT NULL
  GROUP BY keyword
),
rakko AS (
  -- 直近の Rakko volume (ku-bell.com 自社が獲得しているキーワードのみ)
  SELECT
    keyword,
    MAX(search_volume)  AS search_volume,
    MAX(seo_difficulty) AS seo_difficulty,
    MAX(cpc)            AS cpc
  FROM `campwill-ec.raw.rakko_inflow_keywords`
  WHERE target_url = 'https://ku-bell.com/'
    AND fetched_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
  GROUP BY keyword
)
SELECT
  COALESCE(r.keyword, rk.keyword)                                                       AS keyword,
  rk.search_volume,
  rk.seo_difficulty,
  rk.cpc,
  IFNULL(r.clicks, 0)                                                                   AS sc_recent_clicks,
  IFNULL(b.clicks, 0)                                                                   AS sc_baseline_clicks,
  IFNULL(b.clicks, 0) - IFNULL(r.clicks, 0)                                             AS click_decline,
  ROUND(r.avg_position, 1)                                                              AS sc_recent_position,
  ROUND(b.avg_position, 1)                                                              AS sc_baseline_position,
  CASE
    WHEN r.clicks IS NULL AND rk.search_volume > 0                                      THEN 'new_opportunity'
    WHEN IFNULL(b.clicks, 0) - IFNULL(r.clicks, 0) >= 100                               THEN 'declining_loss'
    WHEN IFNULL(b.clicks, 0) - IFNULL(r.clicks, 0) >= 30                                THEN 'declining_minor'
    WHEN r.avg_position <= 3 AND r.clicks < rk.search_volume * 0.02                     THEN 'top3_low_ctr'
    WHEN r.clicks > IFNULL(b.clicks, 0)                                                 THEN 'growing'
    ELSE                                                                                     'stable'
  END                                                                                    AS opportunity_type,
  ROUND(
    GREATEST(IFNULL(b.clicks, 0) - IFNULL(r.clicks, 0), 0)
    * 0.015                                                                             -- CV率 1.5% (仮定)
    * (SELECT avg_order_value FROM aov)
  )                                                                                      AS estimated_monthly_loss_yen,
  CURRENT_TIMESTAMP()                                                                    AS generated_at
FROM sc_recent r
FULL OUTER JOIN sc_baseline b USING (keyword)
LEFT JOIN rakko rk USING (keyword)
WHERE COALESCE(r.keyword, b.keyword, rk.keyword) IS NOT NULL;
