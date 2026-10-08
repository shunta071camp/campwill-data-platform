"""
CAMPWILL BQ Analyst Proxy
- POST /query : SQL を受け取り SELECT-only + mart-only ガード → BigQuery 実行 → JSON 返却
- POST /chat  : messages を Anthropic Claude に中継 → SQL 生成 / 示唆生成
- GET  /health: ヘルスチェック

認証: X-API-Key ヘッダを SHARED_SECRET と照合 (/health は除く)
"""
import json
import os
import re
import time
from functools import wraps

import requests
import sqlparse
from flask import Flask, jsonify, request
from flask_cors import CORS
from google.cloud import bigquery

app = Flask(__name__)
CORS(app)

# ===== 設定 =====
BQ_PROJECT       = os.environ.get("BQ_PROJECT", "campwill-ec")
BQ_LOCATION      = os.environ.get("BQ_LOCATION", "asia-northeast1")
MAX_BYTES_BILLED = int(os.environ.get("MAX_BYTES_BILLED", str(5 * 1024 * 1024 * 1024)))  # 5 GiB
ANTHROPIC_KEY    = os.environ.get("ANTHROPIC_API_KEY", "").strip()
ANTHROPIC_MODEL  = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5").strip()
SHARED_SECRET    = os.environ.get("SHARED_SECRET", "").strip()

# 危険キーワード (大文字化済み文字列で部分一致判定)
FORBIDDEN_KEYWORDS = [
    "INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "CREATE",
    "ALTER", "TRUNCATE", "GRANT", "REVOKE", "CALL", "EXPORT",
]

# 許可するテーブル参照のプロジェクト + データセット
# - campwill-ec.mart.* のみ許可 (campwill-realestate は 2026-08-12 廃止)
ALLOWED_TABLE_PATTERN = re.compile(
    r"`?(campwill-ec)\.mart\.[a-zA-Z0-9_]+`?", re.IGNORECASE
)
ALLOWED_PROJECTS = {"campwill-ec"}
# 任意の `project.dataset.table` 参照を検出 (sqlparse 前段で網羅的に拾う)
ANY_TABLE_REF_PATTERN = re.compile(
    r"`?([a-zA-Z][a-zA-Z0-9_-]*)\.([a-zA-Z][a-zA-Z0-9_]*)\.([a-zA-Z][a-zA-Z0-9_]*)`?"
)

