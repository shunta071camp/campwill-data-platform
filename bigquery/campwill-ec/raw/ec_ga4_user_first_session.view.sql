-- raw.ec_ga4_user_first_session: user_pseudo_id 別の最初の session_start
--
-- リードタイム計算 (first session → purchase) の起点として使用。
-- 365 日 sliding window。GA4 retention の上限なので、より古い user は first_session_ts が NULL になる可能性。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_ga4_user_first_session` AS
WITH ranked AS (
  SELECT
    user_pseudo_id,
    TIMESTAMP_MICROS(event_timestamp) AS session_ts,
    PARSE_DATE('%Y%m%d', event_date)  AS session_date,
    traffic_source.source             AS source,
    traffic_source.medium             AS medium,
    traffic_source.name               AS campaign,
    device.category                   AS device_category,
    geo.country                       AS geo_country,
    ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp ASC) AS rn
  FROM `campwill-ec.analytics_255235274.events_*`
  WHERE event_name = 'session_start'
    AND _TABLE_SUFFIX BETWEEN
      FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY))
      AND FORMAT_DATE('%Y%m%d', CURRENT_DATE('Asia/Tokyo'))
)
SELECT
  user_pseudo_id,
  session_ts        AS first_session_ts,
  session_date      AS first_session_date,
  source            AS first_source,
  medium            AS first_medium,
  campaign          AS first_campaign,
  device_category   AS first_device_category,
  geo_country       AS first_geo_country
FROM ranked
WHERE rn = 1;
