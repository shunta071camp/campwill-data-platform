-- mart.re_case_pipeline: 現時点のパイプライン状態スナップショット
--
-- status 別の進行中案件件数 / 提案賃料合計 / 平均経過日数 / 担当者別

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_case_pipeline` AS
WITH active_deals AS (
  SELECT *
  FROM `campwill-realestate.raw.re_deals`
  WHERE status NOT IN ('CONTRACTED', 'LOST')
)
SELECT
  status,
  COUNT(*)                                                                          AS deal_count,
  SUM(IFNULL(proposed_rent, 0))                                                     AS total_proposed_rent_yen,
  ROUND(AVG(DATE_DIFF(CURRENT_DATE('Asia/Tokyo'),
                      DATE(created_at, 'Asia/Tokyo'), DAY)), 1)                     AS avg_age_days,
  COUNT(DISTINCT assigned_user_id)                                                  AS distinct_assignees,
  STRING_AGG(DISTINCT CAST(assigned_user_id AS STRING)
             ORDER BY CAST(assigned_user_id AS STRING))                             AS assigned_user_ids,
  CURRENT_TIMESTAMP()                                                               AS generated_at
FROM active_deals
GROUP BY status
ORDER BY
  CASE status
    WHEN 'INQUIRY'         THEN 1
    WHEN 'VIEWING_PLANNED' THEN 2
    WHEN 'VIEWED'          THEN 3
    WHEN 'APPLIED'         THEN 4
    WHEN 'SCREENING'       THEN 5
    WHEN 'CONTRACTING'     THEN 6
    ELSE 99
  END;
