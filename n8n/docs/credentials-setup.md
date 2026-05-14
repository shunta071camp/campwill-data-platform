# n8n Credentials セットアップ

各ワークフローが参照する認証情報を n8n の Credentials 機能に登録する手順。

> **セキュリティ原則**: API キーや SA 鍵 JSON はリポジトリに絶対にコミットしない。すべて n8n の Credentials 機能（暗号化保存）で管理する。ワークフロー JSON 側からは Credential 名で参照。

---

## 1. BigQuery (campwill-ec)

ワークフローが BigQuery `raw.*` テーブルに INSERT するための認証。

### 手順

1. n8n UI → 左メニュー「Credentials」→「New Credential」
2. 検索ボックスで **`Service Account`** または **`Google Service`** と入力
3. **「Google Service Account API」** を選択
   - ⚠️ 「Google BigQuery **OAuth2** API」は選ばない（ブラウザログイン用で、サーバー実行に向かない）
   - 「Google API」（無印）でも可。その場合は中の Authentication で `Service Account` を選択
4. **Service Account Email**: `n8n-pipeline@campwill-ec.iam.gserviceaccount.com`
5. **Private Key**: `campwill-ai-ready/.keys/n8n-pipeline-campwill-ec.json` を開き、`private_key` フィールドの値を貼り付け（`-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` まで全体）
   - JSON 内の `\n` を実際の改行に変換してからコピーする必要あり（テキストエディタの置換機能で `\n` → 改行）
6. （フィールドがあれば）**Impersonate a User**: 空欄
7. **Name** (Credential 名): `BigQuery (campwill-ec)`
8. 「Save」→「Test connection」で接続確認

### `private_key` の改行置換が面倒な場合

PowerShell で一発変換：

```powershell
$json = Get-Content "c:\Users\user\OneDrive\デスクトップ\AI\campwill-ai-ready\.keys\n8n-pipeline-campwill-ec.json" -Raw | ConvertFrom-Json
$json.private_key | Set-Clipboard
```

→ 既に改行展開された PEM 形式がクリップボードに入るので、そのまま貼り付け可能。

### `campwill-realestate` / `campwill-central` 用

同じ手順で `n8n-pipeline-campwill-realestate.json` / `n8n-pipeline-campwill-central.json` を使って別 Credential を作成（Credential 名は `BigQuery (campwill-realestate)` 等）。

---

## 2. Shopify (2026年仕様・OAuth2 経由)

> **重要**: 2026年1月から Shopify Dev Dashboard で作成したアプリは `shpat_` トークンを発行しません。短命トークン + リフレッシュ式に変更されたため、**n8n の OAuth2 機能で連携**するのが最短ルート（n8n 側でトークン更新も自動）。

### Step A: Dev Dashboard でアプリ作成

1. Shopify 管理画面（`https://kubell.myshopify.com/admin`）→ 右上プロフィール → **Dev Dashboard**
2. **アプリ** → **Create App** → App name: `n8n ETL`
3. **設定** タブで以下を設定：
   - **Application URL**: `https://oauth.n8n.cloud/` ← **n8n のコールバックホストと一致が必須**
   - **Allowed redirection URLs**: `https://oauth.n8n.cloud/oauth2/callback`
4. ストアにインストール（**インストール → kubell ストア選択 → 承認**）
5. 設定画面で **クライアントID** と **シークレット**をコピー（シークレットは 👁 で表示）

### Step B: n8n に Credential 登録

1. n8n UI → Credentials → **New** → 検索 **`Shopify OAuth2 API`**（"Access Token API" ではない）
2. 入力：
   - **Subdomain**: `kubell`
   - **Client ID**: Dev Dashboard でコピーしたもの
   - **Client Secret**: 同上
   - **Scopes**: `read_orders read_all_orders read_customers read_products read_inventory`（スペース区切り）
   - **Access Mode**: 空欄 or `offline`（リテラル `value` のままにしない）
   - **Name**: `Shopify OAuth2 (kubell)`
3. **Sign in with Shopify** → ブラウザで Shopify 承認画面 → 完了
4. **Connection successful** と出れば OK

### よくあるエラー

