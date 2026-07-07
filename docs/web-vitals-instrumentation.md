# Web Vitals 送信仕込み (Shopify theme → GA4 → BQ)

## 目的

GA4 BQ Export 経由で **LCP / INP / CLS / FCP / TTFB** をページ別に取得し、`mart.ec_page_ux_health` に Web Vitals 列を追加する。

## 仕組み

1. Shopify theme `theme.liquid` に [web-vitals](https://github.com/GoogleChrome/web-vitals) ライブラリを読み込み
2. 各 metric (LCP/INP/CLS/FCP/TTFB) が確定したら `gtag('event', 'web_vitals', {...})` で GA4 に送信
3. GA4 BQ Export (24h 後) で `event_name='web_vitals'` として raw に着弾
4. `mart.ec_page_ux_health` を改訂して Web Vitals 列を追加

## 手順

### Step 1: Shopify 管理画面で theme 編集

1. Shopify 管理画面 → **オンラインストア → テーマ → 現在のテーマ → アクションメニュー → コードを編集**
2. 左ペインで `layout/theme.liquid` を開く
3. `</head>` 直前 に以下の `<script>` ブロックを追加 (下記コピペ)

### Step 2: 貼り付ける snippet

```html
<!-- Web Vitals → GA4 送信 (campwill-data-platform / mart.ec_page_ux_health 用) -->
<script type="module">
  import {onLCP, onINP, onCLS, onFCP, onTTFB} from 'https://unpkg.com/web-vitals@4?module';

  function sendToGA4(metric) {
    if (typeof gtag !== 'function') return;
    gtag('event', 'web_vitals', {
      metric_name:      metric.name,                        // LCP / INP / CLS / FCP / TTFB
      metric_value:     Math.round(metric.name === 'CLS' ? metric.value * 1000 : metric.value),
      metric_rating:    metric.rating,                      // good / needs-improvement / poor
      metric_delta:     Math.round(metric.delta),
      metric_id:        metric.id,
      non_interaction:  true
    });
  }

  onLCP(sendToGA4);
  onINP(sendToGA4);
  onCLS(sendToGA4);
  onFCP(sendToGA4);
  onTTFB(sendToGA4);
</script>
```

### Step 3: 保存 & 動作確認

1. `theme.liquid` を **Save**
2. サイトを開いて DevTools → Network → "google-analytics" でフィルタ
3. `event=web_vitals` のリクエストが飛んでいることを確認 (ページロード後数秒で複数件)

### Step 4: GA4 で event 表示確認 (1-2 時間後)

GA4 管理画面 → **Reports → Realtime → Events** で `web_vitals` が表示されているか確認

### Step 5: BQ で raw 着弾確認 (24h 後)

```sh
bq query --use_legacy_sql=false --project_id=campwill-ec \
"SELECT COUNT(*), MIN(event_timestamp), MAX(event_timestamp)
 FROM \`campwill-ec.analytics_255235274.events_*\`
 WHERE _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', CURRENT_DATE('Asia/Tokyo'))
   AND event_name = 'web_vitals'"
```

→ COUNT が増えていればOK

### Step 6: `mart.ec_page_ux_health` を Web Vitals 対応版に改訂

下記の SQL ブロックを `bigquery/campwill-ec/mart/ec_page_ux_health.sql` に追加 / 差し替え (Web Vitals 列追加):

```sql
-- per_page_session の CTE 内に追加
web_vitals_per_page AS (
  SELECT
    REGEXP_REPLACE(
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location'),
      r'\?.*$', ''
    ) AS page_url,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'metric_name')   AS metric_name,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'metric_value')  AS metric_value,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'metric_rating') AS metric_rating
  FROM `campwill-ec.analytics_255235274.events_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Asia/Tokyo'), INTERVAL 30 DAY))
                          AND FORMAT_DATE('%Y%m%d', CURRENT_DATE('Asia/Tokyo'))
    AND event_name = 'web_vitals'
),
web_vitals_agg AS (
  SELECT
    page_url,
    -- 75th percentile が Web Vitals 公式の評価値
    APPROX_QUANTILES(IF(metric_name = 'LCP',  metric_value, NULL), 100)[OFFSET(75)] AS lcp_p75_ms,
    APPROX_QUANTILES(IF(metric_name = 'INP',  metric_value, NULL), 100)[OFFSET(75)] AS inp_p75_ms,
    APPROX_QUANTILES(IF(metric_name = 'CLS',  metric_value, NULL), 100)[OFFSET(75)] AS cls_p75_x1000,
    APPROX_QUANTILES(IF(metric_name = 'FCP',  metric_value, NULL), 100)[OFFSET(75)] AS fcp_p75_ms,
    APPROX_QUANTILES(IF(metric_name = 'TTFB', metric_value, NULL), 100)[OFFSET(75)] AS ttfb_p75_ms,
    COUNTIF(metric_name = 'LCP' AND metric_rating = 'poor') AS lcp_poor_count,
    COUNTIF(metric_name = 'INP' AND metric_rating = 'poor') AS inp_poor_count,
    COUNTIF(metric_name = 'CLS' AND metric_rating = 'poor') AS cls_poor_count
  FROM web_vitals_per_page
  WHERE page_url IS NOT NULL
  GROUP BY page_url
)

-- 既存の SELECT に LEFT JOIN web_vitals_agg を追加し、列も追加
-- ... lcp_p75_ms, inp_p75_ms, cls_p75_x1000, fcp_p75_ms, ttfb_p75_ms ...
```

最終的に `ec_page_ux_health` の `page_ux_score` 式に Web Vitals を組み込み:
```
page_ux_score = engagement 40% + scroll 30% + (100-bounce) 20% + web_vitals_score 10%
```

## Web Vitals 閾値 (公式)

| metric | Good | Needs Improvement | Poor |
|---|---|---|---|
| **LCP** (Largest Contentful Paint) | ≤ 2.5s | 2.5-4.0s | > 4.0s |
| **INP** (Interaction to Next Paint) | ≤ 200ms | 200-500ms | > 500ms |
| **CLS** (Cumulative Layout Shift) | ≤ 0.1 | 0.1-0.25 | > 0.25 |
| **FCP** (First Contentful Paint) | ≤ 1.8s | 1.8-3.0s | > 3.0s |
| **TTFB** (Time to First Byte) | ≤ 800ms | 800-1800ms | > 1800ms |

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| GA4 Realtime に出ない | `gtag` 未定義 | GA4 タグが先に読み込まれているか確認 (`window.gtag` 存在チェック) |
| BQ に来ない | GA4 BQ Export 設定なし | GA4 管理画面 → 管理 → BigQuery のリンク確認 |
| 一部 metric だけ来る | LCP/CLS は遅延発火 | 数秒待つ。LCP は最初のユーザー操作で確定。CLS はページ遷移時に確定 |
| INP が 0 件 | ユーザー操作なし (ボット等) | 通常運用で問題なし、操作あれば発火する |

## ロードマップ

- **Phase 1** (このドキュメント): Web Vitals 送信開始、データ蓄積
- **Phase 2** (2 週間後): `mart.ec_page_ux_health` に Web Vitals 列追加、page_ux_score を Web Vitals 込みに改訂
- **Phase 3** (1ヶ月後): 役職別ダッシュボード (デベロッパー向け Core Web Vitals 監視 / マーケ向け CV 寄与 UX)
