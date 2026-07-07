-- mart.ec_initiative_results: 施策の効果検証 (実施日 ±7 日窓で比較)
--
-- 対象: mart.ec_initiatives で start_date + 7日 が経過した施策
-- target_metric 別に別 CTE で参照テーブルを切替、最後に UNION ALL で統一スキーマ:
--   - revenue       : mart.ec_daily_pnl の SUM(revenue)
--   - cvr (代理)    : mart.ec_channel_roi の SUM(orders) (日次注文数を CVR 代理として)
--   - klaviyo_cv    : mart.ec_klaviyo_conversion の SUM(shopify_orders)
--
-- 注意:
--   - 真の CVR (orders/sessions) は GA4 sessions 必要。初版は orders 比較で代用
--   - overlap_warning: 実施日 ±3 日に他施策があれば TRUE (寄与分離注意の喚起)
--   - 結果は再生成型 (毎日 SQ で TRUNCATE+INSERT)
--
-- 新 metric 追加時: 同じ列構成で CTE 1 つ追加 (30〜50 行) + UNION ALL に追記

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_initiative_results`
PARTITION BY DATE(calculated_at)
AS
WITH targets AS (
  -- 実施日 + 7 日以上経過した施策のみ
  SELECT
    initiative_id,
    target_metric,
    start_date
  FROM `campwill-ec.mart.ec_initiatives`
  WHERE start_date IS NOT NULL
    AND start_date <= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
    AND target_metric IN ('revenue', 'cvr', 'klaviyo_cv')
),
-- ===== Revenue CTE =====
-- 注意: mart.ec_daily_pnl は line-grain (1 order × 1 SKU = 1 row) で `revenue` 列は
-- order.total_price を全 line に複製している設計。SUM(revenue) すると line 数分過大集計 (avg x1.35)。
-- → order_id で DISTINCT してから SUM
revenue_daily AS (
  SELECT order_date AS date, SUM(revenue) AS value
  FROM (
    SELECT order_date, order_id, ANY_VALUE(revenue) AS revenue
    FROM `campwill-ec.mart.ec_daily_pnl`
    GROUP BY order_date, order_id
  )
  GROUP BY order_date
),
revenue_results AS (
  SELECT
    t.initiative_id,
    'revenue' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN revenue_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'revenue'
  GROUP BY t.initiative_id
),
-- ===== CVR CTE (代理: 日次注文数) =====
cvr_daily AS (
  SELECT date, SUM(orders) AS value
  FROM `campwill-ec.mart.ec_channel_roi`
  GROUP BY date
),
cvr_results AS (
  SELECT
    t.initiative_id,
    'cvr' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN cvr_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'cvr'
  GROUP BY t.initiative_id
),
-- ===== Klaviyo CV CTE =====
klaviyo_daily AS (
  SELECT DATE(sent_at, 'Asia/Tokyo') AS date, SUM(shopify_orders) AS value
  FROM `campwill-ec.mart.ec_klaviyo_conversion`
  GROUP BY 1
),
klaviyo_results AS (
  SELECT
    t.initiative_id,
    'klaviyo_cv' AS target_metric,
    AVG(IF(d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY)
                     AND DATE_SUB(t.start_date, INTERVAL 1 DAY), d.value, NULL)) AS baseline_value,
    AVG(IF(d.date BETWEEN t.start_date
                     AND DATE_ADD(t.start_date, INTERVAL 6 DAY), d.value, NULL)) AS observed_value
  FROM targets t
  LEFT JOIN klaviyo_daily d
    ON d.date BETWEEN DATE_SUB(t.start_date, INTERVAL 7 DAY) AND DATE_ADD(t.start_date, INTERVAL 6 DAY)
  WHERE t.target_metric = 'klaviyo_cv'
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
  SELECT * FROM revenue_results
  UNION ALL SELECT * FROM cvr_results
  UNION ALL SELECT * FROM klaviyo_results
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
