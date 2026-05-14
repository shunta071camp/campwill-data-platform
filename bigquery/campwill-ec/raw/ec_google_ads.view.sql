-- raw.ec_google_ads VIEW: Google Ads BQ Data Transfer Service tables から派生
--
-- データ投入は GCP の BigQuery Data Transfer Service (BQ DTS) で自動化されている。
-- DTS が作る Campaign + CampaignBasicStats を JOIN して、既存の raw.ec_google_ads
-- スキーマ（仕様書 §3.1 raw.ec_google_ads）に合わせて SELECT する VIEW。
--
-- これにより mart.ec_channel_roi 等の下流 SQL は無変更で動く。
--
-- 設定方法:
--   1. n8n/docs/native-bq-integrations.md の手順で BQ DTS を有効化
--   2. データセット名と Customer ID（10桁、ハイフン除く）を確認
--   3. 下記 <REPLACE_DATASET_SUFFIX> と 5312357691 を置換
--      例: dataset name が "google_ads" で customer_id が 1234567890 の場合
--          google_ads.CampaignBasicStats_1234567890
--   4. bq query --use_legacy_sql=false < ec_google_ads.view.sql で VIEW 作成
--
-- 注意:
--   - DTS は ad_group 粒度のテーブル (AdGroupBasicStats) も別途持つので、ad_group_id が
--     必要なら別 view を作るか、本 VIEW の SELECT を AdGroupBasicStats ベースに変える
--   - Campaign テーブルは SCD（履歴）形式なので、最新行を QUALIFY で取る

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_google_ads` AS
SELECT
  s._DATA_DATE                                          AS date,
  CAST(c.campaign_id AS STRING)                         AS campaign_id,
  c.campaign_name                                       AS campaign_name,
  c.campaign_advertising_channel_type                   AS campaign_type,
  CAST(NULL AS STRING)                                  AS ad_group_id,
  s.metrics_impressions                                 AS impressions,
  s.metrics_clicks                                      AS clicks,
  CAST(s.metrics_cost_micros / 1000000 AS INT64)        AS cost,
  s.metrics_conversions                                 AS conversions,
  CAST(s.metrics_conversions_value AS INT64)            AS revenue,
  CURRENT_TIMESTAMP()                                   AS inserted_at
FROM `campwill-ec.google_ads.ads_CampaignBasicStats_5312357691` s
JOIN `campwill-ec.google_ads.ads_Campaign_5312357691` c
  ON s.campaign_id = c.campaign_id
  AND s._DATA_DATE BETWEEN c._DATA_DATE AND DATE_ADD(c._DATA_DATE, INTERVAL 60 DAY)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY s._DATA_DATE, s.campaign_id
  ORDER BY c._DATA_DATE DESC
) = 1;