| エラー | 原因 | 対処 |
|---|---|---|
| `application_cannot_be_found` | アプリがストアに未インストール | Dev Dashboard でストアにインストール |
| `redirect_uri and application url must have matching hosts` | Dev Dashboard の Application URL が n8n コールバックホストと不一致 | Application URL を `https://oauth.n8n.cloud/` に設定 |
| `Invalid scope` | スコープのスペル誤りまたは未承認 | Dev Dashboard 側で同じスコープが宣言されているか確認 |

### n8n に登録

1. n8n UI → Credentials → New
2. `Shopify Access Token API` を選択
3. **Shop Subdomain**: 例 `campwill-store`（管理画面 URL の `https://campwill-store.myshopify.com` の `campwill-store` 部分）
4. **Access Token**: `shpat_...` を貼り付け
5. **Name**: `Shopify (campwill)`
6. Save → Test

> **既存の API キー**: `AI/shopify-freee-sync/` の `.env` で同じ Shopify ストアの API キーが既に発行されている可能性あり。重複発行せず流用するか検討。

---

## 3. Klaviyo

### API キー取得

1. Klaviyo Web UI → 右上アカウント → **Settings**
2. **API Keys** タブ → **Create Private API Key**
3. キー名: `n8n ETL`、スコープ: **Custom**で以下にチェック：
   - **Campaigns**: Read
   - **Profiles**: Read
   - **Metrics**: Read
   - **Events**: Read
4. 生成されたキー（`pk_...` 形式）をコピー

### n8n に登録

1. n8n UI → Credentials → New
2. `Klaviyo API` を選択（または `HTTP Header Auth`）
3. **API Key**: `pk_...` を貼り付け
   - HTTP Header Auth で設定する場合: Header Name = `Authorization`, Value = `Klaviyo-API-Key pk_...`、`revision` ヘッダ = `2024-10-15` も追加
4. **Name**: `Klaviyo`
5. Save → Test

---

## 4. Google Ads — n8n 不要 (BQ Data Transfer Service 使用)

n8n 経由ではなく、**BigQuery Data Transfer Service (BQ DTS)** で公式直接連携する。Google 公式・無料・メンテフリー。

