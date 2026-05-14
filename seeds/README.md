# Seeds

初期マスタデータ。

## ec_shipping_rules_seed.sql

送料マスタの初期値（2026年通年 1注文あたり1000円）。

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  < seeds/ec_shipping_rules_seed.sql
```

## ec_cost_master_seed_template.csv

単価マスタ投入用 CSV テンプレート。実データを埋めた版（`ec_cost_master.csv`）は `.gitignore` で除外される。

```bash
# テンプレをコピーして実データを埋める
cp seeds/ec_cost_master_seed_template.csv seeds/ec_cost_master.csv

# 投入
bq load \
  --source_format=CSV \
  --skip_leading_rows=1 \
  --project_id=campwill-ec \
  campwill-ec:mart.ec_cost_master \
  seeds/ec_cost_master.csv \
  bigquery/campwill-ec/mart/ec_cost_master.json
```

価格改定時は古い行の `valid_to` を更新してから新行を追加すること。
