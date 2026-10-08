# Attribution モデル — 組織標準ルール

> 本ドキュメントは、CAMPWILL EC 事業のチャネル別売上貢献を **組織として 1 つの指標で見る** ための真実源 (single source of truth)。
> 数字の出口は [`mart.ec_channel_attribution_weekly`](../bigquery/campwill-ec/mart/ec_channel_attribution_weekly.sql)。
>
> **v2.0 準拠 mart 群 (2026-07-07 統一完了)**:
> - source of truth: `mart.ec_order_enriched` (`channel_classified` + `klaviyo_clicked_within_5d`)
> - 依存 mart: `ec_channel_roi` / `ec_channel_attribution_weekly` / `ec_attribution_first_last` / `ec_order_line_enriched` — 全て同一定義参照 (drift 検出済み → 統一)
> - `ec_klaviyo_conversion` (last-click 5d attribution) は Klaviyo campaign 単体効果検証用の別モデル (Clicked Email event の per-order last-click)

## 目的

マーケ予算配分・効果測定の議論を「どのチャネルがいくら稼いだか」の単一の数字に基づいて行うため、attribution ルールを明文化・版管理する。

「チャネル間の重複は当然存在するが、組織として 1 つの数字をみんなで見る」ことが本仕組みのゴール。完璧な attribution は存在しないので、**合意したルールで継続的にチューニングする** プロセスごと回す。

---

## 現行モデル v2.0 (2026-05-19 制定、Klaviyo Events per-order override)

### channel_classified の値 (v2.1)

| 区分 | 値 |
|---|---|
| 有料 (ad_cost あり) | `google_paid` / `meta_paid` / `yahoo_paid` / `microsoft_paid` / `tiktok_paid` |
| 無料ショッピング | `google_shopping_free` / `microsoft_shopping_free` (Merchant Center 無料リスティング) |
| 自然検索 | `seo_google` / `seo_yahoo` / `seo_bing` / `seo_other` |
| SNS・その他 | `instagram_organic` / `social_youtube` / `line` / `ai_referral` / `referral` |
| メール | `email_klaviyo` (+ Klaviyo 5 日 click carve) |
| 不明 | `direct` / `unknown` / `other` (other は 0.5% 程度が正常) |

**判別ルールの要点**: utm_medium=product_sync/shop/shopping は Shopify の商品フィード URL で、有料のショッピング/P-MAX 広告でも無料リスティングでも同じ値になる。landing_site に広告クリック ID (gclid/gbraid/wbraid、Microsoft は msclkid) があれば有料、なければ無料と判定する (自動タグ付けは広告クリックにのみ付与されるため)。

### 採用ルール

1. **Shopify last-touch (`channel_classified`) を基底**
   - paid 広告 / SEO 検索 / SNS referrer の last-touch をそのまま尊重
2. **Klaviyo Events per-order override** (v2.0 から)
   - 各注文の `created_at` から **遡って 5日以内** に同 email が Klaviyo メールを **click** していたら、その注文を **email_klaviyo に再分類**
   - データソース: `raw.ec_klaviyo_events_latest` (Klaviyo Events API "Clicked Email" を取り込み)
   - 5日窓は Klaviyo dashboard デフォルト attribution window と整合
   - Click のみカウント (Open は除外、より conservative)
   - **Campaign / Flow を区別せず click したものは全て対象** (v2.0 では click event 取り込み時に区別していない、改善余地あり)
3. **集約 carve は廃止** (v1.x の direct/other/unknown pro-rata 機構は引退)
   - per-order が直接 reclassify するため不要
4. **粒度は週次** (`week_start` = 月曜起点)
5. **費用対効果列を同マートに同居** (`ad_cost` / `roas` / `cpa` / `net_revenue_after_ad_cost`)
   - paid 4 種は raw.ec_{google,meta,yahoo,microsoft}_ads から週次集計で JOIN
   - non-paid (organic / direct / unknown / email_klaviyo) は `ad_cost = NULL`

