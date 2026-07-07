# デイリーダイジェスト セットアップ手順

> Backlog・Googleカレンダー・Gmail・Slack から「今日やるべきこと」を毎平日 AM8:00 JST に集約し、
> 個人専用 Slack チャンネルへ通知する n8n ワークフロー。
> 仕様書: `CAMPWILL_デイリーダイジェスト_実装仕様書.md`

- ワークフロー JSON: [`n8n/workflows/daily-digest.json`](../n8n/workflows/daily-digest.json)
- 生成スクリプト: [`scripts/n8n-sync/build-daily-digest.py`](../scripts/n8n-sync/build-daily-digest.py)（JS を直すときはここを編集して再生成）
- フロー型（BigQuery 蓄積なし・リアルタイム処理のみ）

---

## ワークフロー構成（20 ノードの直列スパイン）

```
Schedule 8:00 平日 JST
 → Backlog: list users → pick my id → my due-soon issues → collect Backlog
 → Slack: list channels → lookup my member id → split channels
        → conversations.history (channel毎) → collect Slack mentions
 → Google Calendar: today events → collect Calendar
 → Gmail: list unread → split ids → get message (id毎) → collect Gmail
 → build digest prompt → Anthropic API (claude-sonnet-4-6) → extract text
 → Slack: post digest（個人チャンネル）
```

設計メモ:
- n8n の HTTP Request は **トップレベル配列レスポンスを N item に分割**、オブジェクトは 1 item。
  これを前提に「fetch（配列分割）→ Code で 1 item に集約」の形で fan-out を制御している。
- 仕様書は Gmail/Calendar を n8n ネイティブノードで、と記載しているが、本実装は **HTTP Request + 単一の
  generic OAuth2 credential** に統一（リポジトリの HTTP-first 流儀に合わせ、credential を 1 つに集約し、
  API デプロイ時の schema ずれを回避するため）。機能は同一。
- Gmail は要約専用ノードを置かず、snippet + 件名を digest 生成プロンプトに直接渡して 1 回の Claude
  呼び出しで要約まで行う（件数が少なくコスト・ノード数を抑えられるため）。

---

## 既に使い回している credential（設定不要）

| 用途 | n8n credential | 種別 |
|---|---|---|
| Backlog API | `Backlog API` (`SQjyvr3N3Fwux7Rp`) | HTTP Query Auth |
| Slack 読み取り | `Slack Bot (read)` (`e6HmFJZvXj23JwQF`) | HTTP Header Auth |
| Claude API | `Anthropic API` (`p7FCjP7Pvtv9IZ1F`) | HTTP Header Auth |
| Slack 投稿 | `Slack OAuth (n8n.cloud)` (`QkIO5PiBLGcuUZOd`) | Slack OAuth2（chat:write 済、error-handler と共用） |

---

## 事前準備（自社対応・3 つ）

### ① Google OAuth2 credential（Calendar + Gmail readonly）

Calendar と Gmail を **1 つの generic OAuth2 credential** でまかなう。

1. **Google Cloud Console** で OAuth クライアントを発行
   - API とサービス → 認証情報 → OAuth クライアント ID（種別: ウェブアプリケーション）
   - 承認済みリダイレクト URI に **`https://oauth.n8n.cloud/oauth2/callback`** を追加
   - 「APIとサービス → 有効なAPI」で **Google Calendar API** と **Gmail API** を有効化
   - OAuth 同意画面で対象アカウント（`s_miyazaki@campwill.me`）をテストユーザー or 内部に
2. **n8n UI → Credentials → New → `OAuth2 API`**（generic）を作成
   - **Grant Type**: `Authorization Code`
   - **Authorization URL**: `https://accounts.google.com/o/oauth2/v2/auth`
   - **Access Token URL**: `https://oauth2.googleapis.com/token`
   - **Client ID / Secret**: 手順①で発行したもの
   - **Scope**: `https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/gmail.readonly`
   - **Auth URI Query Parameters**: `access_type=offline&prompt=consent`（refresh token を確実に得るため）
   - **Authentication**: `Header`
   - **Name**: `Google OAuth2 (readonly)`
