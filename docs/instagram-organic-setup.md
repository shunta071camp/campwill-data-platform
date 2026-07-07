# Instagram オーガニック投稿パフォーマンス 取り込みセットアップ

## 概要

Instagram のオーガニック投稿 (Feed / Reels / Carousel) の impressions / reach / likes / comments / saves を毎日 BQ に取り込む。Meta Graph API v21.0 経由。

| 項目 | 値 |
|---|---|
| 取り込み先 | `campwill-ec.raw.ec_instagram_organic` |
| スケジュール | 毎日 03:40 JST |
| API | Meta Graph API (Instagram Graph API) v21.0 |
| 取得 metric | impressions, reach, likes, comments, saves, total_interactions, engagement_rate |
| n8n workflow | `n8n/workflows/instagram-organic.json` |

## 前提条件

- Instagram のアカウントが **ビジネスアカウント** または **クリエイターアカウント** に設定済 (個人アカウントは API 不可)
- Instagram が **Facebook ページとリンク** 済 (ビジネス/クリエイター化の必須要件)

ビジネス化の手順: Instagram アプリ → 設定 → アカウント → プロアカウントに切り替える → ビジネス/クリエイター選択 → Facebook ページに接続

---

## ユーザー側作業 (約 30 分)

### Step 1: Meta for Developers アカウント (1 分)