### 結果の性質
- 全 channel の `revenue` 合計 = Shopify 全注文金額 (差 0)
- `share_pct` の週内合計 = 100%
- `email_klaviyo` 行の `orders` は **per-order でカウント済** (v2.0 から、v1.x では NULL だった)
- `email_klaviyo` の `ad_cost` = NULL (subscription cost 未計上)
- **Events 取り込み開始 (2026-05-19) 以前の週**: Events データが無いため `email_klaviyo` = 0 表示。組織レビューでは「v2.0 切替日以降の数字を信頼」

---

## Tunable パラメータ (v2.0)

| パラメータ | 現行値 | 変更時の影響 | 変更場所 |
|---|---|---|---|
| Klaviyo click window | 5 日 (Klaviyo dashboard 設定継承) | 長くすると email_klaviyo↑、paid/organic↓ | `mart/ec_order_enriched.sql` の `klaviyo_clicked_within_5d` |
| Credit 配分 | **100% override** (Klaviyo wins) | 50/50 split など多touch 分配は別実装 | `mart/ec_channel_attribution_weekly.sql` の CASE |
| 集計粒度 | 週次 (月曜起点) | daily/monthly 派生は SQL 1 行 | view 追加 |
| Click 取得 metric | "Clicked Email" のみ | "Opened Email" も追加すれば Klaviyo↑ (より緩い基準) | `n8n/workflows/klaviyo-events-daily.json` |
| Campaign vs Flow 区別 | 区別せず click 全採用 | 区別すれば Flow click を除外可能 | Events transform で campaign_id 有無判定 |

---

## 公式根拠 (Klaviyo)

Klaviyo の attribution methodology を確認した結果、以下が判明:

- **Klaviyo の attribution は Klaviyo メッセージ内 (email/sms/push) のみ last-click**
  → 外部チャネル (Google/Meta/Yahoo) とは **公式に競合しない設計、重複を許容**
- profile_id ベース直結 (pixel/cookie 非依存)
  → Shopify order を email で profile に紐付け、attribution window 内に Klaviyo インタラクションあれば帰属
- デフォルト attribution window = **5 日** (email、2024-10-09 以降の新規アカウント)

**インプリケーション**: Klaviyo の数字は他チャネル attribution と公式に重複しているので、組織標準を作るには「重複部分をどこから差し引くか」を別途決める必要があった。本モデルは `direct/other/unknown` から carve することで解決している。

### 参照 URL
- https://help.klaviyo.com/hc/en-us/articles/1260804504250 (Understanding Klaviyo message attribution)
- https://help.klaviyo.com/hc/en-us/articles/115005248128 (Understanding message conversion tracking)
- https://help.klaviyo.com/hc/en-us/articles/11118357030555 (How to change your attribution model)
- https://help.klaviyo.com/hc/en-us/articles/36457929459227 (Understanding attribution model types)

---

## 既知の制約 (Known Gaps) — v2.0 時点

1. **Events 取り込み開始日以前の歴史データ無し**: 2026-05-19 取り込み開始、過去 90日まで backfill。それ以前の週は email_klaviyo = 0 表示。歴史比較は v2.0 切替日以降で行う
2. **「click したから買った」vs「買う気だった人が click」の判別不可**: per-order tag は相関の存在を示すが因果関係ではない。Klaviyo は依然 over-attribution の可能性 (但し dashboard と同じ基準なので組織で議論しやすい)
3. **Campaign / Flow の click 区別なし**: 現状は全 click を採用。Flow click (welcome / abandoned cart) も Klaviyo に credit が行く。Campaign のみに絞る場合は events transform で `campaign_id IS NOT NULL` フィルタ追加
4. **Open は除外**: より緩い「open within 5d」基準も理論上採用可能だが、現状は conservative に click のみ
5. **raw 重複対策は view 経由のみ**: n8n が日次 INSERT で堆積するので raw 本体は重複したまま。`raw.ec_klaviyo_*_latest` view で dedup している。根本対策 (n8n MERGE 化) は別タスク
6. **Klaviyo subscription cost 未計上**: paid 4 種以外 (Klaviyo / SEO / IG organic / direct) は `ad_cost = NULL`。人件費は経営判断として考慮対象外 (sunk cost 扱い)

