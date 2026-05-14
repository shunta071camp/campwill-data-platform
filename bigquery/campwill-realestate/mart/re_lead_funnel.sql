-- mart.re_lead_funnel: 日次ファネル（オーガニック流入 → 問合せ → 案件化 → 成約/失注）
--
-- 注: GA4 BQ Export が来たら、ga4_visits CTE を追加して訪問数列を入れる予定（現状は SC のみ）

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_lead_funnel` AS
WITH days AS (
  SELECT d AS date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY),
    CURRENT_DATE('Asia/Tokyo')
  )) AS d
),
sc_clicks AS (
  SELECT date, SUM(clicks) AS organic_clicks, SUM(impressions) AS organic_impressions
  FROM `campwill-realestate.raw.re_search_console`
  GROUP BY date
),
inquiries AS (
  -- Tenant 新規登録 = 問い合わせ発生（tenant-leasing では Inquiry テーブルが無く Tenant 直接登録）
  SELECT DATE(created_at, 'Asia/Tokyo') AS d, COUNT(*) AS inquiry_count
  FROM `campwill-realestate.raw.re_tenants`
  GROUP BY d
),
deals_created AS (
  -- Deal 作成 = 案件化（テナント × 物件で具体化した時点）
  SELECT DATE(created_at, 'Asia/Tokyo') AS d, COUNT(*) AS new_deal_count
  FROM `campwill-realestate.raw.re_deals`
  GROUP BY d
),
deals_won AS (
  SELECT DATE(updated_at, 'Asia/Tokyo') AS d, COUNT(*) AS won_count
  FROM `campwill-realestate.raw.re_deals`
  WHERE status = 'CONTRACTED'
  GROUP BY d
),
deals_lost AS (
  SELECT DATE(updated_at, 'Asia/Tokyo') AS d, COUNT(*) AS lost_count
  FROM `campwill-realestate.raw.re_deals`
  WHERE status = 'LOST'
  GROUP BY d
)
SELECT
  d.date,
  IFNULL(sc.organic_clicks, 0)                                      AS organic_clicks,
  IFNULL(sc.organic_impressions, 0)                                 AS organic_impressions,
  IFNULL(i.inquiry_count, 0)                                        AS inquiry_count,
  IFNULL(dc.new_deal_count, 0)                                      AS new_deal_count,
  IFNULL(dw.won_count, 0)                                           AS won_count,
  IFNULL(dl.lost_count, 0)                                          AS lost_count,
  ROUND(SAFE_DIVIDE(IFNULL(i.inquiry_count, 0), NULLIF(sc.organic_clicks, 0)) * 100, 2)        AS click_to_inquiry_pct,
  ROUND(SAFE_DIVIDE(IFNULL(dc.new_deal_count, 0), NULLIF(i.inquiry_count, 0)) * 100, 2)        AS inquiry_to_deal_pct,
  ROUND(SAFE_DIVIDE(IFNULL(dw.won_count, 0), NULLIF(dc.new_deal_count, 0)) * 100, 2)           AS deal_win_pct,
  CURRENT_TIMESTAMP() AS generated_at
FROM days d
LEFT JOIN sc_clicks sc       USING (date)
LEFT JOIN inquiries i        ON d.date = i.d
LEFT JOIN deals_created dc   ON d.date = dc.d
LEFT JOIN deals_won dw       ON d.date = dw.d
LEFT JOIN deals_lost dl      ON d.date = dl.d
ORDER BY d.date DESC;
