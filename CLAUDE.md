# CAMPWILL Data Platform — Claude Code / Codex 利用ガイド

このリポジトリは CAMPWILL の EC 事業のデータ基盤（BigQuery + n8n + Claude API）。Claude Code / Codex で BigQuery を扱うときの前提を以下にまとめる。

---

## プロジェクト構成

| GCP プロジェクト | 用途 | 状態 |
|---|---|---|
| `campwill-ec` | EC 事業（kubell）— raw 23 テーブル + 12 view、mart 25 テーブル + 1 view、Scheduled Query 22 本稼働中 | **稼働中** |
| `campwill-realestate` | 不動産事業（クラスラ）| **廃止**（2026-08-12 プロジェクト削除） |
| `campwill-central` | 全社横断（Phase 3） | placeholder |

> `campwill-realestate` は 2026-08-12 に廃止。データソースだった案件管理システム tenant-leasing (Render) の解約に伴い、BigQuery 4 データセット（raw / mart / GA4 export / searchconsole）・Scheduled Query 8 本・n8n 3 本（`re_*`）・関連 SQL を全て削除した。不動産系の記述が残っていたら過去の遺物。

- ロケーション: **`asia-northeast1`**（東京）固定。GA4 Export と一致が必須
- 日次バッチは UTC 23:00–23:55（JST 08:00–08:55）に集中

---

## データセットの使い分け

### `campwill-ec.raw` — 生データ（PII 含む、扱い注意）

| テーブル | 内容 | 注意 |
|---|---|---|
| `ec_shopify_orders` | Shopify 注文 | **email / phone 等 PII** |
| `ec_shopify_products_daily` | 商品+原価日次スナップショット | |
| `ec_klaviyo_campaigns` / `ec_klaviyo_profiles` | Klaviyo メール配信 | **PII** |
| `ec_klaviyo_campaigns_latest` (VIEW) | Klaviyo Campaigns dedup 済 (raw 本体は n8n 日次 INSERT で重複堆積) — **downstream はこれを読む** | |
| `ec_klaviyo_events` | Klaviyo Events (Clicked Email per profile/timestamp、attribution per-order 用) | **PII** |
| `ec_klaviyo_events_latest` (VIEW) | 上記 dedup 済 — **downstream はこれを読む** | |
| `ec_crux_history_daily` | CrUX History API 経由の URL 別 Core Web Vitals (LCP/INP/CLS/FCP/TTFB) 28日 rolling | |
| `ec_crux_history_latest` (VIEW) | 上記 dedup 済 — **downstream はこれを読む** | |
| `ec_judgeme_reviews` | Judge.me Shopify レビュー (rating/body/reviewer/verified/pictures) | **PII** (reviewer_email/ip_address) |
| `ec_judgeme_reviews_latest` (VIEW) | review_id dedup + verified を raw_payload から派生 | **downstream はこれを読む** |
| `ec_slack_messages` / `ec_slack_messages_latest` (VIEW) | Slack 社内 message (Bot 投入 channel のみ、施策抽出元) | 社内議論 |
| `ec_backlog_issues` / `ec_backlog_issues_latest` (VIEW) | Backlog 課題 dedup (status 変更追跡、n8n 日次 INSERT で重複堆積、latest を使う) | |
| `ec_backlog_comments` / `ec_backlog_comments_latest` (VIEW) | Backlog コメント dedup | |
| `ec_initiatives_raw` | Claude API 出力 (施策候補、デバッグ用 raw_payload 含む) | |
| `ec_meta_ads` (VIEW) | Meta 広告 — 2026-06-29 以前 BQ DTS (facebook_ads.*)、2026-06-30 以降 n8n workflow (ec_meta_ads_insights*) の UNION | |
| `ec_meta_ads_insights` | Meta Ads Insights (n8n meta-ads-daily 経由、Marketing API 直叩き、ad 単位日次) | |
| `ec_meta_ads_insights_actions` | Meta Ads Insights action_type 別 (attribution window 別) | |
| `ec_google_ads` (VIEW) | Google 広告 — BQ DTS 経由 | |
| `ec_search_console` (VIEW) | GSC — Bulk Export 経由 | |
| `ec_yahoo_ads` / `ec_microsoft_ads` | Yahoo / MS 広告 | |
| `ec_tiktok_ads` | TikTok 広告 (campaign × day、TikTok Marketing API 経由) | |
| `ec_instagram_organic` | Instagram オーガニック投稿の日次スナップショット (Meta Graph API v21.0 経由)。直近 30 日、累計 metric。`impressions` 列は実際は Reels の `views` を格納 (Meta が 2024 年に rename) | reach, views, likes, comments, saves, engagement_rate |
| `ec_backlog_issues` | Backlog 課題 | |
| `rakko_inflow_keywords` | ラッコ KW（自社+競合 7URL × 週次） | |
| `ec_openlogi_inventory_daily` | OPENLOGI 在庫日次スナップショット (**2026-09 にはぴロジへ倉庫移管、以降は全 SKU 0。取り込み停止中**) | |
| `ec_clarity_metrics_daily` | Microsoft Clarity UX 指標日次（OVERALL / URL / Source+Device の 3 dimension_set） | |
| `ec_ga4_purchase` (VIEW) | GA4 purchase event（transaction_id = Shopify order_id） | |
| `ec_ga4_user_first_session` (VIEW) | GA4 user_pseudo_id 別の最初の session_start | |
| `oauth_tokens` / `oauth_tokens_history` | n8n の OAuth refresh_token 管理 | **secret** |

