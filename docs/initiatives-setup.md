# 施策自動記録・効果検証システム セットアップ

## 概要

Slack と Backlog の昨日分の発言から、Anthropic Claude API が施策を自動抽出し、実施日 ±7 日窓で効果検証する仕組み。

**EC と不動産で完全分離した 2 系統**で稼働します:

| 系統 | BQ project | mart | target_metric (初版 3 種) |
|---|---|---|---|
| **EC** | `campwill-ec` | `mart.ec_initiatives` + `mart.ec_initiative_results` | `revenue` / `cvr` / `klaviyo_cv` |
| **不動産** | `campwill-realestate` | `mart.re_initiatives` + `mart.re_initiative_results` | `inquiry` / `deal` / `seo` |

- Slack Bot / Backlog API key も 2 系統 (EC 用と不動産用で別)
- Anthropic API key は 1 つで両方で共有

---

## ユーザー側作業 (約 40 分)

### Step 1: Slack 新規 App を 2 つ作成 (各 10 分、計 20 分)

それぞれ別のアプリとして作成:

#### 1-A: EC 用 Slack Bot
1. https://api.slack.com/apps → **Create New App → From scratch**
2. App Name: `campwill-ec-collector`
3. Workspace: 該当 workspace を選択
4. 左メニュー **OAuth & Permissions** → **Bot Token Scopes** に以下追加:
   - `channels:history`
   - `channels:read`
   - `groups:history`
   - `groups:read`
   - `users:read`
5. 上部 **Install to Workspace** → 承認 → `Bot User OAuth Token` (`xoxb-...`) をコピー
6. Slack で **EC 系の channel に Bot を invite**:
   ```
   /invite @campwill-ec-collector
   ```
   例: `#marketing-discussion`, `#ec-operations`, `#campaign-planning` 等

#### 1-B: 不動産用 Slack Bot
1. 同じ手順で **新規 App** を作成 (App Name: `campwill-property-collector`)
2. 同じ scope を付与
3. **Install to Workspace** → `Bot User OAuth Token` (`xoxb-...`) をコピー
4. Slack で **不動産系の channel に Bot を invite**:
   ```
   /invite @campwill-property-collector
   ```

> 1 つの workspace に Bot 2 体共存可能。各 Bot は invite された channel しか見えないので、EC channel と property channel を切り分けて invite してください。

### Step 2: Backlog API key を 2 つ取得 (3 分)

Backlog の構成によって対応が異なります:

- **same space (同じ Backlog 空間で project が分かれている)**: API key は 1 つで OK。ただし「2 つずつ作る」方針なら別 user で 2 key 発行
- **separate space (EC 用と不動産用で space が別)**: それぞれの space で発行

1. EC 用: `<ec-space>.backlog.com` → 個人設定 → API → 発行 → メモ (space domain も)
2. 不動産用: `<property-space>.backlog.com` → 同様に発行

### Step 3: Anthropic API key 取得 (3 分、共有)

1. https://console.anthropic.com/ → Settings → API Keys → Create Key
2. Name: `campwill-data-platform`
3. `sk-ant-...` をコピー (Billing 設定も必要、月 ~$4 想定 = EC + property 合算)

### Step 4: campwill-realestate 用の Google Service Account JSON を n8n に登録 (5 分)

既に EC 用 SA credential は n8n に登録済 (`Google Service Account account（EC）`)。
不動産用 SA は **新規登録** が必要:

1. リポジトリの `.keys/n8n-pipeline-campwill-realestate.json` をコピー (テキストエディタで開いて全文)
2. n8n 新規 credential 画面で:
   - **Type**: `Google Service Account API`
   - **Credential Name**: `Google Service Account (realestate)`
   - **Service Account Email**: `n8n-pipeline@campwill-realestate.iam.gserviceaccount.com`
   - **Private Key**: JSON の `private_key` 値 (`-----BEGIN PRIVATE KEY-----` 〜 `-----END PRIVATE KEY-----`)

### Step 5: n8n に通信系 credential 5 つを登録 (10 分)

