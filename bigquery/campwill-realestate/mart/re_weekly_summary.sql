-- mart.re_weekly_summary: 週次サマリ（経営報告用）
--
-- WoW 比較で 流入 / 問合せ / 案件化 / 成約 の推移を可視化

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_weekly_summary` AS
WITH weekly AS (
  SELECT
    DATE_TRUNC(date, WEEK(MONDAY)) AS week_start,
    SUM(organic_clicks)            AS organic_clicks,
    SUM(inquiry_count)             AS inquiries,
    SUM(new_deal_count)            AS new_deals,
    SUM(won_count)                 AS won,
    SUM(lost_count)                AS lost
  FROM `campwill-realestate.mart.re_lead_funnel`
  GROUP BY week_start
),
with_lag AS (
  SELECT *,
    LAG(organic_clicks) OVER (ORDER BY week_start) AS prev_organic_clicks,
    LAG(inquiries)      OVER (ORDER BY week_start) AS prev_inquiries,
    LAG(new_deals)      OVER (ORDER BY week_start) AS prev_new_deals,
    LAG(won)            OVER (ORDER BY week_start) AS prev_won
  FROM weekly
)
SELECT
  week_start,
  organic_clicks,
  inquiries,
  new_deals,
  won,
  lost,
  ROUND(SAFE_DIVIDE(organic_clicks - prev_organic_clicks, NULLIF(prev_organic_clicks, 0)) * 100, 1) AS clicks_wow_pct,
  ROUND(SAFE_DIVIDE(inquiries - prev_inquiries,           NULLIF(prev_inquiries, 0))      * 100, 1) AS inquiries_wow_pct,
  ROUND(SAFE_DIVIDE(new_deals - prev_new_deals,           NULLIF(prev_new_deals, 0))      * 100, 1) AS new_deals_wow_pct,
  ROUND(SAFE_DIVIDE(won - prev_won,                       NULLIF(prev_won, 0))            * 100, 1) AS won_wow_pct,
  CURRENT_TIMESTAMP() AS generated_at
FROM with_lag
ORDER BY week_start DESC;