---

## 変更履歴 (Change Log)

| Version | Date | Author | Change | Rationale |
|---|---|---|---|---|
| 2.1 | 2026-10-08 | s_miyazaki | **channel_classified の分類漏れ解消** ('other' 27% → 0.5%)。(1) Google/Microsoft のショッピング・P-MAX 流入 (utm_medium=product_sync/shop/shopping) を **広告クリック ID (gclid/gbraid/wbraid/msclkid) の有無で有料/無料に判別** し、`google_paid` / `google_shopping_free` (新設) 等へ (2) yahoo/display → `yahoo_paid`、bing/pmx → `microsoft_paid` (3) ig・yt/organic_social を meta_paid から `instagram_organic` / `social_youtube` へ (4) Meta 配信面 (th/an/msg/未展開マクロ) を meta_paid に (5) `line` / `ai_referral` / `seo_other` / `referral` / `tiktok_paid` を新設 (6) 自サイト referrer (ku-bell.com) を direct に、google.co.jp を seo_google に (7) ec_customer_profile の独自 CASE を廃止し本列を参照 (8) ec_channel_roi に TikTok 広告費を接続 | BQ 計測監査で 'other' の正体が判明。Shopify の商品フィード URL (sag_organic) は有料ショッピング広告でも無料リスティングでも同じ utm になるため、utm だけでは判別不能だった。結果、Google 広告の売上が約 3 割過小計上 (9月 ROAS 3.57 → 4.57)、無料リスティング (売上の約 9%) が不可視、Yahoo ディスプレイの売上が未計上 (広告費だけ計上) だった |
| 2.0.1 | 2026-07-07 | s_miyazaki | **v2.0 モデルを ec_channel_roi / ec_attribution_first_last に横展開して統一**。両 mart は独自 CASE 分類を廃止し `ec_order_enriched.channel_classified` + `klaviyo_clicked_within_5d` を採用。合わせて `ec_klaviyo_conversion` は last-click 5d attribution 方式に全面刷新 (旧 profile join 単純合算は 45〜360 倍過大集計) | BQ 全体 audit で ec_channel_roi と ec_channel_attribution_weekly の revenue 総額が 20〜30% 系統ズレ発覚。source が違うため必然的に drift。全 attribution mart を single source (ec_order_enriched) に統一して未来永劫の drift を防ぐ |
| 2.0 | 2026-05-19 | s_miyazaki | **Klaviyo Events API 取り込み開始**、per-order override 方式に転換。Click within 5d で email_klaviyo に再分類。集約 carve は廃止 | クロスチャネル過小評価 (Google ad → Klaviyo click → 購入 等) を per-order レベルで捕捉。Klaviyo dashboard と同じ click+5d 基準で組織内議論しやすく |
| 1.2 | 2026-05-19 | s_miyazaki | `raw.ec_google_ads` view を AccountBasicStats ベースに修正 (旧 CampaignBasicStats × Campaign INNER JOIN で 90% の cost が落ちていた)。google_paid の ROAS が 59x → 3.5x の現実的水準に補正 | 旧 view は campaign メタ作成日より古い stats date が JOIN 条件で消えていた。campaign 別ブレイクダウンは downstream で未使用だったため AccountBasicStats で集約に切替 |
| 1.1 | 2026-05-19 | s_miyazaki | `ad_cost` / `roas` / `cpa` / `net_revenue_after_ad_cost` 列を同マートに追加。paid 4 種 (google/meta/yahoo/microsoft) に対応 | 費用対効果を「横並びで」見たいという user 要望。チャネル間の予算配分判断を売上だけでなく ROAS ベースで議論可能に |
| 1.0 | 2026-05-19 | s_miyazaki | 初版制定。Shopify last-touch + Klaviyo Campaigns carve from direct/other/unknown 方式。週次粒度 | 組織として Klaviyo を正しく評価する単一指標を構築。メルマガ担当の貢献を可視化する社員要望に応える |

