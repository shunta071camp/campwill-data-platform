# campwill-central (placeholder)

全社横断分析プロジェクト。仕様書 §3.3 では下記テーブルが想定されているが、SQL は未定義（Phase 3 で実装）。

| データセット | テーブル | 内容 |
|---|---|---|
| mart_all | all_revenue_summary | 全事業売上サマリ |
| mart_all | all_ad_comparison | 事業間広告費比較 |
| mart_all | all_channel_roi | 全チャネル ROI 比較 |
| mart_all | all_cost_summary | 全社コストサマリ |
| mart_all | company_kpi | 全社 KPI ダッシュボード用 |

## 設計の考え方

`campwill-central.mart_all.*` は `campwill-ec.mart.*` と `campwill-realestate.mart.*` を横断した SELECT で生成する。BigQuery は同一リージョン内であれば異なるプロジェクトの参照が可能（全プロジェクト `asia-northeast1` 統一が前提）。

例:
```sql
CREATE OR REPLACE TABLE `campwill-central.mart_all.all_revenue_summary` AS
SELECT 'ec' AS business, ...
FROM `campwill-ec.mart.ec_weekly_summary`
UNION ALL
SELECT 're' AS business, ...
FROM `campwill-realestate.mart.re_weekly_summary`;
```

## 次にやること（Phase 3）

1. EC 側 mart が安定稼働した後に着手
2. 不動産側 mart が整った後に着手
3. 両事業のメトリクス定義を揃える（売上単位、期間粒度、KPI 名）
4. SQL を `mart_all/` に追加
