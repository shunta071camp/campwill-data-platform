# BQ アナリスト Artifact セットアップ

## 概要

自然言語で BigQuery `mart` テーブルに問い合わせる Web UI。

```
ユーザー質問 → Claude API が SQL 生成 → Cloud Run プロキシ経由で BQ 実行 → 結果テーブル + Claude が示唆
```

- **何ができる**: 「直近 7 日のチャネル別 ROAS」「メタ広告の比較記事 CP の効果」等を自然言語で聞いて表 + 示唆を取得
- **何が守られる**: SELECT のみ + mart 限定 + 1 クエリ 5 GB 上限 + クエリ自動 LIMIT 1000
- **誰が使える**: 共有 X-API-Key を持つ社員 (管理者から配布)
- **PII**: mart は元々 PII ゼロ (email/phone はハッシュ化済)、`ec_initiatives.description` は社内議論抜粋 (内部限定情報)

---

## 構成

| 構成要素 | 場所 |
|---|---|
| Cloud Run プロキシ | `campwill-ec` project の `bq-analyst-proxy` (asia-northeast1) |
| Service Account | `looker-studio-reader@campwill-ec.iam.gserviceaccount.com` (流用) |
| Anthropic API キー | Secret Manager `bq-analyst-anthropic-key` |
| 共有 X-API-Key | Secret Manager `bq-analyst-shared-secret` |
| HTML Artifact | [docs/campwill-bq-analyst.html](campwill-bq-analyst.html) (シングルファイル) |

---

## 管理者向け: 初回セットアップ (約 20 分)

### Step 1: gcloud 認証 + プロジェクト切替

```bash
gcloud auth login
gcloud config set project campwill-ec
```

### Step 2: Anthropic API キーを Secret Manager に投入

既存の `sk-ant-...` を流用 (n8n と同じキーで OK):

```bash
# Anthropic Console (https://console.anthropic.com/settings/keys) で発行済キーを使う
read -s -p "Anthropic API key (sk-ant-...): " ANTHROPIC_KEY
echo
echo -n "${ANTHROPIC_KEY}" | gcloud secrets create bq-analyst-anthropic-key --data-file=-
unset ANTHROPIC_KEY
```

### Step 3: 共有 X-API-Key を生成して投入

```bash
openssl rand -hex 16 | gcloud secrets create bq-analyst-shared-secret --data-file=-
# 値を取得 (社員配布用に控える)
gcloud secrets versions access latest --secret=bq-analyst-shared-secret
```

### Step 4: SA に Secret アクセス権限を付与

```bash
SA="looker-studio-reader@campwill-ec.iam.gserviceaccount.com"
for SECRET in bq-analyst-anthropic-key bq-analyst-shared-secret; do
  gcloud secrets add-iam-policy-binding ${SECRET} \
    --member="serviceAccount:${SA}" \
    --role="roles/secretmanager.secretAccessor"
done
```

### Step 5: Cloud Run にデプロイ

```bash
bash bq-proxy/deploy.sh
```

→ デプロイ完了後、URL と X-API-Key が表示される。これを社員に配布。

### Step 6: 動作確認 (curl)

```bash
URL=$(gcloud run services describe bq-analyst-proxy --region asia-northeast1 --format='value(status.url)')
KEY=$(gcloud secrets versions access latest --secret=bq-analyst-shared-secret)

# ヘルスチェック
curl ${URL}/health

# クエリ正常系
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

---

## 利用者向け: 使い方 (約 2 分)

### Step 1: 必要なもの

管理者から配布される:
- **Cloud Run URL** (例: `https://bq-analyst-proxy-xxx-an.a.run.app`)
- **X-API-Key** (32 文字英数字)

### Step 2: HTML を開く

3 通り:

**A) ローカルファイルとして開く**
- リポジトリの [docs/campwill-bq-analyst.html](campwill-bq-analyst.html) をダウンロード → ダブルクリックでブラウザが開く

**B) Claude.ai の Artifact として開く** (推奨)
- Claude.ai に HTML 内容を貼り付け → 「これを Artifact として表示」と依頼 → サイドペインで利用

**C) 社内 GitHub Pages / 内部 Web で公開**
- リポジトリの設定で GitHub Pages を有効化、または社内サーバに置く

### Step 3: 接続設定

1. 右上 **⚙ 設定** をクリック
2. **Cloud Run URL** と **X-API-Key** を入力
3. **保存** → ブラウザの localStorage に保存される (毎回入力不要)

### Step 4: 質問する

クイックアクションボタン:
- 📢 **広告分析** — チャネル別 ROAS / CPA
- 📈 **チャネル ROI** — 週次推移
- 💰 **粗利分析** — SKU 別実質粗利率
- 📧 **Klaviyo 分析** — メール CV
- 🧪 **施策追跡** — 効果検証付き施策一覧

