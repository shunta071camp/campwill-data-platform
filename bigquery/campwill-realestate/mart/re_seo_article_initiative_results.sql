-- mart.re_seo_article_initiative_results: 不動産 SEO 記事施策の **個別記事** 効果検証
--
-- 既存の mart.re_initiative_results は re_lead_funnel.organic_clicks (= 組織全体合計) との
-- ±7 日窓比較のため、SEO 施策 30 件すべてが同値 (+25%) になり個別効果が見えない問題があった
-- (KRASULA-184 で発見)。本テーブルは raw.re_search_console を page 別に集計して個別記事 URL
-- ごとに baseline / observed / change_pct / effect を出す。
--
-- マッピング: mart.re_initiatives.article_url (KRASULA-186 で Backlog issue description /
-- comment から REGEXP_EXTRACT で取得) を JOIN キーとして使用
--
-- 対象: target_metric='seo' AND article_url IS NOT NULL AND start_date + 7 日が経過済
-- スキップ: article_url=NULL の施策 (新規記事制作で未公開 / 複数記事リライト系)
--
-- 窓: ±28 日 (元 plan の ±7 日では krasula.jp の低 traffic 記事で baseline=0 が頻発)
--   - baseline: start_date - 28 〜 start_date - 1 (28 日)
--   - observed: start_date 〜 LEAST(start_date + 27, CURRENT_DATE - 1) (最大 28 日、観察期間が短い施策は部分許容)
--   - 対象は最低 7 日経過した施策 (= observed 7 日分は確保)
--
-- effect 判定:
--   baseline=0 AND observed>0: 'positive' (流入発生)
--   baseline=0 AND observed=0: 'insufficient_data' (元々流入なし、判定不可)
--
-- SC 側 URL の fragment (`#index_xxx`) 違いは REGEXP で正規化して同一視

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_seo_article_initiative_results`
PARTITION BY DATE(calculated_at)
AS
WITH targets AS (
  SELECT
    initiative_id,
    title,
    start_date,
    article_url,
    LEAST(
      DATE_ADD(start_date, INTERVAL 27 DAY),
      DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 1 DAY)
    ) AS observed_end_date
  FROM `campwill-realestate.mart.re_initiatives`
  WHERE target_metric = 'seo'
    AND start_date IS NOT NULL
    AND start_date <= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
    AND article_url IS NOT NULL
),
sc_per_article AS (
  -- raw.re_search_console.page から fragment を除去して /notes/<slug> に正規化
  SELECT
    date,
    REGEXP_EXTRACT(page, r'(https://krasula\.jp/notes/[a-zA-Z0-9_-]+)') AS article_url,
    SUM(clicks) AS clicks
  FROM `campwill-realestate.raw.re_search_console`
  WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 90 DAY)
    AND page LIKE 'https://krasula.jp/notes/%'
  GROUP BY date, REGEXP_EXTRACT(page, r'(https://krasula\.jp/notes/[a-zA-Z0-9_-]+)')
),
results AS (
  SELECT
    t.initiative_id,
    t.title,
    t.article_url,
    t.start_date,
    t.observed_end_date,
    DATE_DIFF(t.observed_end_date, t.start_date, DAY) + 1 AS observed_days,
    AVG(IF(sc.date BETWEEN DATE_SUB(t.start_date, INTERVAL 28 DAY)
                       AND DATE_SUB(t.start_date, INTERVAL 1 DAY), sc.clicks, NULL)) AS baseline_clicks,
    AVG(IF(sc.date BETWEEN t.start_date AND t.observed_end_date, sc.clicks, NULL)) AS observed_clicks
  FROM targets t
  LEFT JOIN sc_per_article sc
    ON sc.article_url = t.article_url
      AND sc.date BETWEEN DATE_SUB(t.start_date, INTERVAL 28 DAY) AND t.observed_end_date
  GROUP BY t.initiative_id, t.title, t.article_url, t.start_date, t.observed_end_date
)
SELECT
  initiative_id,
  title,
  article_url,
  start_date,
  observed_end_date,
  observed_days,
  ROUND(baseline_clicks, 2) AS baseline_clicks,
  ROUND(observed_clicks, 2) AS observed_clicks,
  ROUND(SAFE_DIVIDE(observed_clicks - baseline_clicks, NULLIF(baseline_clicks, 0)) * 100, 1) AS change_pct,
  CASE
    WHEN baseline_clicks IS NULL OR observed_clicks IS NULL                       THEN 'insufficient_data'
    WHEN baseline_clicks = 0 AND observed_clicks = 0                              THEN 'insufficient_data'
    WHEN baseline_clicks = 0 AND observed_clicks > 0                              THEN 'positive'
    WHEN observed_clicks > baseline_clicks * 1.05                                 THEN 'positive'
    WHEN observed_clicks < baseline_clicks * 0.95                                 THEN 'negative'
    ELSE                                                                              'neutral'
  END AS effect,
  CURRENT_TIMESTAMP() AS calculated_at
FROM results;
