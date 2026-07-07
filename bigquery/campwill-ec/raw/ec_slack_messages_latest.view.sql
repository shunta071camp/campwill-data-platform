-- raw.ec_slack_messages_latest: message_ts 単位で最新 inserted_at 行を採用 (dedup)
--
-- daily incremental が overlap 範囲を含むため同 message_ts が複数 INSERT されうる。
-- リアクション追加・メッセージ編集による再取得も最新行で吸収。
-- 全 downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_slack_messages_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY message_ts ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_slack_messages`
)
WHERE rn = 1;
