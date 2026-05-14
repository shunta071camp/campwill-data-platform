-- raw.re_search_console VIEW: Search Console Bulk Data Export tables から派生
--
-- 設定:
--   1. Search Console (krasula.jp プロパティ) → 設定 → 一括データのエクスポート
--      → 宛先: campwill-realestate / dataset: searchconsole / location: asia-northeast1
--   2. Google が campwill-realestate.searchconsole に毎日 3 テーブル投入
--      (searchdata_url_impression / searchdata_site_impression / ExportLog)
--   3. このファイルを bq query で実行して VIEW 作成
--
-- VIEW の粒度: URL × クエリ × 日次。country / device / search_type は集約せずそのまま残す。
-- 必要なら呼び出し側で GROUP BY 集約してください。

CREATE OR REPLACE VIEW `campwill-realestate.raw.re_search_console` AS
SELECT
  data_date                              AS date,
  url                                    AS page,
  query                                  AS query,
  clicks                                 AS clicks,
  impressions                            AS impressions,
  SAFE_DIVIDE(clicks, impressions)       AS ctr,
  SAFE_DIVIDE(sum_position, impressions) AS position,
  CURRENT_TIMESTAMP()                    AS inserted_at
FROM `campwill-realestate.searchconsole.searchdata_url_impression`
WHERE query IS NOT NULL;