---

## ロードマップ (改善候補)

- **Phase 3**: MMM (Marketing Mix Modeling) — 回帰ベースで各チャネル incremental contribution を統計推定。データ量が増えてから着手
- **Phase 4**: 役職別ダッシュボード自動化 (Klaviyo 担当 / SEO 担当 / 広告担当 それぞれの KPI を本マートから派生)
- Campaign vs Flow click の区別 (人間メルマガ click だけ採用、Welcome/Cart Abandon click は除外する派)
- Open イベントも取り込んで「open within 5d」基準も併用検討
- n8n raw 重複の根本対策 (MERGE/UPSERT 化、ワークフロー横断)
- Holdout 実験 (Klaviyo 20% 停止 vs 100% の incremental ROAS 直接測定)

---

## チューニングプロセス

1. 提案者が本ドキュメント (`docs/attribution-model.md`) に PR で **変更案 + Rationale** を書く (新 Version 行を Change Log に追加)
2. SQL ファイル (`bigquery/campwill-ec/mart/ec_channel_attribution_weekly.sql`) を更新
3. PR description に **数字インパクト試算** を貼る (新旧 model 比較、影響のある週の vs 全 channel revenue 差分)
4. レビュー承認後 merge
5. `python scripts/setup-scheduled-queries.py` で SQ 更新
6. 該当 mart を手動再生成し数字確認
7. Slack #data-platform 等で「attribution v{X.X} に更新しました」と告知

---

## 関連

- 出力マート (組織標準週次): [`mart.ec_channel_attribution_weekly`](../bigquery/campwill-ec/mart/ec_channel_attribution_weekly.sql)
- v2.0 統一 mart 群 (2026-07-07 統一):
  - [`mart.ec_channel_roi`](../bigquery/campwill-ec/mart/ec_channel_roi.sql) — 日次 ROI (ad_cost JOIN)
  - [`mart.ec_attribution_first_last`](../bigquery/campwill-ec/mart/ec_attribution_first_last.sql) — 顧客 1 行 初回 vs 最終流入
  - [`mart.ec_order_line_enriched`](../bigquery/campwill-ec/mart/ec_order_line_enriched.sql) — SKU 視点 wide fact (channel_classified を JOIN 継承)
  - [`mart.ec_klaviyo_conversion`](../bigquery/campwill-ec/mart/ec_klaviyo_conversion.sql) — Klaviyo campaign 単体効果 (last-click 5d、上記統一とは別モデル)
- 上流 wide fact (per-order tag): [`mart.ec_order_enriched`](../bigquery/campwill-ec/mart/ec_order_enriched.sql) — `channel_classified` + `klaviyo_clicked_within_5d` 列
- Events dedup view: [`raw.ec_klaviyo_events_latest`](../bigquery/campwill-ec/raw/ec_klaviyo_events_latest.view.sql)
- Campaigns dedup view (旧 v1.x で使用): [`raw.ec_klaviyo_campaigns_latest`](../bigquery/campwill-ec/raw/ec_klaviyo_campaigns_latest.view.sql)
- n8n Events workflow: `n8n/workflows/klaviyo-events-daily.json` (毎日 04:15 JST)
- クエリ例集: [`docs/queries/ec_channel_attribution_examples.md`](queries/ec_channel_attribution_examples.md)
- 全体ガイド: [`CLAUDE.md`](../CLAUDE.md)
