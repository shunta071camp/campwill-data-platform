# n8n ワークフロー

仕様書 §4 のデータ取り込みパイプラインを n8n Pro（クラウド版）で構築するためのワークフロー JSON 集。

## 構成

```
n8n/
├── README.md                       # このファイル
├── docs/
│   ├── credentials-setup.md        # n8n に登録する各種認証情報の設定手順
│   ├── bq-scheduled-queries.md     # mart テーブル再生成（BigQuery 側スケジュールクエリ）
│   └── native-bq-integrations.md   # Google Ads / Search Console は BQ 公式連携を使う
└── workflows/
    ├── shopify-orders-incremental.json        # Shopify 注文 日次差分（毎日 AM 4:30）✅ Active
    ├── klaviyo-campaigns.json                 # Klaviyo キャンペーン実績（毎日 AM 4:00）✅ Active
    ├── klaviyo-profiles.json                  # Klaviyo プロフィール 差分取得（毎日 AM 4:00）✅ Active
    ├── klaviyo-profiles-backfill.json         # Klaviyo プロフィール初回バックフィル（手動・チャンク実行）
    ├── yahoo-ads.json                         # Yahoo!広告（検索+ディスプレイ）日次（毎日 AM 3:20、要API承認）
    ├── microsoft-ads.json                     # Microsoft広告（Bing）日次（毎日 AM 3:30、要Developer Token）
    ├── microsoft-ads-backfill.json            # Microsoft広告 初回バックフィル（手動・日付範囲指定）
    └── instagram-organic.json                 # Instagram オーガニック（毎日 AM 3:40）
```