# ===== Anthropic 中継時の system プロンプト =====
SYSTEM_PROMPT = """\
あなたは CAMPWILL EC (kubell) のデータアナリスト AI です。
ユーザーの質問に対して BigQuery mart テーブルを参照する SQL を生成し、
実行結果から事業的な示唆を返します。

# 利用可能テーブル (campwill-ec.mart)

## EC 系 (campwill-ec.mart)

| テーブル | 主な列 | 用途 |
|---|---|---|
| ec_weekly_summary | week_start, weekly_revenue, weekly_orders, weekly_customers, avg_order_value, refund_count, refund_rate_pct | 週次 KPI サマリ |
| ec_channel_roi | date, channel, orders, unique_customers, revenue, ad_cost, roas, cpa, refund_rate_pct, ltv | チャネル別日次 ROI |
| ec_channel_attribution_weekly | week_start, channel, orders, revenue, ad_cost, roas | 組織標準 attribution v2.1 (週次) |
| ec_daily_pnl | order_date, order_id, sku, quantity, revenue, cost_price, total_cost, gross_profit, actual_gross_profit, actual_margin_pct, is_refunded | SKU 別粗利 (⚠️ line-grain: 1 order = N rows で `revenue` は order.total_price が複製されている。**日次 / 週次 revenue 集計には ec_weekly_summary / ec_channel_roi を使うこと**。SKU 別必須なら `SUM(quantity*unit_price)` で line-level 計算) |
| ec_klaviyo_conversion | campaign_id, campaign_name, sent_at, recipients, open_rate, click_rate, klaviyo_revenue, shopify_orders, shopify_revenue, purchase_rate_pct | Klaviyo メール CV (v2: last-click 5d attribution。Clicked Email event × campaign_id マッチ、5 日以内 order を last-click campaign に帰属。Klaviyo 公式報告値と近似) |
| ec_customer_profile | customer_email_hash, first_order_date, last_order_date, order_count, total_revenue, ltv_tier | 顧客プロファイル (PII ハッシュ済) |
| ec_order_enriched | order_id, order_date, channel_classified, utm_source, utm_campaign, landing_site, total_price | 注文 wide fact (attribution 適用済) |
| ec_initiatives | initiative_id, start_date, category, title, target_metric, confidence, needs_review, source_url | 施策マスタ (Slack/Backlog 自動抽出) |
| ec_initiative_results | initiative_id, target_metric, baseline_value, observed_value, change_pct, effect, overlap_warning | 施策効果検証 |
| ec_review_enriched | review_id, sku, rating, body, customer_email_hash, is_first_purchase | Judge.me レビュー (PII ハッシュ済) |
| ec_order_line_enriched | order_id, order_date, sku, quantity, unit_price, line_revenue_yen, channel_classified, is_refunded, total_price | SKU 視点 wide fact (⚠️ line-grain: 売上集計は `line_revenue_yen` を使う。`total_price` は order-level 複製で naive SUM すると line 数分 x1.5 過大。order-level 合計が要る場合は ec_order_enriched を使う) |
| ec_sku_trend | year_month, sku, sku_title, units_sold, revenue, mom_growth_pct, yoy_growth_pct, trend_class (rising/declining/stable) | SKU 別月次トレンド + rising/declining 分類 |
| ec_cohort_ltv | cohort_month, months_since_first, cohort_size, active_customers, retention_pct, month_revenue, cumulative_revenue, cumulative_ltv | コホート月 × 経過月の累計 LTV / リテンション |
| ec_repeat_pattern | order_index (1-10), days_since_previous, order_count, avg_revenue | リピート回数別の間隔 / 客単価 |
| ec_search_to_purchase | year_month, sc_query, sc_path, sc_clicks, sc_impressions, sc_avg_position, matched_orders, matched_revenue, conversion_rate_pct, revenue_per_click | SC 検索 → 購入導線 (月次) |
| ec_seo_opportunity | keyword, opportunity_type, sc_recent_position, sc_avg_impressions, estimated_monthly_loss_yen | SEO 機会 (推定損失額つき) |
| ec_competitor_gap | keyword, competitor_count, competitors, cpc, search_volume, estimated_monthly_opportunity_yen | 競合のみ獲得 KW (自社未獲得) |
| ec_attribution_first_last | customer_email_hash, first_channel, last_channel, order_count, total_revenue | ファースト/ラストアトリビューション |
| ec_page_ux_health | page_url, page_type, sessions_30d, engagement_rate, scroll_90_rate, bounce_rate, cv_rate, lcp_p75_ms, inp_p75_ms, cls_p75, ux_score | Page 別 UX 健康度スコア + Web Vitals |
| ec_inventory_health | sku, sku_title, status (stockout/at_risk/healthy/overstock), current_stock, weekly_sales_avg, days_of_stock | 在庫ステータス分類 |
| ec_storage_cost_estimated | sku, snapshot_date, size_category, estimated_daily_cost, estimated_monthly_cost | OPENLOGI 推定保管費用 |

# チャネル値 (channel / channel_classified / first_channel / last_channel 共通, attribution v2.1)

| 区分 | 値 |
|---|---|
| 有料広告 (ad_cost あり) | google_paid, meta_paid, yahoo_paid, microsoft_paid, tiktok_paid |
| 無料ショッピング (Merchant Center 無料リスティング) | google_shopping_free, microsoft_shopping_free |
| 自然検索 | seo_google, seo_yahoo, seo_bing, seo_other |
| SNS・その他 | instagram_organic, social_youtube, line, ai_referral, referral |
| メール | email_klaviyo |
| 不明 | direct, unknown, other |

- 「オーガニック」と聞かれたら seo_* + google_shopping_free + microsoft_shopping_free + instagram_organic + social_youtube + line + ai_referral + referral + email_klaviyo を含める。google_shopping_free は売上の約 1 割を占める主要チャネル
- 「広告」は *_paid のみ。google_paid にはショッピング/P-MAX 広告も含まれる

# 厳守ルール

1. **mart のみ参照** (`campwill-ec.mart.<table>` 形式)。raw / 他プロジェクトは禁止
2. SELECT 文のみ。DDL/DML は不可
3. クエリは日付フィルタを必ず入れる (`WHERE order_date >= DATE_SUB(CURRENT_DATE("Asia/Tokyo"), INTERVAL N DAY)` 形式推奨)
4. LIMIT 付与推奨 (LIMIT を省略しても自動で 1000 が付くが、明示が望ましい)
5. SQL は ```sql ... ``` のコードブロックで 1 つだけ返す
6. 説明文は SQL ブロックの前後に短く
7. 不動産 (クラスラ) 関連の質問には答えられない。`campwill-realestate` は 2026-08-12 に廃止済のため、データが存在しない旨を伝える

# 出力形式

ユーザーの最初の質問への返答 (SQL 生成フェーズ):
- 1-2 行で「何を出すか」を説明
- ```sql のブロックで SQL を返す

実行結果を受け取った後の返答 (示唆フェーズ):
- 結果から読み取れる事業示唆を箇条書きで 3-5 個
- 数値を引用 (例: 「ROAS 12.3 で google_paid が最良」)
- 必要なら次に試すべき分析を 1-2 個提案
"""