[https://developers.facebook.com/](https://developers.facebook.com/) にログイン (Facebook 個人アカウント連携)

### Step 2: Meta App 作成 (5 分)

1. [https://developers.facebook.com/apps/](https://developers.facebook.com/apps/) → **マイアプリ** → **アプリを作成**
2. 「ユースケースの選択」: **その他** → 次へ
3. 「アプリのタイプ」: **ビジネス** → 次へ
4. App 名: `campwill-ec-instagram` (任意)、連絡先メール入力 → 作成

### Step 3: Instagram Graph API を有効化 (3 分)

1. App ダッシュボードの左メニュー → **製品を追加**
2. **Instagram Graph API** の「設定」をクリック
3. ダイアログが出たら **設定** をクリック (これで使用可能になる)

### Step 4: Access Token 発行 (10 分) — 最重要

#### 4-A: Graph API Explorer を開く

[https://developers.facebook.com/tools/explorer/](https://developers.facebook.com/tools/explorer/)

#### 4-B: アプリを選択

右上の **Meta App** ドロップダウンから Step 2 で作った App を選択

#### 4-C: User Access Token を取得

1. **Generate Access Token** をクリック
2. 以下のスコープを **全部チェック**:
   - `instagram_basic`
   - `instagram_manage_insights`
   - `pages_show_list`
   - `pages_read_engagement`
   - `business_management`
3. 「Continue」→ Facebook 認証 → 許可

→ 上部の **Access Token** 欄に短期トークン (1〜2 時間有効) が表示される

#### 4-D: 長期 User Token に変換 (60 日有効)

ブラウザの新しいタブで以下 URL を開く (置換):

```
https://graph.facebook.com/v21.0/oauth/access_token?grant_type=fb_exchange_token&client_id=<App ID>&client_secret=<App Secret>&fb_exchange_token=<短期 User Token>
```

- **App ID**: App ダッシュボード → 設定 → 基本 → **アプリ ID**
- **App Secret**: 同ページの **app secret** → 「表示」を押す
- **短期 User Token**: Step 4-C でコピーしたもの

→ JSON で `{"access_token": "EAAxxx...", "token_type": "bearer"}` が返る。この `access_token` が **長期 User Token** (60 日有効)。

#### 4-E: Page Access Token (永続) を取得

Graph API Explorer に戻り、**アクセストークン** 欄に Step 4-D の長期 User Token を貼り付け。

クエリ欄に `me/accounts` を入力 → **送信**

→ レスポンスで `data` 配列内に Facebook ページ一覧。各 page の `access_token` が **Page Access Token** (有効期限なし)。

クーベル/CAMPWILL の Instagram に接続されている Facebook ページの `access_token` を控える。

> 💡 Page Access Token は基本的に **無期限**。これを Secret Manager / n8n credential に入れて運用する。

### Step 5: Instagram Business Account ID 取得 (2 分)

Graph API Explorer で、アクセストークン欄に **Page Access Token** を貼り付け、クエリ欄に以下を入力:

```
<PAGE_ID>?fields=instagram_business_account
```

`PAGE_ID` は Step 4-E の `me/accounts` で取得した page の `id`。

→ レスポンスで `instagram_business_account.id` が表示される。これが **Instagram Business Account ID** (例: `17841400123456789`、17 桁)。

### Step 6: n8n に credential 登録 (3 分)

[n8n credentials 新規作成画面](https://campwill.app.n8n.cloud/projects/xSwFSDmagTleuj5x/credentials/new) で:

- **Type**: 検索ボックスで `Facebook Graph API` と入力 → 選択
- **Credential Name**: `Meta Graph API (Instagram)`
- **Access Token**: Step 4-E の **Page Access Token** (`EAAxxx...`)
- 保存

→ URL の `credentials/XXXXXXXX` の `XXXXXXXX` をコピー (= n8n credential ID)

### Step 7: 動作確認 (任意、Graph API Explorer で)

アクセストークン欄に Page Access Token を貼って、以下クエリで投稿が返れば OK:

```
<IG_BUSINESS_ACCOUNT_ID>/media?fields=id,permalink,media_type,timestamp,like_count,comments_count&limit=5
```

→ 直近 5 投稿が JSON で返る = API 接続 OK

### Step 8: チャットで返信

```
- Instagram Business Account ID: <17 桁の ID>
- Meta Graph API credential ID: XXXXXXXX
```

→ 私が workflow に投入 → n8n push → manual trigger で検証。

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `Application does not have permission for this action` | scope 不足 | Step 4-C で全 5 scope をチェックして再 Generate |
| `instagram_business_account` フィールドが返らない | Instagram がビジネス/クリエイター化されてない | Instagram アプリでプロアカウント化 + Facebook ページ接続 |
| Long-lived token 変換で `Invalid OAuth access token` | App Secret 間違い | 設定 → 基本 で App Secret を再確認 |
| `Unsupported get request` (Insights API) | post が古すぎる (2 年以上前) or 削除済み | metric 取得は最新 90 日分のみ正確 |
| `Application request limit reached` | API レート制限 | n8n workflow は batchInterval=1000ms で 1 秒間隔なので通常問題なし。発生時は batchSize を下げる |

---

## 取得できる metric (BQ 列対応)

| 列 | 元 metric | 意味 |
|---|---|---|
| `impressions` | `impressions` (insights API) | 表示回数 (重複含む) |
| `reach` | `reach` (insights API) | ユニークユーザー数 |
| `likes` | `like_count` (media) | いいね数 (累計、取得時点) |
| `comments` | `comments_count` (media) | コメント数 (累計、取得時点) |
| `saves` | `saved` (insights API) | 保存数 |
| `engagement_rate` | `total_interactions / reach` を算出 | エンゲージメント率 |
| `media_type` | media | IMAGE / VIDEO / CAROUSEL_ALBUM / REEL |
| `post_url` | media.permalink | Instagram 上の URL |
| `posted_at` | media.timestamp | 投稿日時 |
| `date` | (取り込み日) | snapshot 日 = 累計 metric の取得日 |

> 注: `impressions/reach/saves` は **累計** (投稿〜現在までの合計)。日次差分が欲しい場合は mart 層で `LAG(reach) OVER (PARTITION BY post_id ORDER BY date)` 等で算出可。

---

## メンテナンス

### Page Access Token のローテーション

Page Access Token は基本的に無期限ですが、Facebook ページの管理者が変わると失効する可能性あり。失効時:

1. Graph API Explorer で再度 Step 4-D → 4-E を実行
2. n8n credential `Meta Graph API (Instagram)` の Access Token を更新 (UI 上で編集)

### Insights API の仕様変更

Meta は organic insights metric を時々 deprecate する (例: 2024 年に Reels の `impressions` → `views`)。
取り込み失敗が続く場合は最新 API docs を確認: [https://developers.facebook.com/docs/instagram-platform/reference/instagram-media](https://developers.facebook.com/docs/instagram-platform/reference/instagram-media)

---

## コスト目安

| サービス | 月額 |
|---|---|
| Meta Graph API | 無料 (API レート制限内) |
| BigQuery | <¥10/月 |

---

## 関連ファイル

- [n8n/workflows/instagram-organic.json](../n8n/workflows/instagram-organic.json) — workflow 本体
- [bigquery/campwill-ec/raw/ec_instagram_organic.json](../bigquery/campwill-ec/raw/ec_instagram_organic.json) — BQ schema
- [docs/initiatives-setup.md](initiatives-setup.md) — 類似手順書 (Slack/Backlog/Anthropic)