セットアップ手順は [native-bq-integrations.md §1](native-bq-integrations.md#1-google-ads--bigquery-data-transfer-service) を参照。

> 旧版の n8n ワークフロー (`google-ads.json`) は削除済み。Developer Token / OAuth2 Client / Customer ID の n8n Credential 設定は不要。Customer ID と OAuth 同意のみが必要で、それは BQ DTS のセットアップ画面で完結する。

---

## 5. Meta Ads (Facebook / Instagram 有料) — n8n 不要 (BQ DTS 使用)

n8n 経由ではなく、**BigQuery Data Transfer Service (BQ DTS) for Facebook Ads** で公式直接連携する。Google 公式・無料・メンテフリー。

セットアップ手順は [native-bq-integrations.md §3](native-bq-integrations.md#3-meta-facebook-ads--bigquery-data-transfer-service) を参照。

> 旧版の n8n ワークフロー (`meta-ads.json`) は削除済み。System User Access Token / Ad Account ID の n8n Credential 設定は不要。BQ DTS 設定画面で Meta Business アカウントの OAuth 同意のみで完結する。
>
> **Instagram オーガニック (§8)** は引き続き Meta Graph API + n8n を使う（Meta 広告データではないため DTS 範囲外）。Instagram オーガニック用には別途 Meta Graph API の Access Token を取得する。

---

## 6. Yahoo!広告（検索 + ディスプレイ）

kubell は検索広告（Search Ads）とディスプレイ広告（YDA / Display Ads）の両方を出稿。両 API は別エンドポイント・別認証スコープだが、同じ Yahoo Developer Network アプリで認証可能。

### Step A: Yahoo!広告 API 利用申請（kubell 側で対応）

1. [Yahoo!広告管理画面](https://promotionalads.yahoo.co.jp/) にログイン
2. 上部メニュー → **「ツール」 → 「API」 → 「API利用申請」**
3. 利用目的・連携先（BigQuery 経由でデータ分析）を記入して申請
4. **承認まで 3〜5 営業日**（LY Corporation 審査）
5. 承認後、`Account ID` および `Base Account ID` が確認できるようになる

### Step B: Yahoo Developer Network でアプリ登録

1. [Yahoo Developer Network](https://e.developer.yahoo.co.jp/dashboard/) にログイン（Yahoo! JAPAN ID 必須）
2. **「新しいアプリケーションを開発」**
3. 入力項目:
   - アプリケーションの種類: **「サーバサイド（Web Application）」**
   - アプリケーション名: `CAMPWILL n8n ETL`
   - サイト URL: `https://campwill.me/`
   - コールバック URL: `https://oauth.n8n.cloud/oauth2/callback`
4. 利用スコープ: `yahooads` にチェック
5. 登録完了後、**Client ID** と **Client Secret** をコピー

### Step C: OAuth Refresh Token 取得（手動 1 回のみ）

ブラウザで以下 URL にアクセス（`{CLIENT_ID}` を置換）:
```
https://auth.login.yahoo.co.jp/yconnect/v2/authorization?response_type=code&client_id={CLIENT_ID}&redirect_uri=https://oauth.n8n.cloud/oauth2/callback&scope=yahooads&bail=1
```

1. Yahoo! JAPAN ログイン → 同意 → リダイレクト先 URL に `?code=XXXX` が付く
2. `code` 値をコピー
3. ターミナル / Postman で Token エンドポイントに POST:
   ```bash
   curl -X POST https://auth.login.yahoo.co.jp/yconnect/v2/token \
     -u "{CLIENT_ID}:{CLIENT_SECRET}" \
     -d "grant_type=authorization_code&code={CODE}&redirect_uri=https://oauth.n8n.cloud/oauth2/callback"
   ```
4. レスポンスの `refresh_token` をコピー（**期限なし**）

### Step D: n8n Credentials 登録

1. n8n UI → Credentials → New → `OAuth2 API`
2. 設定:
   - **Grant Type**: `Authorization Code`
   - **Authorization URL**: `https://auth.login.yahoo.co.jp/yconnect/v2/authorization`
   - **Access Token URL**: `https://auth.login.yahoo.co.jp/yconnect/v2/token`
   - **Client ID** / **Client Secret**: Step B で取得
   - **Scope**: `yahooads`
   - **Authentication**: `Body`
3. **Name**: `Yahoo Ads OAuth2`
4. Connect ボタン → ブラウザで Yahoo ログイン → 同意 → 完了

> **代替案**: HTTP Request の `Send Headers` で `Authorization: Bearer {access_token}` を直接渡し、別途 access token をリフレッシュする Code ノードを workflow に組み込む方法もある（OAuth2 credential を使わない）。

### Step E: Account ID 確認

n8n workflow で使う `accountId`（数値）と `baseAccountId` を kubell の Yahoo!広告管理画面 URL から確認:
- 例: `https://promotionalads.yahoo.co.jp/pages/account/{ACCOUNT_ID}/dashboard`

検索広告とディスプレイ広告で同じ `accountId` を使う。

---

## 7. Microsoft Advertising (Bing Ads)

### Step A: Developer Token 申請（kubell 側で対応）

1. [Microsoft Advertising 管理画面](https://ads.microsoft.com/) にログイン
2. 右上歯車 → **「Developer settings」** → **「Get a token」**
3. 利用目的を記入（"Internal data pipeline to BigQuery for analytics"）
4. **Sandbox Token** は即時発行、**Production Token** は **1〜3 営業日**で承認

### Step B: Azure Active Directory アプリ登録

1. [Azure Portal](https://portal.azure.com/) → **App registrations** → **New registration**
2. 入力:
   - Name: `CAMPWILL n8n ETL`
   - Supported account types: **「Multi-tenant」** 推奨
   - Redirect URI: **Web** → `https://oauth.n8n.cloud/oauth2/callback`
3. 登録完了後、**Application (client) ID** をコピー
4. **Certificates & secrets** → **New client secret** → 値をコピー（**Client Secret**、24 ヶ月有効）
5. **API permissions** → Add a permission → **Microsoft Advertising** → Delegated → `msads.manage` を追加 → Grant admin consent

### Step C: OAuth Refresh Token 取得

ブラウザで以下 URL にアクセス:
```
https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id={CLIENT_ID}&response_type=code&redirect_uri=https://oauth.n8n.cloud/oauth2/callback&scope=https://ads.microsoft.com/msads.manage%20offline_access&response_mode=query
```

1. Microsoft アカウント（kubell の Microsoft Ads 管理者）でログイン → 同意 → `?code=XXXX`
2. `code` を Token エンドポイントに POST:
   ```bash
   curl -X POST https://login.microsoftonline.com/common/oauth2/v2.0/token \
     -d "client_id={CLIENT_ID}&scope=https://ads.microsoft.com/msads.manage offline_access&code={CODE}&redirect_uri=https://oauth.n8n.cloud/oauth2/callback&grant_type=authorization_code&client_secret={CLIENT_SECRET}"
   ```
3. `refresh_token` をコピー（90 日間有効、毎回の API 呼び出しでローリング更新される）

### Step D: Customer ID / Account ID 確認

1. Microsoft Advertising 管理画面 → 右上歯車 → **「Account & billing」**
2. **Customer ID** と **Account ID** をコピー

### Step E: n8n Credentials 登録

1. n8n UI → Credentials → New → `OAuth2 API`
2. 設定:
   - **Grant Type**: `Authorization Code`
   - **Authorization URL**: `https://login.microsoftonline.com/common/oauth2/v2.0/authorize`
   - **Access Token URL**: `https://login.microsoftonline.com/common/oauth2/v2.0/token`
   - **Client ID** / **Client Secret**: Step B で取得
   - **Scope**: `https://ads.microsoft.com/msads.manage offline_access`
   - **Authentication**: `Body`
3. **Name**: `Microsoft Ads OAuth2`
4. 別途 HTTP Request ノードのヘッダに以下を追加:
   - `DeveloperToken`: Step A の Production Token
   - `CustomerId`: Step D の Customer ID
   - `CustomerAccountId`: Step D の Account ID

> Microsoft Ads は OAuth2 だけでは認証不十分で、Developer Token + Customer ID をヘッダで渡す必要がある（v13 仕様）。

---

## 8. Google Search Console — n8n 不要 (Bulk Data Export 使用)

n8n 経由ではなく、Search Console 公式の **Bulk Data Export** で BigQuery に直接エクスポート。Google 公式・無料・メンテフリー。

セットアップ手順は [native-bq-integrations.md §2](native-bq-integrations.md#2-search-console--bulk-data-export) を参照。

> 旧版の n8n ワークフロー (`search-console.json`) は削除済み。Search Console プロパティ所有者権限と Bulk Export 設定で完結する。

---

## 9. Instagram オーガニック (Meta Graph API)

Meta Ads は BQ DTS に切替えたが、**Instagram オーガニック投稿の insights は DTS 範囲外**なので n8n + Meta Graph API で取得する。

### 取得物
- **Access Token** (System User Token 推奨・期限なし) — Meta Business Suite で発行
- **Instagram Business Account ID**

### Access Token 取得
1. [Meta Business Suite](https://business.facebook.com/) → Business Settings
2. **System Users** → 新規作成 (権限: 管理者)
3. 該当の **Facebook Page** + **Instagram Business Account** を System User に割り当て
4. System User の「Generate New Token」→ App 選択 → scope: `instagram_basic`, `instagram_manage_insights`, `pages_read_engagement`, `business_management` → 生成

### Instagram Business Account ID の取得
1. Facebook Page と Instagram Business Account をリンク済みであることが前提
2. Graph API Explorer で `GET /me/accounts` → Page ID を取得
3. `GET /{page_id}?fields=instagram_business_account` → IG Business Account ID 取得
4. ワークフロー側の `REPLACE_WITH_IG_BUSINESS_ACCOUNT_ID` に貼り付け

### n8n に登録
1. Credentials → New → 検索 **`Facebook Graph API`**
2. **Access Token**: 上記トークン
3. Name: `Meta Graph API (Instagram)`

---

## 10. Slack 通知（Phase 2 で使用）

### Bot Token 取得

1. https://api.slack.com/apps → **Create New App** → From scratch
2. アプリ名: `CAMPWILL Reports`、ワークスペース: campwill
3. **OAuth & Permissions** → Scopes:
   - `chat:write`
   - `chat:write.public`
4. **Install to Workspace** → Bot User OAuth Token (`xoxb-...`) コピー
5. レポート投稿先チャンネル (`#ai-reports` 等) に Bot を `/invite @CAMPWILL Reports`

### n8n に登録
1. Credentials → New → `Slack API`
2. Access Token: `xoxb-...`
3. Name: `Slack (campwill)`
