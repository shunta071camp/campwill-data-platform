-- raw.ec_hapilogi_inbound_records_latest: 入荷実績の明細単位で最新取得行を採用 (dedup)
--
-- logiec inboundRecord API は「前回取得以降に更新された実績」を返す差分 API。
-- 更新された実績は再度返るため、最新行で常に最新の入荷数を提供する。
-- downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_hapilogi_inbound_records_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY order_no, row_no, item_code, IFNULL(lot_no, '')
      ORDER BY inserted_at DESC
    ) AS rn
  FROM `campwill-ec.raw.ec_hapilogi_inbound_records`
)
WHERE rn = 1;
