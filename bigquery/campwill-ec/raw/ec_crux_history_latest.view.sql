-- raw.ec_crux_history_latest: ec_crux_history_daily を dedup
--
-- 同一 (url, form_factor, collection_period_end) について最新 snapshot_date の行を採用。
-- 28日 rolling のため snapshot 毎に過去 28 collection_period が重複する。
-- downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_crux_history_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY url, form_factor, collection_period_end
      ORDER BY snapshot_date DESC, inserted_at DESC
    ) AS rn
  FROM `campwill-ec.raw.ec_crux_history_daily`
)
WHERE rn = 1;
