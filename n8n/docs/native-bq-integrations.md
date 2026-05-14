# Native BigQuery Integrations (n8n を経由しない公式連携)

仕様書 §4 では Google Ads / Search Console を n8n 経由で取得する設計だったが、両者とも **Google 公式の BigQuery 直接連携が無料で提供されている**ため、こちらに切り替えた。

| 媒体 | 公式連携 | このドキュメント該当節 |
|---|---|---|
| GA4 | BigQuery Export | (仕様書 §4 通り、別途 GA4 管理画面で設定) |
| Google Ads | BQ Data Transfer Service | §1 |
| Search Console | Bulk Data Export | §2 |
| Meta (Facebook) Ads | BQ Data Transfer Service | §3 |

公式連携のメリット：
- API 認証・トークン更新を Google が管理（メンテ不要）
- 全期間バックフィル可能
- ネイティブテーブルでスキーマが豊富（DTS は ~80 テーブル、Bulk Export は 3 テーブル）
- 月額追加費用ゼロ（BQ ストレージのみ）

n8n 側で各媒体にスキーマを合わせるため、`bigquery/campwill-ec/raw/ec_*.view.sql` で **VIEW として既存スキーマと同形に派生**させる。これで mart 層の SQL は無変更で動く。

---

## 1. Google Ads — BigQuery Data Transfer Service

### 前提

- Google Ads アカウント管理者権限
- Customer ID（10 桁、ハイフンなし）— Google Ads UI 右上の `123-456-7890` から `-` 除いたもの
- BQ Data Transfer API が `campwill-ec` プロジェクトで有効化されていること

### 1.1 Data Transfer API 有効化

```bash
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
gcloud services enable bigquerydatatransfer.googleapis.com --project=campwill-ec
```

### 1.2 Console UI で転送設定

