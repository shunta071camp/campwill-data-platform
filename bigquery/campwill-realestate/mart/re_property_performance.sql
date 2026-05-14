-- mart.re_property_performance: 物件別のパフォーマンス
--
-- 各物件の: 案件数 / 内見数 / 成約数 / 失注数 / 進行中 / 平均成約リードタイム / 募集経過日数

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_property_performance` AS
WITH deal_stats AS (
  SELECT
    property_id,
    COUNT(*)                                                     AS total_deals,
    COUNTIF(status = 'CONTRACTED')                               AS won_deals,
    COUNTIF(status = 'LOST')                                     AS lost_deals,
    COUNTIF(status NOT IN ('CONTRACTED', 'LOST'))                AS active_deals,
    AVG(IF(status = 'CONTRACTED',
           DATE_DIFF(DATE(updated_at), DATE(created_at), DAY),
           NULL))                                                AS avg_lead_time_days
  FROM `campwill-realestate.raw.re_deals`
  GROUP BY property_id
),
viewing_stats AS (
  SELECT property_id, COUNT(*) AS total_viewings
  FROM `campwill-realestate.raw.re_activities`
  WHERE activity_type = 'VIEWING'
  GROUP BY property_id
)
SELECT
  p.id                                                            AS property_id,
  p.property_name,
  p.property_type,
  p.listing_status,
  p.rent_amount,
  p.owner_id,
  IFNULL(ds.total_deals, 0)                                       AS total_deals,
  IFNULL(ds.won_deals, 0)                                         AS won_deals,
  IFNULL(ds.lost_deals, 0)                                        AS lost_deals,
  IFNULL(ds.active_deals, 0)                                      AS active_deals,
  ROUND(ds.avg_lead_time_days, 1)                                 AS avg_lead_time_days,
  IFNULL(vs.total_viewings, 0)                                    AS total_viewings,
  ROUND(SAFE_DIVIDE(ds.won_deals, ds.total_deals) * 100, 1)       AS win_rate_pct,
  DATE_DIFF(CURRENT_DATE('Asia/Tokyo'),
            DATE(p.created_at, 'Asia/Tokyo'), DAY)                AS days_listed,
  CURRENT_TIMESTAMP()                                             AS generated_at
FROM `campwill-realestate.raw.re_properties` p
LEFT JOIN deal_stats     ds ON p.id = ds.property_id
LEFT JOIN viewing_stats  vs ON p.id = vs.property_id
ORDER BY total_deals DESC, days_listed DESC;
