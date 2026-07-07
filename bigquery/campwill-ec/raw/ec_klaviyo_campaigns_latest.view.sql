-- raw.ec_klaviyo_campaigns_latest: 重複堆積した raw を dedup した正規データ
--
-- n8n workflow (klaviyo-campaigns) が UPSERT でなく日次 INSERT で同 campaign_id を
-- 多重挿入するため (調査時点で 21 行/campaign)、最新 inserted_at の 1 行のみを返す view。
-- 全 downstream はこの view を読むこと。
--
-- 検証: SUM(revenue) over last 30d sent_at = Klaviyo dashboard 表示と完全一致 (2026-05-19 確認)

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_klaviyo_campaigns_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_klaviyo_campaigns`
)
WHERE rn = 1;
