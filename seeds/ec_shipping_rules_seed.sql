-- 送料マスタ初期データ
-- 1注文あたり 1000円。Shopify orders 全期間 (2021-11-22 ~) をカバーするため広い範囲で1行
-- 送料変更時は古い行の valid_to を更新してから新行を追加すること（重複期間NG）

INSERT INTO `campwill-ec.mart.ec_shipping_rules`
  (valid_from, valid_to, shipping_fee_per_order)
VALUES
  (DATE('2020-01-01'), DATE('2099-12-31'), 1000);
