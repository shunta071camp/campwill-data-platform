# Judge.me レビュー連携セットアップ

## 概要
Shopify ストア (kubell.myshopify.com) の Judge.me レビューを daily で BigQuery に取り込む。
- 取得 endpoint: `https://api.judge.me/api/v1/reviews`
- 取り込み先: `raw.ec_judgeme_reviews` (dedup view: `raw.ec_judgeme_reviews_latest`)
- 初回 = 全件 backfill、以降 = 過去 7日分 incremental (moderation 状態変化を拾える)

サイト改修不要、API token 取得のみ。

---

## 必要なユーザー作業 (5 分)

### Step 1: Judge.me 管理画面で API token を取得

1. Judge.me 管理画面にログイン
2. **Settings → Integrations** に移動
3. 画面右上の **View API tokens** ボタンをクリック
4. 表示される 3 つのうち **Private API Token** をコピー
   - (Public API Token は read-only だが publicly safe、Private は server-side 用、より権限大)
   - Shop domain も併記されてるはず: `kubell.myshopify.com` ← これは workflow に既にハードコード済

### Step 2: n8n credential 作成

1. https://campwill.app.n8n.cloud/projects/xSwFSDmagTleuj5x/credentials/new
2. **Type: Query Auth** を選択
3. 入力:
   - **Credential Name**: `Judge.me API`
   - **Name** (パラメータ名): `api_token`
   - **Value**: コピーした Private API Token
4. 保存 → URL の credential ID をコピー

### Step 3: チャットで返信

```
credential ID: XXXXXXXX
```

→ 私が workflow に埋め込み → push → manual trigger で初回 backfill → 検証。

---

## 仕組み

```
[n8n Schedule 03:30 JST daily]
  ↓
BigQuery: 最新 review_created_at - 7日 を since 取得 (初回は 2020-01-01)
  ↓
Judge.me API: GET /api/v1/reviews
  Query: shop_domain=kubell.myshopify.com, api_token=*, per_page=100,
         page=1, created_at_min=<since>
  ↓ pagination loop (page 1 → 2 → ... → 空 or 200 ページで打ち切り)
  ↓
Transform: 各 review を 22 列に展開 + raw_payload 保存
  ↓
BigQuery: insert raw.ec_judgeme_reviews
  → dedup view が review_id ベースで最新行を提供
```

## raw 列構成

| 列 | 型 | 説明 |
|---|---|---|
| review_id | INT64 | Judge.me ID (主キー) |
| product_external_id | STRING | Shopify product ID (ec_shopify_products との JOIN キー) |
| product_handle / product_title | STRING | 商品識別 |
| rating | INT64 | 1-5 |
| title / body | STRING | レビュー本文 |
| reviewer_name / reviewer_email | STRING | **PII**、mart で hash 化推奨 |
| verified_buyer | BOOL | 実購入者か |
| curated / published / hidden / featured | BOOL/STRING | モデレーション状態 |
| source | STRING | 収集経路 (judgeme / google / facebook 等) |
| ip_address | STRING | **PII** |
| has_published_pictures / videos | BOOL | メディア有無 |
| pictures_json | STRING | 画像 URL 配列 (JSON 文字列) |
| review_created_at / updated_at | TIMESTAMP | Judge.me 上タイムスタンプ |
| raw_payload | STRING | review object 全体 (debug) |
| inserted_at | TIMESTAMP | BQ 挿入時刻 (dedup view 用) |

## 想定される使い方

### 商品別評価集計 (mart 化候補)
```sql
SELECT
  product_external_id,
  product_title,
  COUNT(*)            AS total_reviews,
  AVG(rating)         AS avg_rating,
  COUNTIF(rating <= 2) AS negative_count,
  COUNTIF(verified_buyer) AS verified_count
FROM `campwill-ec.raw.ec_judgeme_reviews_latest`
WHERE published = TRUE
GROUP BY 1, 2
ORDER BY total_reviews DESC;
```

### 低評価レビュー直近 30 日 (改善 ALERT)
```sql
SELECT review_created_at, rating, title, body, product_handle
FROM `campwill-ec.raw.ec_judgeme_reviews_latest`
WHERE review_created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND rating <= 2 AND published = TRUE
ORDER BY review_created_at DESC;
```

### 注文 × レビューの紐付け (mart で実装可能)
- `reviewer_email` を hash 化して `ec_order_enriched.customer_email_hash` と JOIN
- 「購入したお客様の何 % がレビューを書くか」「レビュー前後の購入頻度変化」等の分析

## PII 取扱

raw に reviewer_email と ip_address があるが、mart 層では:
- `customer_email_hash = TO_HEX(SHA256(LOWER(reviewer_email)))` で hash 化
- ip_address は基本的に mart 持ち出さず raw だけに留める

CLAUDE.md 「やってはいけないこと」「mart の email は hash」と同じポリシー適用。

## quota / コスト

- Judge.me API: 明示 rate limit なし (ただし常識的にスロットリングは存在)
- daily run: 1-3 ページ (= 100-300 review/日) が普通、初回 backfill のみ大量
- 完全無料 (Judge.me アプリ自体は別途課金)

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `401 Unauthorized` | api_token 不正 / 期限切れ | Judge.me 管理画面で再取得 |
| `404 Not Found` | shop_domain ミスマッチ | workflow の hardcoded shop_domain 確認 |
| backfill 中で 200 page 上限到達 | レビュー数膨大 | `maxRequests: 200` を増やす or 日付区切り backfill 化 |
| `published=false` ばかり | 自動公開 OFF 設定 | Judge.me 設定 → Auto Publish を見直すか、本マートで `published=true` フィルタ |