### `campwill-ec.mart` — 分析用集計済データ（**PII ゼロ** — customer_email は SHA256 hash 化、これを使う）

| テーブル | 用途 |
|---|---|
| `ec_daily_pnl` | 日次 PnL（売上・原価・送料・粗利） |
| `ec_channel_roi` | チャネル別 日次 ROI (v2.0 準拠: ec_order_enriched.channel_classified + Klaviyo 5d carve、ec_channel_attribution_weekly と整合) |
| `ec_klaviyo_conversion` | Klaviyo メール起点 CV (**v2 last-click 5d attribution**: Clicked Email event → 5 日以内 order を last-click campaign に per-order 帰属。旧版 profile join 単純合算は 45〜360 倍過大集計、2026-07-07 全面刷新) |
| `ec_weekly_summary` | 週次サマリ |
| `ec_customer_profile` | 顧客 1 行（休眠フラグ・お気に入り SKU 等、180 日休眠定義） |
| `ec_cohort_ltv` | コホート × 月次 LTV |
| `ec_repeat_pattern` | リピート order_index 1-10 + 間隔分析 |
| `ec_sku_trend` | SKU の MoM/YoY + rising/declining 分類 |
| `ec_search_to_purchase` | SC 検索 → 購入導線 |
| `ec_attribution_first_last` | 顧客 1 行 = 初回 vs 最終流入チャネル (v2.0 準拠: ec_order_enriched.channel_classified + Klaviyo 5d carve 継承、独自 CASE 廃止) |
| `ec_seo_opportunity` | SEO 機会金額化（SC × Rakko 統合） |
| `ec_competitor_gap` | 競合のみ獲得 KW（自社未獲得） |
| `ec_inventory_health` | ⚠️ **使用不可** (倉庫移管で OPENLOGI 在庫が 0、SQ 停止中)。在庫ステータス分類 |
| `ec_storage_cost_estimated` | ⚠️ **使用不可** (同上)。OPENLOGI 推定保管費用 |
| `ec_page_ux_health` | **Page 別** UX 健康度スコア (engagement_rate/scroll_90/bounce/CV + Web Vitals LCP/INP/CLS、30d 集計、GA4 + CrUX 由来)。商品ページ・LP・記事の改善優先度判断に |
| `ec_review_enriched` | Judge.me レビュー 1 行 = 1 row の wide fact (PII ゼロ、ec_customer_profile JOIN 済)。商品評価分析・低評価監視・リピーター vs 新規傾向 |
| `ec_initiatives` | **施策マスタ** (AI 自動抽出、PII 除去済)。Slack/Backlog から Claude が日次抽出 |
| `ec_initiative_results` | **施策の効果検証** (実施日 ±7 日窓で revenue/cvr/klaviyo_cv を pre/post 比較、overlap_warning 付き) |
| `ec_customer_user_crosswalk` | customer_email × GA4 user_pseudo_id (cross-device 紐付け、ec_order_enriched が依存) |
| `ec_order_enriched` | **横断分析の起点 wide fact (注文 1 行 = 1 row)** — attribution + GA4 + 返金 + lifecycle + cross-device lead time。ad-hoc 分析はまずこれ ([クエリ例](docs/queries/ec_order_enriched_examples.md)) |
| `ec_order_line_enriched` | **SKU 視点の起点 wide fact (line item 1 行 = 1 row)** — SKU/quantity/unit_price/line 返金 + channel + lifecycle。SKU 別売上 / 返品率 / SKU × チャネル分析はこれ ([クエリ例](docs/queries/ec_order_line_enriched_examples.md)) |
| `ec_channel_attribution_weekly` | **組織標準: 週次チャネル別売上貢献** — Shopify last-touch + Klaviyo Campaigns carve from direct/other/unknown。マーケ予算配分・効果測定の単一指標。詳細仕様: [`docs/attribution-model.md`](docs/attribution-model.md) ([クエリ例](docs/queries/ec_channel_attribution_examples.md)) |
| `ec_cost_master` (VIEW) | SKU 単価マスタ（Shopify products から自動派生） |
| `ec_shipping_rules` | 送料マスタ（seed） |
| `ec_openlogi_sku_size_map` | SKU→size_category マッピング（seed、OPENLOGI 保管費用推定用） |
| `ec_openlogi_storage_rate` | size_category→日額単価テーブル（seed） |

