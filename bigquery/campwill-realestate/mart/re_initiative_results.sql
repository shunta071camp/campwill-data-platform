-- mart.re_initiative_results: 不動産施策の効果検証 (実施日 ±7 日窓で比較)
--
-- 対象: mart.re_initiatives で start_date + 7日 が経過した施策
-- target_metric 別に別 CTE で参照テーブルを切替 (全て mart.re_lead_funnel):
--   - inquiry : SUM(inquiry_count)   per day
--   - deal    : SUM(new_deal_count)  per day
--   - seo     : SUM(organic_clicks)  per day
--
-- 注意:
--   - re_lead_funnel は日次 1 行/全社合計。物件・チャネル別の細分化は別マート
--   - overlap_warning: 実施日 ±3 日に他施策があれば TRUE

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_initiative_results`
PARTITION BY DATE(calculated_at)
AS
WITH targets AS (
  SELECT
    initiative_id,
    target_metric,
    start_date
  FROM `campwill-realestate.mart.re_initiatives`
  WHERE start_date IS NOT NULL
    AND start_date <= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
    AND target_metric IN ('inquiry', 'deal', 'seo')
),
-- ===== Inquiry CTE =====
inquiry_daily AS (
  SELECT date, SUM(inquiry_count) AS value
  FROM `campwill-realestate.mart.re_lead_funnel`
  GROUP BY date
),
inquiry_results AS (
  SELECT
    t.initiative_id,
    'inquiry' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN inquiry_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'inquiry'
  GROUP BY t.initiative_id
),
-- ===== Deal CTE =====
deal_daily AS (
  SELECT date, SUM(new_deal_count) AS value
  FROM `campwill-realestate.mart.re_lead_funnel`
  GROUP BY date
),
deal_results AS (
  SELECT
    t.initiative_id,
    'deal' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN deal_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'deal'
  GROUP BY t.initiative_id
),
-- ===== SEO CTE =====
seo_daily AS (
  SELECT date, SUM(organic_clicks) AS value
  FROM `campwill-realestate.mart.re_lead_funnel`
  GROUP BY date
),
seo_results AS (
  SELECT
    t.initiative_id,
    'seo' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN seo_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'seo'
  GROUP BY t.initiative_id
),
-- ===== Overlap detection =====
overlap_check AS (
  SELECT
    a.initiative_id,
    COUNTIF(b.initiative_id IS NOT NULL AND b.initiative_id != a.initiative_id) > 0 AS overlap_warning,
    STRING_AGG(IF(b.initiative_id != a.initiative_id, b.initiative_id, NULL), ',' ORDER BY b.initiative_id) AS overlap_initiatives
  FROM targets a
  LEFT JOIN targets b
    ON b.start_date BETWEEN DATE_SUB(a.start_date, INTERVAL 3 DAY) AND DATE_ADD(a.start_date, INTERVAL 3 DAY)
  GROUP BY a.initiative_id
),
unified AS (
  SELECT * FROM inquiry_results
  UNION ALL SELECT * FROM deal_results
  UNION ALL SELECT * FROM seo_results
)
SELECT
  u.initiative_id,
  u.target_metric,
  ROUND(u.baseline_value, 2)  AS baseline_value,
  ROUND(u.observed_value, 2)  AS observed_value,
  ROUND(SAFE_DIVIDE(u.observed_value - u.baseline_value, NULLIF(u.baseline_value, 0)) * 100, 1) AS change_pct,
  CASE
    WHEN u.baseline_value IS NULL OR u.observed_value IS NULL                    THEN 'insufficient_data'
    WHEN u.observed_value > u.baseline_value * 1.05                              THEN 'positive'
    WHEN u.observed_value < u.baseline_value * 0.95                              THEN 'negative'
    ELSE                                                                              'neutral'
  END AS effect,
  oc.overlap_warning,
  oc.overlap_initiatives,
  CURRENT_TIMESTAMP() AS calculated_at
FROM unified u
LEFT JOIN overlap_check oc USING (initiative_id);
