-- raw.ec_judgeme_reviews_latest: review_id 単位で最新 inserted_at 行を採用 (dedup)
--
-- daily incremental + 7日 overlap で同 review_id が複数 INSERT されるため、
-- 最新行のみ downstream に提供。reviewer による編集や moderation status 変更を反映。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_judgeme_reviews_latest` AS
SELECT
  * EXCEPT (rn, verified, verified_buyer),
  -- 旧行の verified は NULL or 旧 transform バグで false 固定なため、常に raw_payload 由来で再計算
  JSON_EXTRACT_SCALAR(raw_payload, '$.verified')                                 AS verified,
  JSON_EXTRACT_SCALAR(raw_payload, '$.verified') IN ('verified-purchase','confirmed-buyer')
                                                                                  AS verified_buyer
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY review_id ORDER BY inserted_at DESC) AS rn
  FROM `campwill-ec.raw.ec_judgeme_reviews`
)
WHERE rn = 1;