# ===== 認証ミドルウェア =====
def require_api_key(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if request.method == "OPTIONS":
            return ("", 204)
        key = request.headers.get("X-API-Key", "")
        if not SHARED_SECRET or key != SHARED_SECRET:
            return jsonify({"error": "unauthorized", "code": "auth"}), 401
        return fn(*args, **kwargs)
    return wrapped


# ===== SQL ガード =====
def strip_comments(sql: str) -> str:
    """-- と /* */ コメントを除去 (バイパス防止)"""
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return sql


def normalize_sql(sql: str) -> str:
    s = strip_comments(sql)
    s = s.strip().rstrip(";").strip()
    return s


def is_select_only(sql: str) -> bool:
    """SELECT または WITH ... SELECT で始まることを判定"""
    parsed = sqlparse.parse(sql)
    if not parsed:
        return False
    stmt = parsed[0]
    # 全ステートメントが 1 つだけであること (複数文混在を防止)
    if len(parsed) > 1:
        return False
    first_token = next((t for t in stmt.tokens if not t.is_whitespace), None)
    if first_token is None:
        return False
    upper = first_token.value.upper()
    return upper in ("SELECT", "WITH")


def has_forbidden_keyword(sql: str) -> str | None:
    upper = sql.upper()
    # 単語境界で判定 (例: "updated_at" を UPDATE と誤判定しないよう \b で囲む)
    for kw in FORBIDDEN_KEYWORDS:
        if re.search(rf"\b{kw}\b", upper):
            return kw
    return None


def check_table_refs(sql: str) -> str | None:
    """全ての `project.dataset.table` 参照が campwill-ec.mart.* であることを確認。
    違反があれば違反テーブル名を文字列で返す。OK なら None。"""
    matches = ANY_TABLE_REF_PATTERN.findall(sql)
    for project, dataset, table in matches:
        ref = f"{project}.{dataset}.{table}"
        if not (project in ALLOWED_PROJECTS and dataset == "mart"):
            return ref
    return None


def ensure_limit(sql: str) -> str:
    """末尾に LIMIT が無ければ 1000 を付与"""
    # 簡易判定: 最後の有意トークンが LIMIT N
    if re.search(r"\bLIMIT\s+\d+\s*$", sql, flags=re.IGNORECASE):
        return sql
    return sql.rstrip() + "\nLIMIT 1000"


def guard_sql(raw_sql: str) -> tuple[str | None, dict]:
    """SQL ガードを順に適用。OK なら (normalized_sql, {}) を、NG なら (None, error) を返す"""
    if not raw_sql or not raw_sql.strip():
        return None, {"error": "sql is empty", "code": "empty"}

    sql = normalize_sql(raw_sql)

    bad = has_forbidden_keyword(sql)
    if bad:
        return None, {"error": f"forbidden keyword: {bad}", "code": "forbidden-keyword"}

    if not is_select_only(sql):
        return None, {"error": "only SELECT / WITH statements are allowed", "code": "select-only"}

    bad_ref = check_table_refs(sql)
    if bad_ref:
        return None, {"error": f"only campwill-ec.mart.* is allowed (got: {bad_ref})", "code": "mart-only"}

    sql = ensure_limit(sql)
    return sql, {}


# ===== BQ クライアント (lazy 初期化) =====
_bq_client = None


def get_bq_client() -> bigquery.Client:
    global _bq_client
    if _bq_client is None:
        _bq_client = bigquery.Client(project=BQ_PROJECT, location=BQ_LOCATION)
    return _bq_client


def serialize_row(row) -> dict:
    """BQ Row を JSON-safe dict に変換"""
    result = {}
    for key, value in row.items():
        if value is None:
            result[key] = None
        elif isinstance(value, (str, int, float, bool)):
            result[key] = value
        elif hasattr(value, "isoformat"):
            result[key] = value.isoformat()
        else:
            result[key] = str(value)
    return result


# ===== Endpoints =====
@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "project": BQ_PROJECT,
        "location": BQ_LOCATION,
        "model": ANTHROPIC_MODEL,
        "anthropic_configured": bool(ANTHROPIC_KEY),
        "auth_configured": bool(SHARED_SECRET),
    })


