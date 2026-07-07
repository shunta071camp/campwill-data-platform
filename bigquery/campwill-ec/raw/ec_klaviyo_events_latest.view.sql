-- raw.ec_klaviyo_events_latest: 重複堆積した raw.ec_klaviyo_events を dedup した正規データ
--
-- n8n workflow (klaviyo_events_daily) は incremental だが、再実行やオーバーラップで
-- 同一 event_id が複数 INSERT される可能性があるため、event_id 単位で最新 inserted_at 行を採用。
--
-- 全 downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_klaviyo_events_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_klaviyo_events`
)
WHERE rn = 1;
