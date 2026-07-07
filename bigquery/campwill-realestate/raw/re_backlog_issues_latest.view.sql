-- raw.re_backlog_issues_latest: issue_id 単位で最新 inserted_at 行を採用 (dedup)

CREATE OR REPLACE VIEW `campwill-realestate.raw.re_backlog_issues_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY issue_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-realestate.raw.re_backlog_issues`
)
WHERE rn = 1;
