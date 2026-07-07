-- raw.ec_meta_ads VIEW: Meta (Facebook) Ads データ統合
--
-- 履歴データ (〜2026-06-29): BQ Data Transfer Service (BQ DTS) 経由の facebook_ads.AdInsights / AdInsightsActions
--   → BQ DTS は 2026-07 に token 期限切れで停止 (KUBELL-1085)、以後は非活性だがデータは保持
-- 新データ (2026-06-30〜): n8n workflow (meta-ads-daily) 経由の raw.ec_meta_ads_insights / _actions
--   → Meta Marketing API 直叩き、System User token を raw.oauth_tokens で管理
--
-- 下流 mart は本 view を通じて透過的に読める (ec_channel_roi / ec_channel_attribution_weekly は cost 列のみ使用)。
-- 詳細: KUBELL-1085, KUBELL-1095 epic

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_meta_ads` AS
WITH
-- === 履歴 (BQ DTS 経由、2026-06-29 以前) ===
legacy_actions AS (
  SELECT
    DateStart,
    AdId,
    SAFE_CAST(SUM(SAFE_CAST(Action1dClick AS NUMERIC)) AS FLOAT64) AS click_actions
  FROM `campwill-ec.facebook_ads.AdInsightsActions`
  GROUP BY DateStart, AdId
),
legacy AS (
  SELECT
    i.DateStart                                          AS date,
    i.CampaignId                                         AS campaign_id,
    i.CampaignName                                       AS campaign_name,
    i.AdSetId                                            AS ad_set_id,
    SAFE_CAST(i.Impressions AS INT64)                    AS impressions,
    SAFE_CAST(i.Clicks AS INT64)                         AS clicks,
    CAST(ROUND(SAFE_CAST(i.Spend AS NUMERIC)) AS INT64)  AS cost,
    COALESCE(a.click_actions, 0)                         AS conversions,
    CAST(NULL AS INT64)                                  AS revenue
  FROM `campwill-ec.facebook_ads.AdInsights` i
  LEFT JOIN legacy_actions a
    ON i.DateStart = a.DateStart AND i.AdId = a.AdId
),
-- === 新 (n8n workflow 経由、2026-06-30 以降) ===
new_actions AS (
  SELECT
    DateStart,
    AdId,
    SAFE_CAST(SUM(SAFE_CAST(Action1dClick AS NUMERIC)) AS FLOAT64) AS click_actions
  FROM `campwill-ec.raw.ec_meta_ads_insights_actions`
  GROUP BY DateStart, AdId
),
new_insights AS (
  SELECT
    i.DateStart                                          AS date,
    i.CampaignId                                         AS campaign_id,
    i.CampaignName                                       AS campaign_name,
    i.AdSetId                                            AS ad_set_id,
    SAFE_CAST(i.Impressions AS INT64)                    AS impressions,
    SAFE_CAST(i.Clicks AS INT64)                         AS clicks,
    CAST(ROUND(SAFE_CAST(i.Spend AS NUMERIC)) AS INT64)  AS cost,
    COALESCE(a.click_actions, 0)                         AS conversions,
    CAST(NULL AS INT64)                                  AS revenue
  FROM `campwill-ec.raw.ec_meta_ads_insights` i
  LEFT JOIN new_actions a
    ON i.DateStart = a.DateStart AND i.AdId = a.AdId
),
-- === UNION cutoff: 2026-06-30 以降は new、以前は legacy ===
combined AS (
  SELECT * FROM legacy WHERE date < DATE '2026-06-30'
  UNION ALL
  SELECT * FROM new_insights WHERE date >= DATE '2026-06-30'
)
SELECT
  date,
  campaign_id,
  campaign_name,
  ad_set_id,
  impressions,
  clicks,
  cost,
  conversions,
  revenue,
  CURRENT_TIMESTAMP() AS inserted_at
FROM combined;
