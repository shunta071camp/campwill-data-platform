# TikTok Ads 連携セットアップ

## 概要
TikTok For Business の広告実績 (campaign × day レベル) を TikTok Marketing API 経由で BQ に毎日取り込む。
- 取得 metric: impressions / clicks / spend / conversion / revenue / 動画再生 (25/50/75/100%)
- 取り込み先: `raw.ec_tiktok_ads`
- 後段: `mart.ec_channel_attribution_weekly` に `tiktok_paid` チャネルとして合流

サイト改修不要、API キー取得のみで開始可能。

---

## 必要なユーザー作業 (15-20 分)

### Step 1: TikTok for Business Developer 登録

1. https://business-api.tiktok.com/portal にアクセス
2. TikTok Ads Manager と同じアカウントでログイン
3. 開発者規約に同意 → 開発者登録 (個人開発者で OK、即時承認)

### Step 2: アプリ作成 + 権限設定

1. ポータルで **My Apps → Create an App**
2. 必須入力:
   - **App name**: `campwill-data-platform` 等
   - **App description**: `Daily ads reporting ingestion to BigQuery`
   - **Category**: `Marketing & Advertising`
   - **Application URL / Privacy URL**: `https://ku-bell.com` (要れば)
   - **Redirect URL**: `https://localhost:8080/callback` (後で OAuth 用、任意の値で可)
3. **Scopes** (必須):
   - ✅ `Ad Account Management`
   - ✅ `Reporting`
4. 保存 → **App ID** と **App Secret** が表示されるのでコピー (Secret は後で見れないので必ず保存)

### Step 3: 自分の Advertiser を Authorize (OAuth 1 回だけ)

簡単なフロー:

1. ポータルの App 詳細ページ → **Tools → Get Test Access Token** ボタンがあるならそれ使う (sandbox token、3 ヶ月有効)
2. なければ手動 OAuth:
   - ブラウザで以下 URL を開く (`<APP_ID>` と `<REDIRECT_URL>` を置換):
     ```
     https://business-api.tiktok.com/portal/auth?app_id=<APP_ID>&state=campwill&redirect_uri=<REDIRECT_URL>
     ```
   - TikTok ログイン → 自社の Advertiser Account を選択 → 承認
   - リダイレクト先 URL に `?auth_code=XXXXXX&state=campwill` が付いてるので **auth_code** をコピー (リダイレクト先がローカル等で開けなくても URL に出るので問題なし)
3. **auth_code を access_token に交換** (curl 等で 1 回だけ実行):
   ```bash
   curl -X POST 'https://business-api.tiktok.com/open_api/v1.3/oauth2/access_token/' \
     -H 'Content-Type: application/json' \
     -d '{
       "app_id":     "<APP_ID>",
       "secret":     "<APP_SECRET>",
       "auth_code":  "<AUTH_CODE>"
     }'
   ```
   - レスポンス:
     ```json
     {
       "data": {
         "access_token": "<LONG_LIVED_TOKEN>",
         "advertiser_ids": ["<ADVERTISER_ID>"]
       }
     }
     ```
   - **access_token** と **advertiser_id** をコピー

> ⚠ access_token は本番モードだと長期有効、sandbox だと短期。本番モード切替も App 詳細から可能。

### Step 4: n8n credential 作成

1. https://campwill.app.n8n.cloud/projects/xSwFSDmagTleuj5x/credentials/new
2. **Type: Header Auth** を選択
3. 入力:
   - **Credential Name**: `TikTok Marketing API`
   - **Name** (ヘッダ名): `Access-Token`
   - **Value**: コピーした access_token
4. 保存 → URL の credential ID をコピー

### Step 5: チャットで以下を返信

```
- credential ID: XXXXXXXXXX
- advertiser_id: 7XXXXXXXXXXXXXXXXXX (TikTok Ads Manager で確認できる account ID)
```

→ 私が workflow に埋め込んで push + manual trigger + 検証します。

---

## 仕組み

```
[n8n Schedule 03:15 JST daily]
  ↓
BigQuery: 最新 inserted_at の翌々日〜昨日 まで取得対象に
  (初回は 90 日 backfill)
  ↓
TikTok API: GET /open_api/v1.3/report/integrated/get/
  Headers: Access-Token: <token>
  Query: advertiser_id, report_type=BASIC, data_level=AUCTION_CAMPAIGN,
         dimensions=["campaign_id","stat_time_day"],
         metrics=[impressions, clicks, spend, conversion, ...],
         start_date / end_date
  ↓
Transform: list[] を flatten、metrics 値を spec 型に変換
  ↓
BigQuery: insert raw.ec_tiktok_ads
  (重複は将来 dedup view か mart 集計で対処)
```

## raw 列構成 (campwill-ec.raw.ec_tiktok_ads)

| 列 | 説明 |
|---|---|
| date | JST 日付 |
| advertiser_id | TikTok account ID |
| campaign_id / campaign_name | キャンペーン識別 |
| objective_type | TRAFFIC / CONVERSIONS / VIDEO_VIEWS |
| impressions / clicks / cost (JPY) | 基本メトリクス |
| conversions | TikTok 計上 CV |
| revenue | TikTok 計上売上 (JPY) |
| video_views / video_p25-p100_count | 動画動画再生段階別 (TikTok 固有) |

## mart 統合 (`ec_channel_attribution_weekly`)

push 後、`mart.ec_channel_attribution_weekly.sql` の `ad_costs_weekly` CTE に TikTok を追加:
```sql
UNION ALL
SELECT DATE_TRUNC(date, WEEK(MONDAY)), 'tiktok_paid', cost FROM `campwill-ec.raw.ec_tiktok_ads`
```

これで他 paid 4 種と並んで TikTok の cost / ROAS / CPA が同じマートに出る (channel_classified の分類ロジックにも `tiktok_paid` 判定追加要)。

## quota / コスト

- TikTok Marketing API quota: **10 req/sec per app**, daily quota は app 種別による
- 本 workflow: 1 req/day → quota の 0.0001% 使用
- 完全無料 (TikTok 広告費自体は別)

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `40105 Forbidden` | Access-Token 失効 / scope 不足 | 再 OAuth、または Scopes に Reporting 含まれてるか確認 |
| `40000 advertiser_id invalid` | advertiser_id 入力ミス | TikTok Ads Manager の URL から再確認 |
| `data.list が空` | 該当期間に広告未配信 | 想定内 |
| `code: 40002 spending data not ready` | TikTok 集計遅延 (typically 1-3h) | 翌朝の cron で自動回復 |
