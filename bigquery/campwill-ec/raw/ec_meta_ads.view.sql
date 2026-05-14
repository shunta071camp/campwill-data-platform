-- raw.ec_meta_ads VIEW: Meta (Facebook) Ads BQ Data Transfer Service tables から派生
--
-- データ投入は GCP の BigQuery Data Transfer Service (BQ DTS) for Facebook Ads で自動化される。
-- DTS が作る AdInsights + AdInsightsActions を JOIN して、
-- 既存の raw.ec_meta_ads スキーマ（仕様書 §3.1）に合わせて SELECT する VIEW。
--
-- これにより mart.ec_channel_roi 等の下流 SQL は無変更で動く。
--
-- DTS テーブル仕様（kubell の Facebook DTS 設定で確認）:
--   - テーブル名は接尾辞なし: AdInsights, AdInsightsActions, Campaigns, AdSets, Ads, AdAccounts
--   - 列名は PascalCase: DateStart, CampaignId, AdSetId, AdId, Impressions, Clicks, Spend
--   - AdInsightsActions は action_type 別の列がない設計:
--       * ActionCollection は固定で "Actions"
--       * Action1dClick / Action7dClick / Action28dClick = attribution window 別 actions 数
--       * ActionValue = actions の合計値
--   - purchase 等の action_type 別分解は DTS では取得不可
--     → conversions は Action1dClick の集計値で暫定対応
--     → revenue は NULL（mart 層で Shopify orders から utm_source/medium で算出する設計）

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_meta_ads` AS
WITH actions_agg AS (
  SELECT
    DateStart,
    AdId,
    SAFE_CAST(SUM(SAFE_CAST(Action1dClick AS NUMERIC)) AS FLOAT64) AS click_actions
  FROM `campwill-ec.facebook_ads.AdInsightsActions`
  GROUP BY DateStart, AdId
)
SELECT
  i.DateStart                                          AS date,
  i.CampaignId                                         AS campaign_id,
  i.CampaignName                                       AS campaign_name,
  i.AdSetId                                            AS ad_set_id,
  SAFE_CAST(i.Impressions AS INT64)                    AS impressions,
  SAFE_CAST(i.Clicks AS INT64)                         AS clicks,
  CAST(ROUND(SAFE_CAST(i.Spend AS NUMERIC)) AS INT64)  AS cost,
  COALESCE(a.click_actions, 0)                         AS conversions,
  CAST(NULL AS INT64)                                  AS revenue,
  CURRENT_TIMESTAMP()                                  AS inserted_at
FROM `campwill-ec.facebook_ads.AdInsights` i
LEFT JOIN actions_agg a
  ON i.DateStart = a.DateStart
  AND i.AdId = a.AdId;
