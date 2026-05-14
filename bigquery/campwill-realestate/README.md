# campwill-realestate

CAMPWILL クラスラ不動産事業の BigQuery 基盤。データソース:
- **GA4** (krasula.jp) — BQ Export
- **Search Console** (krasula.jp) — Bulk Export
- **自社案件管理システム** ([tenant-leasing](https://github.com/.../tenant-leasing)) の `/api/export/*`

## データセット

| データセット | テーブル | 内容 |
|---|---|---|
| `raw` | `re_tenants` | テナント (= 問い合わせ起点) |
| `raw` | `re_deals` | 案件 (Deal) |
| `raw` | `re_activities` | 活動履歴 (電話/メール/訪問/内見) |
| `raw` | `re_properties` | 物件 |
| `raw` | `re_owners` | オーナー |
| `raw` | `re_search_console` (VIEW) | SC Bulk Export → URL × クエリ × 日次 |
| `mart` | `re_lead_funnel` | 日次ファネル: 流入 → 問合せ → 案件化 → 成約 |
| `mart` | `re_case_pipeline` | 現時点パイプライン状態 |
| `mart` | `re_seo_inquiry_attribution` | SC × 問合せ貢献分析 (page-level は妥協版) |
| `mart` | `re_property_performance` | 物件別 KPI (案件数 / 内見数 / 成約率 / リードタイム) |
| `mart` | `re_weekly_summary` | 週次サマリ + WoW |
| `ga4_export` | `events_*` | GA4 自動 export |
| `searchconsole` | `searchdata_url_impression` 他 | SC Bulk Export 着地 |

## セットアップ手順

### 1. raw テーブル作成（一度だけ）

```bash
bash scripts/create-realestate-tables.sh
```

### 2. tenant-leasing 側で EXPORT_API_KEY を設定

`tenant-leasing/render.yaml` で env 宣言済み。Render Dashboard → Environment で 32 文字以上のランダム値を設定。

### 3. 初回 sync

```bash
EXPORT_API_KEY=<同じ値> \
EXPORT_BASE_URL=https://tenant-leasing.onrender.com \
GOOGLE_APPLICATION_CREDENTIALS=.keys/n8n-pipeline-campwill-realestate.json \
python3 scripts/realestate-sync.py
```

### 4. mart 初回生成

```bash
bash scripts/create-realestate-mart.sh
```

### 5. Scheduled Query 登録（mart の毎日自動再計算）

```bash
python3 scripts/setup-scheduled-queries-realestate.py
```

→ `re-lead_funnel` 等 5 本が登録され、毎日 20:00–20:20 UTC (= 05:00–05:20 JST) に自動実行される。

### 6. 日次 sync の cron 化

Render Cron Job を作成:
- Schedule: `30 19 * * *` (19:30 UTC = 04:30 JST)
- Command: `EXPORT_API_KEY=$EXPORT_API_KEY python3 scripts/realestate-sync.py`
- Env: campwill-data-platform repo を deploy する必要あり

> 暫定: 毎朝手動で `python3 scripts/realestate-sync.py` 実行でも可。

## データソースの設定

### GA4 BQ Export

1. GA4 (krasula.jp プロパティ) 管理画面 → BigQuery のリンク設定
2. リンク先プロジェクト: `campwill-realestate`
3. Dataset 名: `analytics_<id>` (自動命名)
4. データ更新頻度: 毎日 + 必要なら streaming
5. → 翌日 `analytics_<id>.events_YYYYMMDD` テーブルが現れる

### Search Console Bulk Export

1. Search Console (krasula.jp プロパティ) → 設定 → 一括データのエクスポート
2. クラウド プロジェクト: `campwill-realestate`
3. データセット名: `searchconsole`
4. 場所: `asia-northeast1`
5. → 翌日 `searchconsole.searchdata_url_impression` 等が出現
6. その後 `bash scripts/create-realestate-tables.sh` を再実行して `re_search_console` VIEW を作成

詳細は [n8n/docs/native-bq-integrations.md](../../n8n/docs/native-bq-integrations.md) 参照。

## tenant-leasing 側の API spec

```
GET /api/export/{tenants|deals|activities|properties|owners}
Authorization: Bearer <EXPORT_API_KEY>
Query:
  ?since=ISO8601   updated_at >= since (任意)
  ?cursor=<id>     id > cursor で次ページ (任意)
  ?limit=N         1..5000 (デフォルト 1000)

Response:
  { "items": [...], "count": N, "next_cursor": <id|null> }
```

## 既知の制限

- **Tenant.source** が自由文 (web/紹介/電話/...) のため、SC × Tenant の page-level attribution は不可。Tenant に `landing_page` / `utm_*` カラムを追加すれば改善可能（後 Phase）
- **DealStatusHistory** テーブル無し → status 遷移の履歴追跡は `Activity` から推測 or 別途追加必要
- **広告データ** (Google/Meta/SUUMO 等) は今回スコープ外

## 後 Phase

1. tenant-leasing に `landing_page` / `utm_source` カラム追加 → page-level SEO attribution
2. `DealStatusHistory` テーブル追加 → 詳細な遷移分析
3. Contract / Invoice / Viewing も BQ に乗せる（成約金額・入金状況・内見効率まで可視化）
4. 広告データ連携（Google Ads / Meta / SUUMO 等ポータル）
5. campwill-central で EC + 不動産 KPI 横断