---

## コスト・ガードレール（必読）

BigQuery on-demand: **$6.25/TB スキャン**。誤クエリで TB 飛ばないよう以下を遵守:

1. **`maximum_bytes_billed` を必ず付ける**（10 GB 上限）
   ```bash
   bq query --use_legacy_sql=false --maximum_bytes_billed=10737418240 "SELECT ..."
   ```
   `~/.bigqueryrc` に `--maximum_bytes_billed=10737418240` 設定済なら不要。

2. **partition / cluster を意識**: 日付フィルタを必ず付ける
   ```sql
   -- BAD: full scan
   SELECT * FROM `campwill-ec.raw.ec_shopify_orders`

   -- GOOD: partition 効く
   SELECT * FROM `campwill-ec.raw.ec_shopify_orders`
   WHERE order_date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
   ```

3. **本番クエリの前に dry-run**:
   ```bash
   bq query --use_legacy_sql=false --dry_run "SELECT ..."
   # → 「This query will process X bytes.」を確認
   ```

4. **raw を直接叩く前に mart で代替できないか確認**: mart は集計済で軽い

5. プロジェクト全体に **1 TB/user/day の Custom Quota 設定済**（暴発時は強制ブロック）

---

## やってはいけないこと

- ❌ raw の email / phone を Slack や外部に送信（PII 漏洩）
- ❌ mart は PII ゼロ (`customer_email_hash` で hash 化済)。逆引きしたい場合は raw 権限保持者に依頼 or Klaviyo / Shopify 管理画面で対応
- ❌ **本番 mart テーブルへの直接書込み**（DataViewer 権限のみ）。派生表が必要なら `sandbox_<姓>` で自分で作る
- ❌ `.keys/` 配下のファイルを git add（既に `.gitignore` 除外、絶対に外さない）
- ❌ `SELECT *` を partition フィルタなしで叩く（コスト爆発）
- ❌ `--maximum_bytes_billed` 無しのクエリ
- ❌ raw からの集計を独自に量産（mart に同等のロジックがあるか先に確認）

---

## アクセス階層（権限ポリシー）

| dataset | 目的 | 付与基準 |
|---|---|---|
| `mart` (READER) | PII ゼロの分析用。**まずここから** | 全員 (デフォルト) |
| `raw` (READER) | PII / 認証情報含む原データ | **Shopify 管理画面で PII を閲覧できる立場と同等の信頼** が必要。`oauth_tokens` / `oauth_tokens_history` の n8n refresh_token / client_secret も plaintext で見えるので、付与時に本人に明示 |
| `sandbox_<姓>` (OWNER) | 個人専用、派生表 / ad-hoc 分析 / 個人 Looker Studio dashboard | 希望者全員。本人 OWNER、他は基本見えない |

### 付与スクリプト

```bash
# 例: mart のみ
bash scripts/grant-bq-access.sh user@campwill.me

# 例: mart + raw + 個人 sandbox (推奨セット for EC 業務担当)
bash scripts/grant-bq-access.sh user@campwill.me --with-raw --with-sandbox
```

`sandbox_<姓>` は email の `@` 前から `_` 区切り最後の単語を姓として推定（`h_nakamura@...` → `sandbox_nakamura`）。同姓が複数いる場合は手動で `sandbox_nakamura_h` 等にリネーム。

### sandbox の使い方