3. **Connect** → ブラウザで `s_miyazaki@campwill.me` を選んで同意 → 接続成功
4. この credential の **ID をメモ**（ワークフロー JSON の `REPLACE_GOOGLE_OAUTH_CRED_ID` に入れる）

> readonly スコープのみ。Gmail 本文は BigQuery に保存せず、Claude で要約して通知するのみ。

### ② 個人専用 Slack チャンネル + 投稿 Bot 招待

1. Slack で個人専用チャンネルを作成（例: `#daily-digest-miyazaki`、プライベート推奨）
2. 投稿用 Bot を招待: チャンネルで `/invite @<Slack OAuth (n8n.cloud) のアプリ名>`
   - これは error-handler が `#n8n_alert` に投稿しているのと同じ chat:write Bot
3. チャンネル ID を控える（チャンネル名右クリック → リンクをコピー → `…/archives/C0XXXXXXX` の `C0XXXXXXX`）
   - ワークフロー JSON の `REPLACE_DIGEST_CHANNEL_ID` に入れる

### ③ 自分宛メンション検出の前提（Slack member id）

- ワークフローは `users.lookupByEmail`（`s_miyazaki@campwill.me`）で自分の Slack member id を自動解決する。
- 読み取り Bot に **`users:read.email`** スコープが無い場合は解決に失敗し、メンション抽出が空振りする。
  - 対処 A: Slack App の OAuth スコープに `users:read.email` を追加して再インストール
  - 対処 B: `Code: split channels` ノード内の `REPLACE_WITH_SLACK_MEMBER_ID` を自分の member id（`U…`）に直書き
- 取得できるのは **Bot が join しているチャンネルでの自分宛メンションのみ**（DM・未参加チャンネルは対象外。
  v1 の合意仕様）。digest 対象にしたいチャンネルには Bot を招待しておく。

---

## デプロイ（Claude 側で実施）

事前準備①②が済み、credential ID とチャンネル ID が判明したら:

1. `daily-digest.json` の placeholder を置換
   - `REPLACE_GOOGLE_OAUTH_CRED_ID` → ① の credential ID
   - `REPLACE_DIGEST_CHANNEL_ID` → ② のチャンネル ID
2. n8n cloud へ新規作成（credential 参照を保持したまま POST）
3. `scripts/n8n-sync/workflow-ids.json` に `daily-digest` を追記
4. n8n UI で **手動実行（Execute Workflow）して動作確認** → 問題なければ Activate

```bash
# 動作確認・再 push 用（mapping 登録後）
python scripts/n8n-sync/sync.py diff daily-digest
python scripts/n8n-sync/sync.py push daily-digest
python scripts/n8n-sync/sync.py executions daily-digest --detail   # エラー時の調査
python scripts/n8n-sync/sync.py activate daily-digest
```

---

## 動作確認チェックリスト

| # | 確認内容 |
|---|---|
| ☐ | 手動実行で Backlog / Calendar / Gmail / Slack 各ノードがデータを返す |
| ☐ | `Code: pick my Backlog id` が自分の user を解決できている（throw していない） |
| ☐ | Gmail の要約が妥当（要返信のみ表示・情報共有は省略） |
| ☐ | 自分宛 Slack メンションが拾えている（member id 解決 OK） |
| ☐ | 個人チャンネルに mrkdwn 整形済みダイジェストが投稿される |
| ☐ | AM8:00（平日）に自動実行される |

---

## 既知の調整ポイント

- **Backlog ユーザー解決**: `Backlog API` credential のキー所有者に関係なく、`build-daily-digest.py` の
  `MY_EMAIL`（= `s_miyazaki@campwill.me`）でスペース内ユーザーを照合して assignee を特定する。
  メールが一致しなければ throw → error-handler 経由で `#n8n_alert` に通知される。
- **モデル**: `claude-sonnet-4-6`（助言品質と日次コストのバランス）。`build-daily-digest.py` の
  `ANTHROPIC_MODEL` で変更可。
- **対象 Backlog プロジェクト**: スペース内の全プロジェクト（assignee = 自分で絞り込み）。
- **発展案**（仕様書 §10）: 夕方の振り返り通知 / チーム全員展開 / 完了タスク自動検知 / BigQuery 連携。
