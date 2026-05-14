-- mart.re_seo_inquiry_attribution: SC 検索クエリ → 問合せ への大まかな貢献分析
--
-- 注: tenant-leasing の Tenant.source は自由文 (web/紹介/電話/...)。landing_page カラムは未保持。
-- ページ単位 attribution は厳密には不可。本 mart は次の 2 軸で「SEO の貢献ポテンシャル」を可視化:
--   1. SC の page × query × clicks（直近 30 日）— トラフィック源
--   2. 同期間の web 系 source の問合せ件数（page-level までは下せない）
--
-- 将来的に Tenant に landing_page / utm_source を持たせれば pagewise JOIN が可能になる。

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_seo_inquiry_attribution` AS
WITH sc_30d AS (
  SELECT
    page,
    query,
    SUM(clicks)                                                  AS clicks,
    SUM(impressions)                                             AS impressions,
    SAFE_DIVIDE(SUM(clicks * position), NULLIF(SUM(clicks), 0))  AS avg_position
  FROM `campwill-realestate.raw.re_search_console`
  WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
  GROUP BY page, query
),
web_inquiries_30d AS (
  SELECT COUNT(*) AS web_inquiry_count
  FROM `campwill-realestate.raw.re_tenants`
  WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND (LOWER(IFNULL(source, '')) LIKE '%web%'
         OR LOWER(IFNULL(source, '')) LIKE '%search%'
         OR LOWER(IFNULL(source, '')) LIKE '%seo%'
         OR LOWER(IFNULL(source, '')) LIKE '%krasula%'
         OR LOWER(IFNULL(source, '')) LIKE '%hp%')
)
SELECT
  sc.page,
  sc.query,
  sc.clicks                            AS sc_clicks_30d,
  sc.impressions                       AS sc_impressions_30d,
  ROUND(sc.avg_position, 1)            AS avg_position,
  (SELECT web_inquiry_count FROM web_inquiries_30d) AS total_web_inquiries_30d,
  CURRENT_TIMESTAMP()                  AS generated_at
FROM sc_30d sc
WHERE sc.clicks > 0
ORDER BY sc.clicks DESC
LIMIT 200;
