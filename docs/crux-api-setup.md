# CrUX History API セットアップ

## 概要

ku-bell.com の **URL 別 Core Web Vitals (LCP / INP / CLS / FCP / TTFB)** を Google CrUX History API から daily 取得し、`raw.ec_crux_history_daily` に蓄積、`mart.ec_page_ux_health` に列追加する。

データ:
- 28日 rolling、daily 更新
- form_factor 集約 (PHONE/DESKTOP/TABLET 合算)
- p75 (75 percentile) + histogram density (good/needs-improvement/poor)

サイト改修不要 (Chrome 実ユーザーデータを Google が集計したもの)。

---

## 必要なユーザー作業 (5 分)

### Step 1: GCP Console で CrUX API 有効化 + API key 作成

1. **CrUX API を有効化**: [https://console.cloud.google.com/apis/library/chromeuxreport.googleapis.com?project=campwill-ec](https://console.cloud.google.com/apis/library/chromeuxreport.googleapis.com?project=campwill-ec) → 「有効にする」

2. **API key 作成**: [https://console.cloud.google.com/apis/credentials?project=campwill-ec](https://console.cloud.google.com/apis/credentials?project=campwill-ec)
   - 上部 → **+ 認証情報を作成 → API キー**
   - キー名: `CrUX API n8n` 等
   - 「キーを制限」をクリック →
     - **API の制限**: Chrome UX Report API のみ選択
     - **アプリケーションの制限**: なし (n8n cloud からなので IP 制限不可)
   - 保存
   - 表示された **キー文字列 (`AIzaSy...`)** をコピー (これが API key)

### Step 2: n8n cloud で credential 作成

1. https://campwill.app.n8n.cloud/projects/xSwFSDmagTleuj5x/credentials/new
2. **Type: Query Auth** を選択
3. 入力:
   - **Credential Name**: `CrUX API Key`
   - **Name**: `key`
   - **Value**: コピーした API key
4. 保存
5. URL バーから credential ID をコピー (`https://campwill.app.n8n.cloud/...credentials/XXXXXX` の `XXXXXX`)

### Step 3: 私に credential ID を渡す

> 「credential ID = `XXXXXXXXXX`」とチャットで返信。
> n8n workflow JSON の `REPLACE_WITH_CREDENTIAL_ID` を置換 → push → 動作確認。

---

## quota / コスト

- **CrUX API quota**: 25,000 リクエスト/日 (project あたり)
- 本 workflow: 50 URL × 1 form_factor = 50 req/day → quota の 0.2% 使用
- 完全無料

---

## 仕組み

```
[n8n Schedule 05:00 JST daily]
  ↓
BigQuery: 上位 50 URL を mart.ec_page_ux_health から取得
  ↓
HTTP: 各 URL について POST /v1/records:queryHistoryRecord
  ↓
Transform: timeseries (28日 × URL) を行展開
  ↓
BigQuery: insert raw.ec_crux_history_daily
  ↓
(翌朝の mart.ec_page_ux_health 再生成時)
LEFT JOIN raw.ec_crux_history_latest → CrUX 列追加 + page_ux_score を Web Vitals 込みに進化
```

## raw 列構成

`raw.ec_crux_history_daily`:
- snapshot_date, url, form_factor, collection_period_start/end
- lcp_p75_ms, lcp_good/ni/poor_density (0-1)
- inp_p75_ms, inp_good/ni/poor_density
- cls_p75, cls_good/ni/poor_density
- fcp_p75_ms, ttfb_p75_ms
- raw_payload (JSON 文字列、デバッグ用)
- inserted_at

dedup view: `raw.ec_crux_history_latest` (URL × period_end の最新 snapshot)

## mart.ec_page_ux_health の page_ux_score 改訂 (v2)

旧 v1: `engagement 40% + scroll 30% + (100-bounce) 30%`

新 v2 (CrUX 有り): `engagement 30% + scroll 20% + (100-bounce) 20% + web_vitals 30%`
  - web_vitals = (lcp_good_pct + inp_good_pct + cls_good_pct) / 3

CrUX データ無い URL (低トラフィック) は v1 式を維持 (`has_crux = FALSE` 列で識別可能)。

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `403 PERMISSION_DENIED` | API key 無効 / CrUX API 未有効化 | Step 1 を再確認 |
| `404 NOT_FOUND` レスポンス | 該当 URL に CrUX 十分なデータなし (typical 100+ users/28d) | 想定内、skip。Transform で error チェック済 |
| `429 Quota exceeded` | 25k/day 超過 (現状 50 req/day なので余裕) | URL 数調整 |
| BQ に行が入らない | Transform JS の bin index 仮定が CrUX 仕様変更で崩れた | raw_payload 列を直接 SQL で parse して確認 |