> **n8n を経由しない媒体** (公式 BigQuery 直接連携を使用):
> - **Google Ads** → BigQuery Data Transfer Service ([設定手順](docs/native-bq-integrations.md#1-google-ads--bigquery-data-transfer-service))
> - **Search Console** → Bulk Data Export ([設定手順](docs/native-bq-integrations.md#2-search-console--bulk-data-export))
> - **Meta (Facebook) Ads** → BigQuery Data Transfer Service ([設定手順](docs/native-bq-integrations.md#3-meta-facebook-ads--bigquery-data-transfer-service))
> - **GA4** → BigQuery Export (GA4 管理画面で設定)
> - **Shopify Orders 初回バックフィル** → `scripts/shopify-backfill/backfill.py`（n8n では OOM するため Python スクリプト）
>
> 削除済み（不要 or 別手段で代替）:
> - `shopify-orders-initial-backfill.json` → Python script に役割移譲
> - `shopify-customers.json` → 当面 mart で使わないため
> - `google-ads.json` / `search-console.json` / `meta-ads.json` → BQ 公式連携に置換

## セットアップ手順

### 1. n8n Pro アカウント作成

[n8n.io/cloud](https://n8n.io/cloud) で Pro プランにサインアップ。月額約 8,000 円。

### 2. Credentials 登録

[docs/credentials-setup.md](docs/credentials-setup.md) を参照して、以下を n8n の Credentials に登録：

| Credential 名 | 用途 |
|---|---|
| `BigQuery (campwill-ec)` | `.keys/n8n-pipeline-campwill-ec.json` を使用 |
| `Shopify` | Shopify 管理画面 → アプリ → API キー |
| `Klaviyo` | Klaviyo Account → Settings → API Keys (Private Key) |
| `Slack` | Slack Bot Token（後続フェーズ） |

### 3. ワークフローインポート

n8n UI で「Workflows」→「Import from File」で `workflows/*.json` を順次インポート。

各ワークフローは import 直後は inactive 状態。Credentials を割り当ててから activate する。

> **既存 workflow の更新は同期スクリプトで自動化可能**: `scripts/n8n-sync/` 参照。
> ローカル JSON を編集 → `python scripts/n8n-sync/sync.py push <name>` で本番反映。
> UI 手動貼り替えが不要になる（5/1 で起きた「Code 古いまま」事故の予防）。

### 4. 初回バックフィル（チャンク実行）

`shopify-orders-initial-backfill.json` は `returnAll: true` で創業時から全件取ろうとすると n8n cloud のタイムアウトや Shopify Cloudflare 502 (`origin_bad_gateway`) で失敗する。kubell は約 15,000 件あるので、**日付範囲を区切って手動で複数回実行する**設計にしてある。

#### 手順

1. ワークフローを開く
2. **「Set: Date Range (EDIT BEFORE EACH RUN)」** ノードをクリック
3. `from_date` / `to_date` を以下のいずれかで埋める：
   - **テスト**: 直近 7 日（例: `2026-04-23T00:00:00Z` 〜 `2026-04-30T23:59:59Z`）でまず動作確認
   - **本番チャンク**: 1 年単位（例: `2020-01-01T00:00:00Z` 〜 `2020-12-31T23:59:59Z`）
4. 右下「Execute Workflow」を押す
5. 完了したら Set ノードに戻って次のチャンクの日付に書き換え → 再実行
6. 全期間（創業〜現在）まで繰り返す
7. 1 年で timeout する場合は四半期 → 月単位に縮める

#### 完了確認

BigQuery で以下を実行して、年別の件数が想定通りか確認：

```sql
SELECT
  EXTRACT(YEAR FROM created_at) AS year,
  COUNT(*) AS line_item_rows,
  COUNT(DISTINCT order_id) AS orders
FROM `campwill-ec.raw.ec_shopify_orders`
GROUP BY year
ORDER BY year;
```

合計 `COUNT(DISTINCT order_id)` が Shopify 管理画面の総注文数（kubell の場合 ~15,000）と一致すれば OK。

#### 重複した場合

同じチャンクを誤って 2 回実行すると `inserted_at` 違いで重複行ができる。`order_id` × `line_item_id` で MAX(inserted_at) を取って最新を採用すれば一意化できる（mart 層の責務）。気になるなら：

```sql
-- 重複削除（最新だけ残す）
CREATE OR REPLACE TABLE `campwill-ec.raw.ec_shopify_orders` AS
SELECT * EXCEPT(rn) FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY order_id, line_item_id
    ORDER BY inserted_at DESC
  ) AS rn
  FROM `campwill-ec.raw.ec_shopify_orders`
)
WHERE rn = 1;
```

#### 完了後

全チャンクを投入し終えたら、`shopify-orders-incremental.json` を Activate（毎日 AM 4:30 に動く）。`MAX(created_at)` を BigQuery から見て差分のみ取得するので、バックフィル完了後の翌日朝から自然に繋がる。

## 実行スケジュール（仕様書 §4 通り）

```
AM 3:00  Google広告
AM 3:10  Meta広告
AM 3:20  Yahoo!広告
AM 3:30  Microsoft広告 / Search Console
AM 3:40  Instagram オーガニック
AM 4:00  Klaviyo（campaigns + profiles）
AM 4:30  Shopify（orders + customers）
AM 5:00  Backlog
AM 6:00  mart テーブル再生成（BigQuery スケジュールクエリ・docs/bq-scheduled-queries.md）
AM 8:00  AI 週次レポート（Phase 2 で実装）
```

## 注意事項

- **タイムゾーン**: n8n のスケジュール設定は UTC ではなく **JST (Asia/Tokyo)** で指定。
- **ステート管理**: 差分取得は n8n の Static Data ではなく BigQuery の `MAX(inserted_at)` を毎回参照する設計。これにより手動再実行や復旧が容易。
- **エラー時の Slack 通知**: 各ワークフローに Slack 通知ノードを追加するのは Phase 2 で対応。それまでは n8n の execution log で監視。

## このディレクトリの非対象

- 実際の API キー値（n8n の Credentials 機能で管理、リポジトリに含めない）
- n8n のセルフホスト構成（n8n Pro クラウドを前提）
