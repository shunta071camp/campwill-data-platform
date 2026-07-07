-- raw.ec_google_ads VIEW: Google Ads BQ Data Transfer Service tables から派生
--
-- データソース: campwill-ec.google_ads.ads_AccountBasicStats_5312357691
--   (BQ DTS が自動で日次取り込み、customer_id = 5312357691)
--
-- 設計判断 (2026-05-19 修正):
--   旧版は ads_CampaignBasicStats × ads_Campaign の INNER JOIN だったが、
--   Campaign メタテーブルの履歴開始日が新しく、それより古い stats date が落ちて
--   cost が約 10x 過小計上 (¥1.92M → ¥186K) になっていた。
--   downstream で campaign_id / campaign_name を使う箇所が無かったので
--   AccountBasicStats ベースに切替: 1 row/date、campaign-level 列は NULL。
--
--   campaign 別ブレイクダウンが必要になった時点で、CampaignBasicStats を
--   正しく dedup した別 view (ec_google_ads_by_campaign) を別途追加する方針。
--
-- 検証: SUM(cost) の 30d 値が Google Ads 管理画面の月次総支出と一致 (約 ¥1.92M)

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_google_ads` AS
SELECT
  _DATA_DATE                                            AS date,
  CAST(NULL AS STRING)                                  AS campaign_id,
  CAST(NULL AS STRING)                                  AS campaign_name,
  CAST(NULL AS STRING)                                  AS campaign_type,
  CAST(NULL AS STRING)                                  AS ad_group_id,
  CAST(SUM(metrics_impressions)             AS INT64)   AS impressions,
  CAST(SUM(metrics_clicks)                  AS INT64)   AS clicks,
  CAST(SUM(metrics_cost_micros) / 1000000   AS INT64)   AS cost,
  SUM(metrics_conversions)                              AS conversions,
  CAST(SUM(metrics_conversions_value)       AS INT64)   AS revenue,
  CURRENT_TIMESTAMP()                                   AS inserted_at
FROM `campwill-ec.google_ads.ads_AccountBasicStats_5312357691`
GROUP BY _DATA_DATE;
