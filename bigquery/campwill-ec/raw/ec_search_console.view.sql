-- raw.ec_search_console VIEW: Search Console Bulk Data Export tables から派生
--
-- データ投入は Search Console 管理画面の「一括データのエクスポート」で自動化されている。
-- これにより毎日 BQ に 3 テーブル (searchdata_url_impression / searchdata_site_impression /
-- ExportLog) が追加される。
--
-- 既存の raw.ec_search_console スキーマ（仕様書 §3.1）に合わせて URL × クエリ粒度で
-- SELECT する VIEW。ctr / position は集計列が無いので算出する。
--
-- 設定方法:
--   1. n8n/docs/native-bq-integrations.md の手順で Bulk Export を有効化
--   2. データセットが campwill-ec:searchconsole に作成されることを確認
--   3. bq query --use_legacy_sql=false < ec_search_console.view.sql で VIEW 作成
--
-- 注意:
--   - searchdata_url_impression は (url, query, country, device, search_type, data_date) で
--     行が分かれている。本 VIEW では country/device/search_type を集約せず、生のまま。
--     必要なら GROUP BY を加えて集約可
--   - position は sum_position / impressions で計算（Search Console UI と同じ計算式）
--   - 匿名化されたクエリは含まれない (Google の仕様)

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_search_console` AS
SELECT
  data_date                            AS date,
  url                                  AS page,
  query                                AS query,
  clicks                               AS clicks,
  impressions                          AS impressions,
  SAFE_DIVIDE(clicks, impressions)     AS ctr,
  SAFE_DIVIDE(sum_position, impressions) AS position,
  CURRENT_TIMESTAMP()                  AS inserted_at
FROM `campwill-ec.searchconsole.searchdata_url_impression`
WHERE query IS NOT NULL;
