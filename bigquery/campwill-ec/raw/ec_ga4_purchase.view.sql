-- raw.ec_ga4_purchase: GA4 events_* から purchase event を抽出した VIEW
--
-- Shopify との JOIN キー: transaction_id (= Shopify order_id 数字 13 桁、サンプル確認済)
-- 例: 7225766183105 == Shopify order_id
-- 365 日 sliding window (GA4 retention 上限を意識)

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_ga4_purchase` AS
SELECT
  PARSE_DATE('%Y%m%d', event_date)                                                   AS event_date,
  TIMESTAMP_MICROS(event_timestamp)                                                  AS event_ts,
  user_pseudo_id,
  (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')  AS ga_session_id,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'transaction_id') AS transaction_id,
  ecommerce.transaction_id                                                           AS ecommerce_transaction_id,
  ecommerce.purchase_revenue                                                         AS purchase_revenue,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location')  AS page_location,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_referrer')  AS page_referrer,
  collected_traffic_source.manual_source                                             AS session_source,
  collected_traffic_source.manual_medium                                             AS session_medium,
  collected_traffic_source.manual_campaign_name                                      AS session_campaign,
  collected_traffic_source.manual_content                                            AS session_content,
  device.category                                                                    AS device_category,
  device.operating_system                                                            AS device_os,
  device.web_info.browser                                                            AS device_browser,
  geo.country                                                                        AS geo_country,
  geo.region                                                                         AS geo_region
FROM `campwill-ec.analytics_255235274.events_*`
WHERE event_name = 'purchase'
  AND _TABLE_SUFFIX BETWEEN
    FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 365 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE('Asia/Tokyo'));
