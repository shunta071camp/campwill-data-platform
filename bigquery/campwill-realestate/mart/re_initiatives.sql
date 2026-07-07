-- mart.re_initiatives: 不動産施策マスタ (PII ガード済 wide fact)
--
-- ソース: raw.re_initiatives_raw (Claude API が日次出力する不動産施策候補)
-- 対応する EC 側: campwill-ec.mart.ec_initiatives
--
-- target_metric (不動産用 3 種):
--   - inquiry : 反響数 (re_lead_funnel.inquiry_count)
--   - deal    : 新規案件 (re_lead_funnel.new_deal_count)
--   - seo     : オーガニック流入 (re_lead_funnel.organic_clicks)

CREATE OR REPLACE TABLE `campwill-realestate.mart.re_initiatives`
PARTITION BY start_date
CLUSTER BY target_metric, category
AS
WITH raw_filtered AS (
  -- n8n re_initiative_extract_daily が日次で「全カラム NULL の空 row」を同 initiative_id に挿入する
  -- バグがあり (KRASULA-189)、dedup で最新空 row が選ばれて mart 件数が日々減少していた。
  -- target_metric / start_date / source の必須メタが揃っている row のみを有効とみなす。
  SELECT *
  FROM `campwill-realestate.raw.re_initiatives_raw`
  WHERE parse_error_flag IS NOT TRUE
    AND initiative_id IS NOT NULL
    AND target_metric IS NOT NULL
    AND start_date IS NOT NULL
    AND source IS NOT NULL
),
dedup AS (
  SELECT * EXCEPT (rn)
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY initiative_id ORDER BY inserted_at DESC) AS rn
    FROM raw_filtered
  )
  WHERE rn = 1
),
pii_guard AS (
  SELECT
    * EXCEPT (title, description),
    IF(REGEXP_CONTAINS(IFNULL(title, ''),       r'[\w.-]+@[\w.-]+|0\d{9,10}'), NULL, title)       AS title,
    IF(REGEXP_CONTAINS(IFNULL(description, ''), r'[\w.-]+@[\w.-]+|0\d{9,10}'), NULL, description) AS description
  FROM dedup
),
backlog_descriptions AS (
  SELECT issue_id, description AS bl_description
  FROM `campwill-realestate.raw.re_backlog_issues_latest`
  WHERE description IS NOT NULL
),
backlog_comments_agg AS (
  -- 1 issue 配下のコメントを連結 (URL が完了報告コメントに書かれるケースに対応)
  SELECT issue_id, STRING_AGG(content, '\n') AS bl_comments
  FROM `campwill-realestate.raw.re_backlog_comments_latest`
  WHERE content IS NOT NULL
  GROUP BY issue_id
)
SELECT
  p.initiative_id,
  p.detected_at,
  p.source,
  p.source_id,
  p.source_url,
  p.additional_source_ids,
  p.category,
  p.title,
  p.description,
  p.start_date,
  p.end_date,
  p.target_metric,
  p.related_property,
  p.related_channel,
  -- SEO 記事 URL: Backlog issue description + コメント連結から krasula.jp/notes/<slug> を抽出
  -- (target_metric='seo' で source='backlog' のときに値が入る想定。fragment は除く)
  CASE
    WHEN p.source = 'backlog' THEN
      REGEXP_EXTRACT(
        CONCAT(IFNULL(bd.bl_description, ''), '\n', IFNULL(bc.bl_comments, '')),
        r'(https://krasula\.jp/notes/[a-zA-Z0-9_-]+)'
      )
    ELSE NULL
  END AS article_url,
  p.confidence,
  p.confidence_score,
  (p.confidence_score IS NOT NULL AND p.confidence_score < 0.7) AS needs_review,
  CURRENT_TIMESTAMP() AS generated_at
FROM pii_guard p
LEFT JOIN backlog_descriptions bd
  ON p.source = 'backlog' AND p.source_id = bd.issue_id
LEFT JOIN backlog_comments_agg bc
  ON p.source = 'backlog' AND p.source_id = bc.issue_id
WHERE p.start_date IS NOT NULL;
