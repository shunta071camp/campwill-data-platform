-- raw.ec_backlog_issues_latest: issue_id 単位で最新 inserted_at 行を採用 (dedup)
--
-- ステータス変更 / 担当者変更 / コメント追加で issue が再 INSERT されるため、
-- 最新行で常に最新ステータスを mart に提供。
-- 全 downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_backlog_issues_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY issue_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_backlog_issues`
)
WHERE rn = 1;
