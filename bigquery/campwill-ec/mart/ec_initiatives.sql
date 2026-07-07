-- mart.ec_initiatives: 施策マスタ (PII ガード済 wide fact)
--
-- ソース: raw.ec_initiatives_raw (Claude API が日次出力する施策候補)
--
-- 処理:
--   1. parse_error_flag = TRUE の行は除外 (翌日リトライ対象)
--   2. action_type による append_source の dedup (同 initiative_id の最新行採用)
--   3. PII guard: description / title に email / 電話番号 を含む行は当該列を NULL 化
--   4. confidence_score < 0.7 は needs_review = TRUE
--
-- 用途:
--   - mart.ec_initiative_results が start_date + 7日 経過した施策を効果検証
--   - BQ Analyst app / 社員 ad-hoc 分析が「最近の施策一覧」「カテゴリ別件数」等を SELECT
--
-- アクセス階層: mart 配置 = 全社員 READER。
--   施策内容 (Slack 抜粋等) は社内議論ベースだが、email/電話は除去済。

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_initiatives`
PARTITION BY start_date
CLUSTER BY target_metric, category
AS
WITH raw_filtered AS (
  -- parse_error 行を除外。
  -- n8n initiative-extract-daily が日次で「全カラム NULL の空 row」を同 initiative_id に挿入する
  -- バグがあり (KRASULA-189 で発見、EC 側も raw に null_target ~21% 確認)、dedup で最新空 row が
  -- 選ばれて mart 件数が日々減少していた。必須メタ (target_metric / start_date / source) が揃った
  -- row のみ有効とみなす。
  SELECT *
  FROM `campwill-ec.raw.ec_initiatives_raw`
  WHERE parse_error_flag IS NOT TRUE
    AND initiative_id IS NOT NULL
    AND target_metric IS NOT NULL
    AND start_date IS NOT NULL
    AND source IS NOT NULL
),
dedup AS (
  -- 同 initiative_id の最新行採用 (append_source で複数行発生)
  SELECT * EXCEPT (rn)
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY initiative_id ORDER BY inserted_at DESC) AS rn
    FROM raw_filtered
  )
  WHERE rn = 1
),
pii_guard AS (
  -- email / 電話番号を含む title / description は NULL 化
  SELECT
    * EXCEPT (title, description),
    IF(REGEXP_CONTAINS(IFNULL(title, ''),       r'[\w.-]+@[\w.-]+|0\d{9,10}'), NULL, title)       AS title,
    IF(REGEXP_CONTAINS(IFNULL(description, ''), r'[\w.-]+@[\w.-]+|0\d{9,10}'), NULL, description) AS description
  FROM dedup
)
SELECT
  initiative_id,
  detected_at,
  source,
  source_id,
  source_url,
  additional_source_ids,
  category,
  title,
  description,
  start_date,
  end_date,
  target_metric,
  related_sku,
  related_channel,
  confidence,
  confidence_score,
  (confidence_score IS NOT NULL AND confidence_score < 0.7) AS needs_review,
  CURRENT_TIMESTAMP() AS generated_at
FROM pii_guard
WHERE start_date IS NOT NULL;  -- start_date 不明の行は効果検証対象にならないので mart 出さない
