-- raw.ec_tiktok_ads_latest: (date, advertiser_id, campaign_id) 単位で最新 inserted_at 行を採用
--
-- workflow が overlap (最新-2日〜昨日) で再取得するため、同 (date, advertiser_id, campaign_id) に
-- 複数行が堆積する。dedup view で常に最新値を提供。
--
-- 全 downstream はこの view を読むこと (mart.ec_channel_attribution_weekly 等)。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_tiktok_ads_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY date, advertiser_id, campaign_id
      ORDER BY inserted_at DESC
    ) AS rn
  FROM `campwill-ec.raw.ec_tiktok_ads`
)
WHERE rn = 1;
