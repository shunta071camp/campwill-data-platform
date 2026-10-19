-- raw.ec_hapilogi_shipment_records_latest: 出荷実績の明細単位で最新取得行を採用 (dedup)
--
-- logiec shipmentRecord API は「前回取得以降に完了日時が進んだ実績」を返す差分 API。
-- 一部出荷→残り出荷などで同じ明細が再度返ることがあるため、最新行を採用する。
-- downstream はこの view を読むこと。

CREATE OR REPLACE VIEW `campwill-ec.raw.ec_hapilogi_shipment_records_latest` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY order_no, order_no_sub, row_no, item_code, IFNULL(lot_no, '')
      ORDER BY inserted_at DESC
    ) AS rn
  FROM `campwill-ec.raw.ec_hapilogi_shipment_records`
)
WHERE rn = 1;
