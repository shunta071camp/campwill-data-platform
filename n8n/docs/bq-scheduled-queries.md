# BigQuery Scheduled Queries (mart テーブル再生成)

仕様書 §4 の **AM 6:00 mart 生成** は n8n ではなく BigQuery のネイティブ機能 Scheduled Queries で実装する。理由：

- 同一プロジェクト内のクエリ実行に n8n を経由する意味がない
- BigQuery 側でスケジュール・履歴・エラー通知が完結
- スケジュールクエリは BigQuery Data Transfer Service の機能で、無料

---

## 1. 事前準備

### 1.1 BigQuery Data Transfer API 有効化

```bash
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"

gcloud services enable bigquerydatatransfer.googleapis.com \
  --project=campwill-ec
```

### 1.2 BigQuery Console で設定

[https://console.cloud.google.com/bigquery/scheduled-queries?project=campwill-ec](https://console.cloud.google.com/bigquery/scheduled-queries?project=campwill-ec)

---

## 2. 登録するスケジュールクエリ一覧

| # | 名前 | スケジュール (JST) | クエリ |
|---|---|---|---|
| 1 | `mart_ec_daily_pnl` | 毎日 06:00 | `bigquery/campwill-ec/mart/ec_daily_pnl.sql` |
| 2 | `mart_ec_channel_roi` | 毎日 06:05 | `bigquery/campwill-ec/mart/ec_channel_roi.sql` |
| 3 | `mart_ec_klaviyo_conversion` | 毎日 06:10 | `bigquery/campwill-ec/mart/ec_klaviyo_conversion.sql` |
| 4 | `mart_ec_weekly_summary` | 毎日 06:15 | `bigquery/campwill-ec/mart/ec_weekly_summary.sql` |

5分ずつずらしているのは、BQ 内部の処理競合を避けるためと、依存関係の安全マージン（n8n の raw 投入が AM 4:30 完了 → 1:30 のバッファ）。

---

## 3. Console UI での登録手順

各 SQL ファイルにつき、以下を繰り返す：

1. [BigQuery Console](https://console.cloud.google.com/bigquery?project=campwill-ec) を開く
2. クエリエディタに `bigquery/campwill-ec/mart/ec_daily_pnl.sql` の中身をコピペ
3. 「スケジュール」 → **新しいスケジュールされたクエリ**
4. 設定：
   - **名前**: `mart_ec_daily_pnl`
   - **スケジュール**: 「カスタム」
   - **カスタム頻度**: `every day 06:00`
   - **タイムゾーン**: `Asia/Tokyo`
   - **クエリ結果の宛先**: SQL に `CREATE OR REPLACE TABLE` が含まれているので **指定しない**（DDL クエリ扱い）
   - **サービスアカウント**: `n8n-pipeline@campwill-ec.iam.gserviceaccount.com`（ない場合は自分のユーザーアカウントで OK だが、退職時に切れる）
   - **通知**: メール通知 or Pub/Sub（後で Slack 通知に繋げたい場合は Pub/Sub）
5. 「保存」

---

## 4. CLI 一括登録（推奨・冪等）

`scripts/setup-scheduled-queries.sh` を本リポジトリに追加して bq CLI で一括作成：

```bash
bash scripts/setup-scheduled-queries.sh
```

このスクリプトは以下を行う：

1. `bigquerydatatransfer.googleapis.com` API 有効化
2. `bq mk --transfer_config` で 4 つのスケジュールクエリを登録（既存ならスキップ）

スクリプト本体はこの README と一緒のリポジトリに置いてある（次フェーズで作成）。

---

## 5. サービスアカウントへの追加権限付与

スケジュールクエリを SA で実行する場合、SA に以下が必要：

```bash
# Data Transfer Service Agent
gcloud iam service-accounts add-iam-policy-binding \
  n8n-pipeline@campwill-ec.iam.gserviceaccount.com \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountShortTermTokenMinter" \
  --project=campwill-ec
```

ただし、ユーザーアカウントで実行するなら不要。実装時に決める。

---

## 6. 動作確認

```bash
# スケジュールクエリ一覧
bq ls --transfer_config --transfer_location=asia-northeast1 --project_id=campwill-ec

# 個別の実行履歴
bq ls --transfer_run --max_results=5 --project_id=campwill-ec <transfer_id>

# 手動トリガー（次のスケジュールを待たずに今すぐ実行）
bq mk --transfer_run \
  --project_id=campwill-ec \
  --start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  --end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  <transfer_id>
```

---

## 7. 失敗時の対応

- BigQuery Console → スケジュールクエリ → 該当クエリ → 「実行履歴」でエラーメッセージ確認
- raw に必要なデータが入っていない場合は SELECT が空になるだけで失敗はしないが、空の mart は AI レポートで「データなし」と判断される
- 構文エラーで失敗した場合は SQL を修正して `bq query --use_legacy_sql=false < file.sql` でローカル検証してから再登録
