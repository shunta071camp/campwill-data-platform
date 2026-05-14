# campwill-realestate (placeholder)

不動産事業の BigQuery スキーマ。仕様書 §3.2 では下記テーブルが想定されているが、現時点ではスキーマ詳細が未定義。

| データセット | テーブル | 内容 |
|---|---|---|
| raw | re_inquiries | 問い合わせデータ |
| raw | re_ads | 広告媒体データ |
| raw | re_backlog_issues | Backlog 課題 |
| mart | re_lead_analysis | リード分析 |
| mart | re_ad_performance | 広告パフォーマンス |
| mart | re_weekly_summary | 週次サマリ |
| ga4_export | events_* | GA4 自動エクスポート |

仕様書原文：

> 不動産事業のスキーマ詳細は事業データの整備状況に合わせて追加する。

## 次にやること

1. 不動産事業側で扱う問い合わせフォーム / 広告媒体 / SUUMO 等のデータソースを確定
2. 各データソースの API / CSV エクスポート仕様を調査
3. スキーマ JSON を `raw/` に追加
4. mart SQL を `mart/` に追加

データセット作成自体は `scripts/create-datasets.sh` が `campwill-realestate` の raw / mart / ga4_export を既に作るので、テーブル定義が確定し次第 `scripts/create-raw-tables.sh` 相当を不動産用に追加すればよい。
