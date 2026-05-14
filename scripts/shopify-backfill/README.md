# Shopify Orders Initial Backfill

ローカル Python スクリプトで Shopify 全注文を BigQuery `raw.ec_shopify_orders` に一発投入する。

## なぜ別スクリプトなのか

n8n cloud のメモリ制限で 15,000 件規模の初回バックフィルは OOM する。このスクリプトは：

- **Shopify Bulk Operations API** を使う → 非同期で全件 JSONL を生成し、Shopify CDN から 1 ファイルでダウンロード
- **`bq load`** で BigQuery に投入 → ストリーミング INSERT より 10〜100倍高速
- **stdlib のみ** — `pip install` 不要

日次差分は引き続き `n8n/workflows/shopify-orders-incremental.json` で動く。このスクリプトは初回のみの実行を想定。

---

## 前提条件

- Python 3.10+（user 環境は 3.13）
- gcloud SDK 認証済み（`bq` コマンドが PATH 上にあること）
- Shopify Dev Dashboard で n8n ETL アプリを kubell ストアにインストール済み
- BigQuery `campwill-ec.raw.ec_shopify_orders` テーブル作成済み

---

## セットアップ

```bash
cd "c:/Users/user/OneDrive/デスクトップ/AI/campwill-ai-ready/scripts/shopify-backfill"
cp .env.example .env
# .env を編集して SHOPIFY_CLIENT_SECRET を入れる
```

`.env` は `.gitignore` で除外されているのでコミットされません。

---

## 実行

```bash
# gcloud / bq の PATH 設定（毎回）
export PATH="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_PYTHON="/c/Users/user/AppData/Local/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

python backfill.py
```

実行ログ例：

```
Got access token via client_credentials grant (length=64)
[1/5] Submitting bulk operation...
      Started bulk op id=gid://shopify/BulkOperation/123 status=CREATED
[2/5] Polling status every 15s...
      [17:30:00] status=RUNNING objectCount=2400 fileSize=?
      [17:30:15] status=RUNNING objectCount=8200 fileSize=?
      [17:30:30] status=COMPLETED objectCount=15847 fileSize=42583921
[3/5] Downloading JSONL -> data/shopify-orders-raw.jsonl
      Saved 42,583,921 bytes
[4/5] Transforming shopify-orders-raw.jsonl -> shopify-orders-bq.jsonl
      Parsed: 15,000 orders, 23,400 line items, 312 refunds
      Wrote 23,400 rows; skipped 0 orders without email
[5/5] bq load -> campwill-ec:raw.ec_shopify_orders
      bq load OK
```

15,000 件で目安 5〜15 分。

---

## 検証

```bash
bq query --use_legacy_sql=false --project_id=campwill-ec \
  'SELECT EXTRACT(YEAR FROM created_at) AS y, COUNT(DISTINCT order_id) AS orders \
   FROM `campwill-ec.raw.ec_shopify_orders` GROUP BY y ORDER BY y'
```

年別の注文数が Shopify 管理画面と一致するか確認。

---

## 中間ファイル

`data/` 以下に生成される（`.gitignore` で除外）：

| ファイル | 内容 |
|---|---|
| `shopify-orders-raw.jsonl` | Shopify Bulk API の生 JSONL |
| `shopify-orders-bq.jsonl` | BigQuery スキーマに変換済み |

デバッグや再実行（`bq load` だけ再実行など）に使える。

---

## トラブルシュート

### `Failed to get access token (HTTP 400) ... application_cannot_be_found`

n8n ETL アプリが kubell ストアに**インストールされていない**。Shopify Dev Dashboard でインストール手順をやり直す。

### `Bulk operation ended unexpectedly: { ... errorCode: ... }`

Shopify 側のエラー。レスポンスの `errorCode` を確認：
- `ACCESS_DENIED`: スコープ不足。Dev Dashboard で `read_orders` `read_all_orders` を有効化
- `INTERNAL_SERVER_ERROR`: 一時的な Shopify 障害。1〜2 時間後に再試行

### `bq load failed`

`data/shopify-orders-bq.jsonl` を `head` して中身確認。スキーマ違反の可能性。
よくあるのは：
- `customer_email` が NULL → スクリプトでスキップしているはずだが念のため確認
- `quantity` が 0 → BigQuery `INTEGER` で REQUIRED でないが NULL になっているか確認

### 重複投入したらどうする？

`bq load` は append-only なので、複数回実行すると重複行ができる。重複削除は：

```sql
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