@app.route("/query", methods=["POST", "OPTIONS"])
@require_api_key
def run_query():
    body = request.get_json(silent=True) or {}
    raw_sql = body.get("sql", "")

    safe_sql, err = guard_sql(raw_sql)
    if err:
        return jsonify(err), 400

    try:
        client = get_bq_client()
        job_config = bigquery.QueryJobConfig(
            maximum_bytes_billed=MAX_BYTES_BILLED,
            use_query_cache=True,
        )
        start = time.time()
        rows = list(client.query(safe_sql, job_config=job_config).result())
        elapsed_ms = int((time.time() - start) * 1000)
        data = [serialize_row(r) for r in rows]
        return jsonify({
            "rows": data,
            "count": len(data),
            "elapsed_ms": elapsed_ms,
            "sql_executed": safe_sql,
        })
    except Exception as e:
        msg = str(e)
        return jsonify({"error": msg, "code": "bq-error"}), 500


@app.route("/chat", methods=["POST", "OPTIONS"])
@require_api_key
def chat():
    if not ANTHROPIC_KEY:
        return jsonify({"error": "anthropic key not configured", "code": "no-anthropic"}), 503

    body = request.get_json(silent=True) or {}
    messages = body.get("messages") or []
    max_tokens = int(body.get("max_tokens", 4096))
    temperature = float(body.get("temperature", 0.2))

    if not isinstance(messages, list) or not messages:
        return jsonify({"error": "messages required", "code": "bad-request"}), 400

    # role 正規化 + content 文字列化
    norm = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role", "user")
        if role not in ("user", "assistant"):
            role = "user"
        content = m.get("content", "")
        if isinstance(content, list):
            content = "".join(str(c) for c in content)
        norm.append({"role": role, "content": str(content)[:50000]})

    payload = {
        "model": ANTHROPIC_MODEL,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "system": SYSTEM_PROMPT,
        "messages": norm,
    }

    try:
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            data=json.dumps(payload),
            timeout=120,
        )
        if resp.status_code >= 400:
            return jsonify({"error": resp.text[:1000], "code": "anthropic-error"}), 502
        rj = resp.json()
        text = ""
        for blk in rj.get("content", []):
            if blk.get("type") == "text":
                text += blk.get("text", "")
        usage = rj.get("usage", {})
        return jsonify({
            "text": text,
            "model": rj.get("model", ANTHROPIC_MODEL),
            "usage": usage,
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e), "code": "anthropic-network"}), 502


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
