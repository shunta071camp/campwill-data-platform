-- raw.re_slack_messages_latest: message_ts 単位で最新 inserted_at 行を採用 (dedup)

CREATE OR REPLACE VIEW `campwill-realestate.raw.re_slack_messages_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY message_ts ORDER BY inserted_at DESC) AS rn
  FROM `campwill-realestate.raw.re_slack_messages`
)
WHERE rn = 1;