または自由入力で:
- 「直近 30 日の購入者男女比」
- 「Meta 広告の比較記事 CP の ROAS」
- 「リピート購入者は何人?」
- 「先週の SKU 別売上トップ 10」
- 「Klaviyo の購読者の中で購入転換した人の割合」

⌘+Enter (Ctrl+Enter) でも送信可能。

---

## システムの仕組み (内部動作)

```
ユーザー質問
   ↓
[HTML] → POST /chat (messages) → [Cloud Run]
                                        ↓
                                  Anthropic Claude Haiku 4.5
                                        ↓
                                  SQL ブロックを含む応答
   ↓
[HTML] SQL 抽出 → POST /query (sql) → [Cloud Run]
                                            ↓
                                      SQL ガード (SELECT-only / mart-only / LIMIT)
                                            ↓
                                      BigQuery 実行 (maximum_bytes_billed=5GB)
                                            ↓
                                      {rows, count, elapsed_ms}
   ↓
[HTML] 結果テーブル表示
   ↓
[HTML] → POST /chat (質問 + SQL + 結果 50 行) → Claude
                                                      ↓
                                                  示唆を自然文で生成
   ↓
[HTML] 示唆表示
```

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| 「X-API-Key が間違っているか未設定」 | 401 | ⚙ 設定 で値を確認、管理者に正しい X-API-Key を確認 |
| 「mart テーブル以外は参照できません」 | SQL ガード 400 | Claude が誤って raw を参照しようとした。質問を「mart テーブルから」と明示 |
| 「SQL ガードで拒否されました」 | SELECT-only / forbidden-keyword | DDL/DML を含む質問は不可。SELECT のみで再質問 |
| 初回応答が 5-8 秒 | Cloud Run コールドスタート | 仕様。連続使用時は速い |
| BQ エラー: `Resources exceeded` | クエリが 5 GB を超えた | 質問に「直近 30 日」等の期間制約を入れる |
| 「Claude API が応答しません」 | Anthropic タイムアウト | しばらく待って再試行。連発時は管理者へ |
| 「Cloud Run プロキシに接続できません」 | URL 誤りまたは Cloud Run 停止 | ⚙ 設定 で URL を確認、Cloud Run コンソールで稼働状況確認 |

---

## コスト目安

| サービス | 月額目安 |
|---|---|
| Anthropic Claude Haiku 4.5 | ~$5 (1 質問あたり ~$0.001、月 5000 質問想定) |
| Cloud Run | <$1 (`min-instances=0`、リクエスト時のみ起動) |
| BigQuery クエリ | 既存 BQ クォータ内 (1 クエリ 5 GB 上限で抑制) |
| Secret Manager | <$1 |

**合計: 月 ~$7** (使用量に応じて変動)

---

## メンテナンス

### 共有 X-API-Key のローテーション (月 1 推奨)

```bash
# 新しい値を Secret Manager の新バージョンとして追加
openssl rand -hex 16 | gcloud secrets versions add bq-analyst-shared-secret --data-file=-

# 旧バージョンは Cloud Run が再起動後に自動で新版を読む
# (--update-secrets で latest を指定しているため)

# 新しい値を社員に配布
gcloud secrets versions access latest --secret=bq-analyst-shared-secret
```

### Anthropic キーの更新

```bash
echo -n "sk-ant-NEW..." | gcloud secrets versions add bq-analyst-anthropic-key --data-file=-
# Cloud Run を再デプロイ (最新版を読み直す)
gcloud run services update bq-analyst-proxy --region asia-northeast1
```

### Cloud Run のログ確認

```bash
gcloud run services logs read bq-analyst-proxy --region asia-northeast1 --limit 50
```

---

## セキュリティチェックリスト

- [x] Cloud Run プロキシで SELECT-only + mart-only + 危険キーワード拒否
- [x] LIMIT 1000 自動付与 + maximum_bytes_billed=5 GiB
- [x] Anthropic API キーは Secret Manager に保管 (HTML 側に露出しない)
- [x] X-API-Key で認証 (`/health` 以外)
- [x] CORS は `*` だが認証で保護
- [x] mart は元々 PII ゼロ (email/phone はハッシュ化)
- [x] `--max-instances=5` で被害規模を制限
- [x] `min-instances=0` でアイドル時コストゼロ

---

## 関連ファイル

- [bq-proxy/app.py](../bq-proxy/app.py) — Flask アプリ本体
- [bq-proxy/deploy.sh](../bq-proxy/deploy.sh) — Cloud Run デプロイスクリプト
- [docs/campwill-bq-analyst.html](campwill-bq-analyst.html) — HTML Artifact
- [CLAUDE.md](../CLAUDE.md) — BQ アクセス階層 + mart catalog
