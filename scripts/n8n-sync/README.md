# n8n cloud 同期スクリプト

ローカル `n8n/workflows/*.json` を master として n8n cloud に push する。
ローカル編集 → `python sync.py push <name>` で本番反映、UI 手動貼り替え不要。

## 事前準備

### 1. API Key 発行

n8n cloud UI で:
1. 右上アイコン → **Settings**
2. 左メニュー **n8n API**
3. **Create an API key**
4. ラベル: `local-sync` / Expires: 任意（推奨 365 日）→ **Create**
5. 表示された API Key を **すぐコピー**（再表示不可）

### 2. `.env` 作成

リポジトリルート `campwill-ai-ready/.env` に以下を作成:

```env
N8N_BASE_URL=https://<your-instance>.app.n8n.cloud
N8N_API_KEY=eyJhbGciOi...
```

> ⚠️ `.env` は `.gitignore` で除外されている（リポジトリにコミット禁止）。

### 3. 初期化

```bash
python scripts/n8n-sync/sync.py init
```

→ 本番の workflow 一覧を取得して `workflow-ids.json` に mapping を自動生成。

「(no match)」と出た workflow は手動で `workflow-ids.json` を編集する必要あり。

## コマンド一覧

```bash
# 一覧表示（本番 workflow と active 状態）
python scripts/n8n-sync/sync.py list

# 1 件 push（active 自動維持）
python scripts/n8n-sync/sync.py push klaviyo-profiles

# 全件 push
python scripts/n8n-sync/sync.py push --all

# active 自動維持を OFF（デバッグ時）
python scripts/n8n-sync/sync.py push klaviyo-profiles --no-keep-active

# 本番 → ローカル（復旧用）
python scripts/n8n-sync/sync.py pull klaviyo-profiles

# 差分確認（push 前のドライラン）
python scripts/n8n-sync/sync.py diff klaviyo-profiles

# Activate / Deactivate
python scripts/n8n-sync/sync.py activate klaviyo-profiles
python scripts/n8n-sync/sync.py deactivate klaviyo-profiles
```

## ファイル構成

```
scripts/n8n-sync/
├── README.md            # このファイル
├── sync.py              # メインスクリプト
├── workflow-ids.json    # ローカルファイル名 ↔ n8n workflow ID の mapping (init で自動生成)
└── .env.example         # 設定例
```

## トラブルシューティング

### `request/body must NOT have additional properties`
PUT 時に read-only field が含まれている。`READONLY_FIELDS` セットに追加して再実行。

### `Unauthorized`
- `.env` の `N8N_API_KEY` が間違っている、または期限切れ
- n8n cloud で再発行 → `.env` 更新

### `Not Found` (workflow ID)
- mapping が古い → `python sync.py init` で再生成
- または対象 workflow が n8n cloud から削除された

### push 後 active が外れる
- 通常は `--keep-active` (default) で自動再 activate される
- 失敗した場合は `python sync.py activate <name>` で手動 activate

## 注意事項

- **credential ID は手動管理**: ローカル JSON 内の credential 参照は本番側の ID をそのまま使用。credential 自体の同期は対象外（漏洩リスク回避）
- **schedule node の time zone**: `settings.timezone` が空だと UTC で実行される。各 workflow JSON で明示
- **workflow ID は環境固有**: 別の n8n インスタンス（dev / prod 分離など）に push する場合は別 mapping を用意
