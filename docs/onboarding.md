# 新メンバー オンボーディング

CAMPWILL Data Platform を Claude Code / Codex から扱えるようにする手順。所要時間 30 分程度。

---

## 前提

- Google Workspace アカウント `<your>@campwill.me` を持っている
- 管理者から `campwill-ec` プロジェクトへの IAM 付与が完了している（jobUser + dataViewer on mart）

未完了の場合は管理者に依頼。

---

## Step 1: gcloud CLI インストール

公式インストーラ: https://cloud.google.com/sdk/docs/install

Windows なら `.exe` をダウンロード → 「Run gcloud init」のチェックは外して終了。

確認:
```powershell
gcloud --version
# => Google Cloud SDK xxx.x.x 等が出れば OK
```

---

## Step 2: 認証

```bash
# 1. ユーザー認証（ブラウザ起動 → @campwill.me でログイン）
gcloud auth login

# 2. ADC（Application Default Credentials）— Python / SDK が使う
gcloud auth application-default login

# 3. デフォルトプロジェクトを campwill-ec に
gcloud config set project campwill-ec
```

確認:
```bash
gcloud config get-value account
# => <your>@campwill.me

gcloud config get-value project
# => campwill-ec
```

---

## Step 3: BigQuery アクセスのコストガード設定（必須）

クエリ単位で 10 GB 上限を強制。誤クエリで TB スキャンしないための保険。

`~/.bigqueryrc` を作成（既存があれば追記）:

```
[query]
--use_legacy_sql=false
--maximum_bytes_billed=10737418240
```

> `10737418240` = 10 GiB。これを超えるクエリは実行時に「bytes billed limit exceeded」で**失敗**します。意図的に大きいクエリを叩く場合は `--maximum_bytes_billed=` を CLI で上書き。

確認（10 GB 超のクエリを意図的に投げて弾かれることをテスト）:

```bash
# 動作するはず（mart の小さなテーブル）
bq query "SELECT * FROM \`campwill-ec.mart.ec_daily_pnl\` LIMIT 5"

# わざと 1 byte 制限で失敗確認
bq query --maximum_bytes_billed=1 "SELECT * FROM \`campwill-ec.mart.ec_daily_pnl\` LIMIT 5"
# => "Query exceeded limit for bytes billed: 1." で失敗 → ガードが効いている
```

---

## Step 4: Claude Code インストール

公式: https://docs.claude.com/en/docs/claude-code/setup

セットアップ後、CLI から `claude` コマンドが叩けることを確認。

---

## Step 5: リポジトリ clone

```bash
# 任意の作業ディレクトリで
git clone https://github.com/shunta071camp/campwill-data-platform.git
cd campwill-data-platform
```

> Private repo なので初回 push 時に GitHub 認証（HTTPS なら Git Credential Manager 経由でブラウザ認証）。

---

## Step 6: Claude Code 起動 + 動作確認

```bash
cd campwill-data-platform
claude
```

Claude Code 内で以下を試す:

> 「先週の売上を `mart.ec_daily_pnl` から見せて」

→ Claude が `bq query` でクエリ実行 → 7 行のテーブル結果が返れば OK。

> 「SEO 機会金額が大きい KW を Top 10 教えて」

→ `mart.ec_seo_opportunity` を参照したクエリが走る。

---

## Step 7: 監査・コスト確認方法

自分のクエリ履歴と費用は以下で確認可能:

```sql
-- 自分の今日のクエリ一覧
SELECT
  job_id, creation_time, total_bytes_billed,
  total_bytes_billed / POW(1024, 3) AS gb_billed,
  query
FROM `campwill-ec`.`region-asia-northeast1`.INFORMATION_SCHEMA.JOBS_BY_USER
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
ORDER BY creation_time DESC
LIMIT 20;
```

GCP Console 経由: https://console.cloud.google.com/bigquery → 左下「Job history」

---

## やってはいけないこと（再掲）

詳細は [/CLAUDE.md](../CLAUDE.md) を参照。

- ❌ raw の email / phone を Slack や外部に送信（PII）
- ❌ `SELECT *` を partition フィルタなしで叩く（コスト爆発）
- ❌ `~/.bigqueryrc` の `maximum_bytes_billed` を外す
- ❌ `.keys/` を git add（コミット禁止、`.gitignore` 除外済）

---

## 困ったとき

- IAM エラー（`Permission denied`）: 管理者に「`campwill-ec` の `bigquery.dataViewer` on `mart` と `bigquery.jobUser` on project が付いているか」確認依頼
- gcloud auth エラー: `gcloud auth login` を再実行
- bq クエリが「bytes billed limit」で失敗: クエリの partition フィルタを見直す。それでも必要なら CLI で `--maximum_bytes_billed=` を一時的に大きくする

---

## 参考リンク

- [/CLAUDE.md](../CLAUDE.md): プロジェクト全体ガイド
- [docs/spec.md](spec.md): 元仕様書
- [docs/setup-gcp.md](setup-gcp.md): GCP 初期セットアップ（管理者向け）
- BigQuery 公式: https://cloud.google.com/bigquery/docs
