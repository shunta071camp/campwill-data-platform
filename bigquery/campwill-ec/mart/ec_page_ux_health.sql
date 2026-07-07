-- mart.ec_page_ux_health: ページ別 UX 健康度スコア (GA4 BQ Export 経由、30日集計)
--
-- ソース: campwill-ec.analytics_255235274.events_* (GA4 BQ Export)
--   events: page_view / user_engagement / scroll / view_item / add_to_cart / purchase
--   GA4 export 開始: 2026-05-01。それ以前は 0 行。
--
-- per page_url (query string 除去後) で集計:
--   - エンゲージメント率 / 平均滞在時間 / スクロール 90% 到達率
--   - 直帰率 (entrance + non-engaged)
--   - 商品ファネル: view_item / add_to_cart / purchase
--   - UX スコア (高=良): engagement 40% + scroll 30% + (100-bounce) 30%
--
-- 注意:
--   - Clarity の dead/rage click rate は取れない (GA4 範囲外)。それは mart.ec_ux_health (Browser 別) で別途参照
--   - sessions < 30 は信頼性低のため除外
--   - Web Vitals (LCP/CLS/INP) は現状未送信、別途 Shopify theme 仕込み後に追加列予定

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_page_ux_health` AS
WITH page_events AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date)                  AS event_date,
    event_name,
    user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')      AS ga_session_id,
    REGEXP_REPLACE(
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location'),
      r'\?.*$', ''
    )                                                  AS page_url,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_title')         AS page_title,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'engagement_time_msec') AS engagement_ms,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'session_engaged')    AS session_engaged_str,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'entrances')          AS entrances,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'percent_scrolled')   AS percent_scrolled,
    device.category                                                                          AS device_category
  FROM `campwill-ec.analytics_255235274.events_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY))
                          AND FORMAT_DATE('%Y%m%d', CURRENT_DATE('Asia/Tokyo'))
    AND event_name IN ('page_view','user_engagement','scroll','view_item','add_to_cart','purchase')
),
per_page_session AS (
  -- 1 row per (page_url, user_session)
  SELECT
    page_url,
    ANY_VALUE(page_title)                                                  AS page_title,
    user_pseudo_id,
    ga_session_id,
    COUNTIF(event_name = 'page_view')                                      AS pageviews_in_session,
    SUM(IF(event_name = 'user_engagement', engagement_ms, 0))              AS engagement_ms_on_page,
    MAX(IF(event_name = 'page_view' AND entrances = 1, 1, 0))              AS is_entrance,
    MAX(IF(event_name = 'page_view' AND session_engaged_str = '1', 1, 0)) AS is_engaged_session,
    MAX(IF(event_name = 'scroll' AND percent_scrolled >= 90, 1, 0))        AS reached_90_scroll,
    MAX(IF(event_name = 'scroll', percent_scrolled, NULL))                 AS max_scroll_pct,
    MAX(IF(event_name = 'view_item',    1, 0))                             AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',  1, 0))                             AS added_to_cart,
    MAX(device_category)                                                   AS device_category
  FROM page_events
  WHERE page_url IS NOT NULL
    AND ga_session_id IS NOT NULL
  GROUP BY page_url, user_pseudo_id, ga_session_id
),
session_purchases AS (
  -- セッション横断: 購入したセッションを特定 (purchase event は /checkout 等で発火するので session 単位で吸収)
  SELECT DISTINCT user_pseudo_id, ga_session_id
  FROM page_events
  WHERE event_name = 'purchase'
),
per_page_session_with_purchase AS (
  SELECT
    pps.*,
    IF(sp.user_pseudo_id IS NOT NULL, 1, 0) AS session_purchased
  FROM per_page_session pps
  LEFT JOIN session_purchases sp USING (user_pseudo_id, ga_session_id)
),
ga_agg AS (
  SELECT
    page_url,
    ANY_VALUE(page_title)                                                                      AS page_title,
    COUNT(*)                                                                                   AS sessions,
    SUM(pageviews_in_session)                                                                  AS pageviews,
    SUM(is_entrance)                                                                           AS entrances,
    SUM(is_engaged_session)                                                                    AS engaged_sessions,
    SUM(engagement_ms_on_page)                                                                 AS engagement_ms_sum,
    SUM(reached_90_scroll)                                                                     AS reached_90_scroll_sessions,
    AVG(max_scroll_pct)                                                                        AS avg_max_scroll_pct_raw,
    SUM(IF(is_entrance = 1 AND is_engaged_session = 0, 1, 0))                                  AS bounced_sessions,
    SUM(viewed_item)                                                                           AS view_item_count,
    SUM(added_to_cart)                                                                         AS add_to_cart_count,
    SUM(session_purchased)                                                                     AS sessions_with_purchase
  FROM per_page_session_with_purchase
  GROUP BY page_url
),
crux_latest_per_url AS (
  -- 各 URL の最新 collection_period (28日 rolling の最終日) の Web Vitals を取得
  SELECT
    url AS page_url,
    lcp_p75_ms,
    ROUND(lcp_good_density  * 100, 1) AS lcp_good_pct,
    ROUND(lcp_poor_density  * 100, 1) AS lcp_poor_pct,
    inp_p75_ms,
    ROUND(inp_good_density  * 100, 1) AS inp_good_pct,
    ROUND(inp_poor_density  * 100, 1) AS inp_poor_pct,
    cls_p75,
    ROUND(cls_good_density  * 100, 1) AS cls_good_pct,
    ROUND(cls_poor_density  * 100, 1) AS cls_poor_pct,
    fcp_p75_ms,
    ttfb_p75_ms
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY url, form_factor ORDER BY collection_period_end DESC) AS rn
    FROM `campwill-ec.raw.ec_crux_history_latest`
    WHERE form_factor = 'ALL_FORM_FACTORS'
  )
  WHERE rn = 1
)
SELECT
  g.page_url,
  g.page_title,
  g.sessions,
  g.pageviews,
  g.entrances,
  g.engaged_sessions,
  ROUND(SAFE_DIVIDE(g.engaged_sessions,            g.sessions) * 100, 2) AS engagement_rate_pct,
  ROUND(SAFE_DIVIDE(g.engagement_ms_sum,           g.sessions) / 1000, 1) AS avg_engagement_sec,
  ROUND(SAFE_DIVIDE(g.reached_90_scroll_sessions,  g.sessions) * 100, 2) AS scroll_90_rate_pct,
  ROUND(g.avg_max_scroll_pct_raw, 2)                                       AS avg_max_scroll_pct,
  g.bounced_sessions,
  ROUND(SAFE_DIVIDE(g.bounced_sessions, NULLIF(g.entrances, 0)) * 100, 2)  AS bounce_rate_pct,
  g.view_item_count,
  g.add_to_cart_count,
  g.sessions_with_purchase,
  ROUND(SAFE_DIVIDE(g.sessions_with_purchase, g.sessions) * 100, 3)        AS cv_rate_pct,
  -- ===== CrUX (Web Vitals) =====
  c.lcp_p75_ms,
  c.lcp_good_pct,
  c.lcp_poor_pct,
  c.inp_p75_ms,
  c.inp_good_pct,
  c.inp_poor_pct,
  c.cls_p75,
  c.cls_good_pct,
  c.cls_poor_pct,
  c.fcp_p75_ms,
  c.ttfb_p75_ms,
  -- ===== Page UX score =====
  -- 旧: engagement 40 + scroll 30 + (100-bounce) 30
  -- 新: engagement 30 + scroll 20 + (100-bounce) 20 + web_vitals 30
  -- web_vitals = (lcp_good + inp_good + cls_good) / 3 (CrUX 無い URL は旧式)
  ROUND(
    CASE
      WHEN c.lcp_good_pct IS NOT NULL AND c.inp_good_pct IS NOT NULL AND c.cls_good_pct IS NOT NULL THEN
        COALESCE(SAFE_DIVIDE(g.engaged_sessions, g.sessions) * 100, 0) * 0.3
        + COALESCE(SAFE_DIVIDE(g.reached_90_scroll_sessions, g.sessions) * 100, 0) * 0.2
        + (100 - COALESCE(SAFE_DIVIDE(g.bounced_sessions, NULLIF(g.entrances, 0)) * 100, 50)) * 0.2
        + ((c.lcp_good_pct + c.inp_good_pct + c.cls_good_pct) / 3) * 0.3
      ELSE
        COALESCE(SAFE_DIVIDE(g.engaged_sessions, g.sessions) * 100, 0) * 0.4
        + COALESCE(SAFE_DIVIDE(g.reached_90_scroll_sessions, g.sessions) * 100, 0) * 0.3
        + (100 - COALESCE(SAFE_DIVIDE(g.bounced_sessions, NULLIF(g.entrances, 0)) * 100, 50)) * 0.3
    END, 1
  ) AS page_ux_score,
  IF(c.lcp_p75_ms IS NOT NULL, TRUE, FALSE) AS has_crux,
  CURRENT_TIMESTAMP() AS generated_at
FROM ga_agg g
LEFT JOIN crux_latest_per_url c USING (page_url)
WHERE g.sessions >= 30
ORDER BY pageviews DESC;
