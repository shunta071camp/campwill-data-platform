-- raw.ec_backlog_comments_latest: comment_id 単位で最新 inserted_at 行を採用 (dedup)

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_backlog_comments_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY comment_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_backlog_comments`
)
WHERE rn = 1;