```sql
-- 自分用の派生 mart
CREATE OR REPLACE TABLE `campwill-ec.sandbox_nakamura.my_weekly_kpi`
PARTITION BY week_start
AS SELECT ... FROM `campwill-ec.mart.ec_order_line_enriched` WHERE ...;

-- 外部 CSV を upload して JOIN (bq load 経由)
-- 個人 Scheduled Query を BQ UI から登録 (自分の sandbox 内宛先)
```

退職 / 異動時は project owner が `bq rm -r -f campwill-ec:sandbox_<姓>` で削除、または引き継ぎ。

---

## ローカル環境（Windows 前提）

```
gcloud パス: C:\Users\<user>\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd
bq パス:    C:\Users\<user>\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\bq.cmd
```

### Bash で bq / gcloud 実行時の必須環境変数

日本語 description のスキーマ JSON が cp932 で読めずクラッシュするため:

```bash
export PATH="/c/Users/<user>/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/<user>/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
```

### 認証（初回のみ）

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project campwill-ec
```

---

## 典型クエリ例

```sql
-- 直近 7 日の PnL
SELECT * FROM `campwill-ec.mart.ec_daily_pnl`
WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 7 DAY)
ORDER BY date DESC;

-- チャネル別 ROI（直近 30 日）
SELECT channel, SUM(revenue) AS rev, SUM(ad_cost) AS cost,
       SAFE_DIVIDE(SUM(revenue), SUM(ad_cost)) AS roas
FROM `campwill-ec.mart.ec_channel_roi`
WHERE date >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY)
GROUP BY channel
ORDER BY roas DESC;

-- SEO 機会 Top 20（推定損失額順）
SELECT keyword, opportunity_type, estimated_monthly_loss_yen, sc_recent_position
FROM `campwill-ec.mart.ec_seo_opportunity`
WHERE estimated_monthly_loss_yen > 0
ORDER BY estimated_monthly_loss_yen DESC
LIMIT 20;

-- 休眠顧客 Top 100（180 日購入なし）
SELECT customer_email_hash, last_order_date, total_orders, total_revenue
FROM `campwill-ec.mart.ec_customer_profile`
WHERE is_dormant = TRUE
ORDER BY total_revenue DESC
LIMIT 100;

