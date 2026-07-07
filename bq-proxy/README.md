# bq-proxy

CAMPWILL BQ アナリスト用 Cloud Run プロキシ。HTML Artifact からの呼出を受け、SQL ガードを通して BigQuery を実行し、Anthropic API も中継する。

## エンドポイント

| メソッド + パス | 用途 |
|---|---|
| `GET /health` | ヘルスチェック (認証不要) |
| `POST /query` | SQL を受け取り SELECT-only + mart-only ガード → BQ 実行 → `{rows, count, elapsed_ms, sql_executed}` を返す |
| `POST /chat`  | `messages[]` を Claude Haiku 4.5 に中継。system プロンプトはサーバ側固定 (mart スキーマ + ルール) |

`/query` と `/chat` は `X-API-Key` ヘッダ (SHARED_SECRET と一致) が必須。

## SQL ガード

`sqlparse` で AST 化したうえで以下を順に検査:

1. コメント (`--` / `/* */`) を除去 (バイパス防止)
2. 危険キーワード (INSERT / UPDATE / DELETE / MERGE / DROP / CREATE / ALTER / TRUNCATE / GRANT / REVOKE / CALL / EXPORT) を含むと拒否
3. 先頭が SELECT または WITH でなければ拒否
4. 任意の `project.dataset.table` 参照が `campwill-ec.mart.*` 以外なら拒否
5. LIMIT が無ければ末尾に `LIMIT 1000` 自動付与
6. `maximum_bytes_billed = 5 GiB` 固定

## 環境変数

| 名前 | 出所 | 用途 |
|---|---|---|
| `ANTHROPIC_API_KEY` | Secret `bq-analyst-anthropic-key` | `/chat` の中継 |
| `SHARED_SECRET` | Secret `bq-analyst-shared-secret` | `X-API-Key` 照合 |
| `BQ_PROJECT` | `campwill-ec` (deploy.sh で固定) | BQ クライアントのプロジェクト |
| `BQ_LOCATION` | `asia-northeast1` | BQ ジョブのロケーション |
| `MAX_BYTES_BILLED` | `5368709120` (5 GiB) | クエリあたり最大スキャン量 |
| `ANTHROPIC_MODEL` | `claude-haiku-4-5` | Anthropic モデル |

## ローカル起動 (開発時)

```bash
cd bq-proxy
pip install -r requirements.txt

# 環境変数 (実値を入れる)
export BQ_PROJECT=campwill-ec
export BQ_LOCATION=asia-northeast1
export ANTHROPIC_API_KEY=sk-ant-...
export SHARED_SECRET=local-dev-secret
# BQ 認証 (Application Default Credentials)
gcloud auth application-default login

python app.py
# → http://localhost:8080

curl http://localhost:8080/health
```

## Cloud Run デプロイ

```bash
bash bq-proxy/deploy.sh
```

事前準備 (1 回のみ):

```bash
# Anthropic API キー
echo -n "sk-ant-..." | gcloud secrets create bq-analyst-anthropic-key --data-file=- --project=campwill-ec

# 共有秘密 (HTML 配布用)
openssl rand -hex 16 | gcloud secrets create bq-analyst-shared-secret --data-file=- --project=campwill-ec

# SA に Secret アクセス権限
SA="looker-studio-reader@campwill-ec.iam.gserviceaccount.com"
gcloud secrets add-iam-policy-binding bq-analyst-anthropic-key \
  --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor" --project=campwill-ec
gcloud secrets add-iam-policy-binding bq-analyst-shared-secret \
  --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor" --project=campwill-ec
```

## 検証 (デプロイ後)

```bash
URL=$(gcloud run services describe bq-analyst-proxy --region asia-northeast1 --format='value(status.url)')
KEY=$(gcloud secrets versions access latest --secret=bq-analyst-shared-secret)

# ヘルスチェック
curl ${URL}/health

# query 正常系
curl -X POST ${URL}/query \
  -H "X-API-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"sql":"SELECT date, channel, revenue FROM `campwill-ec.mart.ec_channel_roi` WHERE date >= DATE_SUB(CURRENT_DATE(\"Asia/Tokyo\"), INTERVAL 7 DAY) LIMIT 10"}'

# raw ガード (400 になるべき)
curl -X POST ${URL}/query \
  -H "X-API-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"sql":"SELECT * FROM `campwill-ec.raw.ec_shopify_orders`"}'

# chat
curl -X POST ${URL}/chat \
  -H "X-API-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"直近7日のチャネル別ROASをSQLで"}]}'
```