[n8n credentials 新規作成画面](https://campwill.app.n8n.cloud/projects/xSwFSDmagTleuj5x/credentials/new) で:

| # | Credential Name | Type | Name | Value |
|---|---|---|---|---|
| 1 | `Slack Bot (EC/read)` | Header Auth | `Authorization` | `Bearer xoxb-...` (EC Bot token) |
| 2 | `Slack Bot (property/read)` | Header Auth | `Authorization` | `Bearer xoxb-...` (Property Bot token) |
| 3 | `Backlog API (EC)` | Query Auth | `apiKey` | (EC Backlog API key) |
| 4 | `Backlog API (property)` | Query Auth | `apiKey` | (Property Backlog API key) |
| 5 | `Anthropic API` | Header Auth | `x-api-key` | `sk-ant-...` |

→ 各保存後、URL の `credentials/XXXXXX` の `XXXXXX` をコピー

### Step 6: チャットで以下を返信

```
[EC 用]
- Slack Bot (EC) credential ID: XXXXXXXX
- Backlog API (EC) credential ID: XXXXXXXX
- Backlog space domain (EC): XXXX.backlog.com

[不動産用]
- Slack Bot (property) credential ID: XXXXXXXX
- Backlog API (property) credential ID: XXXXXXXX
- Backlog space domain (property): XXXX.backlog.com
- Google Service Account (realestate) credential ID: XXXXXXXX

[共有]
- Anthropic API credential ID: XXXXXXXX
```

→ 実装側で workflow 6 つに埋め込み → push/activate → manual trigger で動作確認。

---

## 仕組み (EC + 不動産 並走)

```
[03:00 JST]  slack-messages-daily         → raw.ec_slack_messages
[03:01 JST]  re_slack_messages_daily       → raw.re_slack_messages  ← 不動産
[03:10 JST]  backlog-issues-daily          → raw.ec_backlog_issues
[03:11 JST]  re_backlog_issues_daily       → raw.re_backlog_issues   ← 不動産
[03:20 JST]  initiative-extract-daily      → raw.ec_initiatives_raw  (Claude API)
[03:21 JST]  re_initiative_extract_daily   → raw.re_initiatives_raw  ← 不動産 (Claude API)

[03:25 JST SQ]  mart-ec_initiatives        → mart.ec_initiatives (PII guard + dedup)
[03:26 JST SQ]  re-initiatives             → mart.re_initiatives   ← 不動産

[04:30 JST]    既存 raw 取り込み (Shopify / realestate-sync 等)
[05:00 JST SQ] re-lead_funnel              → 不動産 lead funnel mart
[05:30 JST SQ] re-initiative_results       → mart.re_initiative_results ← 不動産 (lead_funnel 後)
[07:50 JST SQ] mart-ec_initiative_results  → mart.ec_initiative_results (全 EC mart 後)
```

---

## 初版スコープと制限

### target_metric 早見表

| 系統 | metric | 参照 | 効果値 |
|---|---|---|---|
| EC | `revenue` | `campwill-ec.mart.ec_daily_pnl` | SUM(revenue) per day |
| EC | `cvr` (代理) | `campwill-ec.mart.ec_channel_roi` | SUM(orders) per day |
| EC | `klaviyo_cv` | `campwill-ec.mart.ec_klaviyo_conversion` | SUM(shopify_orders) per day |
| 不動産 | `inquiry` | `campwill-realestate.mart.re_lead_funnel` | SUM(inquiry_count) per day |
| 不動産 | `deal` | `campwill-realestate.mart.re_lead_funnel` | SUM(new_deal_count) per day |
| 不動産 | `seo` | `campwill-realestate.mart.re_lead_funnel` | SUM(organic_clicks) per day |

### 制限
- 評価窓は **固定 7 日**
- 因果分離なし。`overlap_warning = TRUE` で同期間に別施策ある場合は寄与判定不可
- private channel / DM は Bot invite 必須 (PII 注意)
- AI の `confidence_score < 0.7` は `needs_review = TRUE` (最初 2 週間手動レビュー)

---

## コスト目安

| サービス | 月額 |
|---|---|
| Slack API (2 Bot) | 無料 |
| Backlog API | 既存契約 |
| Anthropic Claude Haiku 4.5 | **~$4/月** (EC + Property 合算) |
| BigQuery | <¥20/月 |

合計 **月 ~¥600** で 2 系統運用可能。

---

## 動作確認

```sql
-- EC 直近 30 日施策一覧
SELECT i.start_date, i.title, i.category, i.target_metric, i.confidence,
       r.change_pct, r.effect, r.overlap_warning, i.source_url
FROM `campwill-ec.mart.ec_initiatives` i
LEFT JOIN `campwill-ec.mart.ec_initiative_results` r USING (initiative_id)
WHERE i.start_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
ORDER BY r.change_pct DESC NULLS LAST;

-- 不動産 直近 30 日施策一覧
SELECT i.start_date, i.title, i.category, i.target_metric, i.confidence,
       r.change_pct, r.effect, r.overlap_warning, i.source_url
FROM `campwill-realestate.mart.re_initiatives` i
LEFT JOIN `campwill-realestate.mart.re_initiative_results` r USING (initiative_id)
WHERE i.start_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
ORDER BY r.change_pct DESC NULLS LAST;
```

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `slack_messages` 0 件 | Bot が channel に invite されてない | 各 channel で `/invite @campwill-{ec,property}-collector` |
| Slack 401 | Bot Token が user token (xoxp-) | OAuth 設定で **Bot User OAuth Token** (xoxb-) を使う |
| Backlog 401 | API key 無効 | Backlog 個人設定で再発行 |
| Anthropic 401 | API key 無効 | console.anthropic.com で再発行 |
| 不動産 workflow が Google SA error | n8n に realestate SA credential 未登録 | Step 4 で登録 |
| `parse_error` が多発 | Claude が JSON 以外を返した | max_tokens を 16384 に上げる |
| `initiative_results` が空 | start_date + 7 日経過した施策がまだない | 1 週間待つ |