[https://console.cloud.google.com/bigquery/transfers?project=campwill-ec](https://console.cloud.google.com/bigquery/transfers?project=campwill-ec)

1. **+ CREATE TRANSFER**
2. **Source type**: `Google Ads`
3. **Transfer config name**: `Google Ads to campwill-ec`
4. **Schedule options**:
   - Repeats: Daily
   - Start now (or 任意の時刻)
5. **Destination settings**:
   - Dataset: 新規作成 or 既存指定 — 例 `google_ads`（リージョンは asia-northeast1）
6. **Data source details**:
   - Customer ID: 10 桁（ハイフンなし）
   - Refresh window: 7 (過去7日を毎日更新、訂正対応)
   - Exclude removed/disabled items: お好みで
7. **Backfill**: 「Schedule backfill」→ 開始日（30〜90日前）と終了日を指定
8. **Notification options**: 任意
9. **Save** → OAuth 同意画面で Google Ads アカウントを承認

### 1.3 完了確認

数分後、`campwill-ec:google_ads`（指定したデータセット名）に約 80 テーブルが作成される：

```bash
bq ls --project_id=campwill-ec google_ads | head -20
```

主要テーブル：
- `Campaign_<customer_id>` — キャンペーンメタデータ（SCD 形式）
- `CampaignBasicStats_<customer_id>` — キャンペーン日別統計
- `AdGroup_<customer_id>` / `AdGroupBasicStats_<customer_id>`
- `KeywordsBasicStats_<customer_id>`
- `Ad_<customer_id>` / `AdBasicStats_<customer_id>`
- ...

### 1.4 VIEW 作成

[bigquery/campwill-ec/raw/ec_google_ads.view.sql](../../bigquery/campwill-ec/raw/ec_google_ads.view.sql) を開いて、`<REPLACE_DATASET_SUFFIX>` と `<REPLACE_CUSTOMER_ID>` を実値で置換。

例：データセット名 `google_ads`、Customer ID `1234567890` の場合、テーブル参照は：
```
`campwill-ec.google_ads_REPLACE.ads_CampaignBasicStats_REPLACE`
```
↓
```
`campwill-ec.google_ads.ads_CampaignBasicStats_1234567890`
```

実行：

```bash
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
bq query --use_legacy_sql=false --project_id=campwill-ec \
  < bigquery/campwill-ec/raw/ec_google_ads.view.sql
```

### 1.5 動作確認

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  'SELECT * FROM `campwill-ec.raw.ec_google_ads` ORDER BY date DESC LIMIT 10'
```

---

## 2. Search Console — Bulk Data Export

### 前提

- Search Console プロパティの**所有者**権限
- BigQuery `campwill-ec` で空データセット `searchconsole` を作成

### 2.1 サービスアカウントへの権限付与

Search Console は専用のシステムサービスアカウント `search-console-data-export@system.gserviceaccount.com` から書き込みを行う。`campwill-ec` プロジェクトに以下のロールを付与：

```bash
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"

gcloud projects add-iam-policy-binding campwill-ec \
  --member='serviceAccount:search-console-data-export@system.gserviceaccount.com' \
  --role='roles/bigquery.jobUser' \
  --condition=None

gcloud projects add-iam-policy-binding campwill-ec \
  --member='serviceAccount:search-console-data-export@system.gserviceaccount.com' \
  --role='roles/bigquery.dataEditor' \
  --condition=None
```

### 2.2 BigQuery データセット作成

```bash
bq --location=asia-northeast1 --project_id=campwill-ec mk --dataset campwill-ec:searchconsole
```

### 2.3 Search Console で Bulk Export 設定

1. [Search Console](https://search.google.com/search-console) → 該当プロパティ選択
2. 左メニュー **設定** → **一括データのエクスポート**
3. **エクスポート開始**:
   - Cloud project ID: `campwill-ec`
   - Dataset name: `searchconsole`
   - Dataset location: `asia-northeast1`
4. 保存

48 時間以内に最初のエクスポートが走る。以降は毎日自動。

### 2.4 完了確認

```bash
bq ls --project_id=campwill-ec searchconsole
# 想定: ExportLog, searchdata_site_impression, searchdata_url_impression
```

### 2.5 VIEW 作成

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  < bigquery/campwill-ec/raw/ec_search_console.view.sql
```

### 2.6 動作確認

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  'SELECT date, page, query, clicks, impressions, position
   FROM `campwill-ec.raw.ec_search_console`
   WHERE date = (SELECT MAX(date) FROM `campwill-ec.raw.ec_search_console`)
   ORDER BY clicks DESC LIMIT 10'
```

---

## 3. Meta (Facebook) Ads — BigQuery Data Transfer Service

### 前提

- Meta Business アカウント管理者権限
- Ad Account ID（`act_` を除く 数字部分のみ）— Meta Business Suite で確認
- BQ Data Transfer API が `campwill-ec` プロジェクトで有効化されていること（Google Ads 設定時に有効化済みなら不要）

### 3.1 Console UI で転送設定

[https://console.cloud.google.com/bigquery/transfers?project=campwill-ec](https://console.cloud.google.com/bigquery/transfers?project=campwill-ec)

1. **+ CREATE TRANSFER**
2. **Source type**: `Facebook Ads`
3. **Transfer config name**: `Facebook Ads to campwill-ec`
4. **Schedule options**:
   - Repeats: Daily（最小間隔 24 時間）
5. **Destination settings**:
   - Dataset: 新規作成 — `facebook_ads`（asia-northeast1）
6. **Data source details**:
   - Ad Account IDs: 数字部分のみ（`act_1234567890` なら `1234567890`）
   - Refresh window: 7（過去 7 日を毎日上書き、Meta 側の遡及訂正対応）
7. **Backfill**: 「Schedule backfill」→ 過去 30〜90 日（Meta API 側制限あり、2026-01 以降一部 breakdown は 6ヶ月制限）
8. **Notification options**: 任意
9. **Save** → OAuth 同意画面で Meta Business アカウントを承認

### 3.2 完了確認

数十分後、`campwill-ec:facebook_ads` データセット下にテーブル群が作成される：

```bash
bq ls --project_id=campwill-ec facebook_ads
```

主要テーブル（DTS が固定で作成）：
- `AdAccounts_<account_id>` — アカウント情報
- `Campaigns_<account_id>` — キャンペーンメタデータ
- `AdSets_<account_id>` — Ad Set メタデータ
- `Ads_<account_id>` — Ad メタデータ
- `AdInsights_<account_id>` — 日別 ad/adset/campaign 別実績（impressions, clicks, spend 等）
- `AdInsightsActions_<account_id>` — action_type 別カウント（purchase, add_to_cart 等）
- `AdInsightsActionValues_<account_id>` — action_type 別 value（売上額）

### 3.3 VIEW 作成

[bigquery/campwill-ec/raw/ec_meta_ads.view.sql](../../bigquery/campwill-ec/raw/ec_meta_ads.view.sql) を開いて、`<REPLACE_AD_ACCOUNT_ID>` を実値で置換。

実行：

```bash
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
bq query --use_legacy_sql=false --project_id=campwill-ec \
  < bigquery/campwill-ec/raw/ec_meta_ads.view.sql
```

⚠️ DTS が初回データ着地後に**実際のテーブル名・列名を確認**して、SQL を必要に応じて微調整してください。AdInsightsActionValues が `value` ではなく別の列名の可能性、またはテーブル名にプレフィックスが付く可能性あり。

### 3.4 動作確認

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  'SELECT * FROM `campwill-ec.raw.ec_meta_ads` ORDER BY date DESC, cost DESC LIMIT 10'
```

---

## 補足: Meta Ads CLI

[Meta Ads CLI (2026-04-29 発表)](https://developers.facebook.com/blog/post/2026/04/29/introducing-ads-cli/) は Marketing API のラッパー Python CLI。

本リポでは採用していない理由：
- BQ 直接連携機能なし（DTS の方が我々の用途には適切）
- データ抽出はバッチ向きでなく ad-hoc 用途中心

将来用途：
- キャンペーン作成・編集の自動化（Mart 分析結果を元に予算配分を AI 提案 → CLI で適用）
- DTS の固定スキーマ外のカスタムメトリクス取得

---

## 4. campwill-realestate (krasula.jp) 用 — 同手順

ec と同じ手順で `campwill-realestate` プロジェクト + krasula.jp ドメインに対して設定する。差分のみ:

### GA4 BQ Export (krasula.jp)

- GA4 (krasula.jp プロパティ) 管理画面 → BigQuery のリンク設定
- リンク先プロジェクト: `campwill-realestate`
- データセット: `analytics_<id>` (自動命名)
- ロケーション: `asia-northeast1`

### Search Console Bulk Export (krasula.jp)

§2 と完全に同じ手順、置換するもの:
- プロジェクト: `campwill-ec` → `campwill-realestate`
- データセット名: `searchconsole`
- §2.1 の SA 権限付与は `campwill-realestate` プロジェクトに対して再実行
- §2.2 のデータセット作成: `bq --location=asia-northeast1 --project_id=campwill-realestate mk --dataset campwill-realestate:searchconsole`
- §2.3 の Bulk Export 設定で Cloud project ID を `campwill-realestate` に
- §2.5 の VIEW 作成は `bigquery/campwill-realestate/raw/re_search_console.view.sql` を使用

> 不動産は今回スコープでは Google Ads / Meta Ads は含めない (krasula は基本オーガニック中心)。後 Phase で必要なら §1 / §3 と同じ手順を `campwill-realestate` プロジェクトで踏む。

---

## 5. もし n8n 版に戻したい場合

`bigquery/campwill-ec/raw/ec_google_ads.json` `ec_search_console.json` `ec_meta_ads.json` のテーブルスキーマ JSON は残してあるので、`scripts/create-raw-tables.sh` で物理テーブルを再作成できる。その後 n8n ワークフロー JSON を git history から復元してインポートすれば元に戻せる。

ただし以下は失う：
- DTS の豊富なスキーマ
- メンテナンスフリー性
- 月次無料枠

通常は戻す理由がない。