-- 組織標準: 直近 8 週のチャネル別売上貢献 (Klaviyo Campaigns 含む)
SELECT week_start, channel, revenue, share_pct
FROM `campwill-ec.mart.ec_channel_attribution_weekly`
WHERE week_start >= DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 56 DAY)
ORDER BY week_start DESC, revenue DESC;
```

---

## n8n ワークフロー（参考）

`n8n/workflows/` 配下の JSON。Active 中:
- `shopify-orders-incremental` (毎日 04:30 JST)
- `shopify-products-daily` (毎日 02:00 JST)
- `klaviyo-{campaigns,profiles}` (毎日 03:00 JST)
- `instagram-organic` (毎日 03:40 JST、Meta Graph API v21.0 で直近 30 日の Reels/投稿の media+insights を取得。impressions は views 値、Reels 用に rename。Meta Page Access Token は永続)
- `meta-ads-daily` (毎日 05:15 JST、Meta Marketing API /act_XXX/insights を叩いて raw.ec_meta_ads_insights + raw.ec_meta_ads_insights_actions を投入。System User token を raw.oauth_tokens で管理、BQ DTS Facebook Ads を KUBELL-1095 で完全置換したもの)
- `meta-ads-token-refresh` (毎週水曜 04:00 JST、fb_exchange_token で System User token を 60 日サイクルで rotate)
- `microsoft-ads-incremental` (毎日 03:10 JST、2 日 lookback 設計。post-insert cleanup で dedup 自動化済)
- `yahoo-ads-incremental` (毎日 03:20 JST、2 日 lookback 設計。post-insert cleanup で dedup 自動化済)
- `rakko-inflow-weekly` (月曜 04:00 JST)
- `clarity-metrics-daily` (毎日 10:00 JST、1 call/day = Channel dim。Clarity API は dim パラメータを無視して常に Channel breakdown を返すため元 6 dim 呼びは全て同一結果を返していた。ec_ux_health 廃止に合わせて 1 回に集約、quota 節約)
- `klaviyo-events-daily` (毎日 04:15 JST、Clicked Email events → attribution per-order tag)
- `crux-history-daily` (毎日 05:00 JST、CrUX History API 経由 URL 別 Core Web Vitals → ec_page_ux_health の Web Vitals 列ソース)
- `judgeme-reviews-daily` (毎日 03:30 JST、Judge.me /api/v1/reviews → ec_judgeme_reviews、初回 backfill 729 件)
- `tiktok-ads` (毎日 03:15 JST、TikTok Marketing API /report/integrated/get → ec_tiktok_ads、TikTok stat_time_day 制限 28 日 rolling)
- `slack-messages-daily` (毎日 03:00 JST、Bot が join した channel の昨日分 → raw.ec_slack_messages、施策抽出元)
- `backlog-issues-daily` (毎日 03:10 JST、updatedSince 差分 → raw.ec_backlog_issues、施策抽出元)
- `initiative-extract-daily` (毎日 03:20 JST、EC 系 Slack+Backlog → Claude API → raw.ec_initiatives_raw)
- `shopify_gender_tagging_daily` (毎日 04:35 JST、前日 order を Dify 経由 gender 判定 → customer/order tag 付与。KUBELL-991 で n8n Pro Webhook → Starter batch 化)
- `cs-substitute-order-alert` (Webhook trigger、CS 業務用の代替注文アラート)
- `slackfile_upload_to_freee` (Slack file → freee accounting、月次経費処理)
- `ZoomAIComanionTranscript` / `ZommRecordingTranscript` (Zoom 会議録画・文字起こし取り込み)
- `error-handler` (Error Trigger → Slack #n8n_alert)

非稼働 (deactivated):
- `openlogi-inventory-daily` (倉庫を OPENLOGI → はぴロジへ移管したため、2026-10-09 停止。はぴロジ API 有無は確認中)
- `slack_to_google_sheets` (Webhook trigger、Slack app 側呼び出し無し、2026-07-07 deactivate)
- `shopify-customers-daily` (対応する raw table 削除済、2026-07-07 deactivate)

削除済:
- `re_slack_messages_daily` / `re_backlog_issues_daily` / `re_initiative_extract_daily` (campwill-realestate 廃止に伴い 2026-08-12 削除)

詳細は `n8n/docs/` 配下。

---

## ローカルフォルダ名と repo 名の差異

- **GitHub repo 名**: `campwill-data-platform`（新規 clone はこの名前のフォルダ）
- **既存運用者ローカル**: `campwill-ai-ready/`（OneDrive sync 都合で初期名のまま据え置き）

両者は同一リポジトリ。新規メンバーは `campwill-data-platform/` フォルダで運用される。

---

## 参考

- セットアップ手順: [docs/onboarding.md](docs/onboarding.md)
- 元仕様書: [docs/spec.md](docs/spec.md)
- GCP 初期セットアップ: [docs/setup-gcp.md](docs/setup-gcp.md)
- BQ Scheduled Queries: [n8n/docs/bq-scheduled-queries.md](n8n/docs/bq-scheduled-queries.md)
- 各種クレデンシャル設定: [n8n/docs/credentials-setup.md](n8n/docs/credentials-setup.md)
- **Attribution モデル組織標準ルール**: [docs/attribution-model.md](docs/attribution-model.md) — 予算配分/効果測定の単一指標
- **Web Vitals 仕込み手順**: [docs/web-vitals-instrumentation.md](docs/web-vitals-instrumentation.md) — Shopify theme に web-vitals snippet 追加、Phase 2 で page_ux_score に統合
- **施策自動記録セットアップ**: [docs/initiatives-setup.md](docs/initiatives-setup.md) — Slack Bot + Backlog + Anthropic credential 取得 + Bot invite 手順
- **BQ アナリスト Artifact**: [docs/bq-analyst-setup.md](docs/bq-analyst-setup.md) — Cloud Run プロキシ (`bq-proxy/`) + HTML Artifact (`docs/campwill-bq-analyst.html`) で mart を自然言語問い合わせ可能に。SQL ガード (SELECT-only / mart-only / 5GB 上限) + Anthropic API キーは Secret Manager 集中管理
- **Instagram オーガニック取り込み**: [docs/instagram-organic-setup.md](docs/instagram-organic-setup.md) — Meta App + Facebook Login 経由の Instagram Graph API で投稿の reach/views/likes/saves/engagement_rate を日次取得 (`raw.ec_instagram_organic`)
- **Backlog 起票運用**: グローバル `~/.claude/CLAUDE.md` 参照。`/backlog-from-plan` (議論済 plan → 慎重起票)、`/backlog-register` (即起票)、`/backlog-progress` (既存 issue 進捗・クローズ) の 3 Skill 体制
