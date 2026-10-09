"""
mart SQL を BigQuery Scheduled Query として登録/更新する (現状 22 本)。

実行時刻 (UTC):
  - 23:00-23:55 UTC (08:00-08:55 JST): 12 本の主要 mart (Shopify/Klaviyo/SC/広告系)
  - 20:30-20:35 UTC (05:30-05:35 JST): 在庫系 (n8n openlogi-inventory-daily 05:00 JST 後)
  - 21:30 UTC       (06:30 JST):       UX 系 (n8n clarity-metrics-daily 06:00 JST 後)

冪等: 同名 display_name の transferConfig が既に存在すれば PATCH で更新、無ければ POST で新規作成。
"""
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PROJECT = "campwill-ec"
PROJECT_NUMBER = "61470654236"
LOCATION = "asia-northeast1"
SERVICE_ACCOUNT = "n8n-pipeline@campwill-ec.iam.gserviceaccount.com"
GCLOUD = r"C:\Users\user\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
ROOT = Path(__file__).resolve().parent.parent
MART = ROOT / "bigquery" / "campwill-ec" / "mart"

SCHEDULES = [
    ("mart-ec_daily_pnl",              "ec_daily_pnl.sql",              "every day 23:00"),
    ("mart-ec_channel_roi",            "ec_channel_roi.sql",            "every day 23:05"),
    ("mart-ec_klaviyo_conversion",     "ec_klaviyo_conversion.sql",     "every day 23:10"),
    ("mart-ec_weekly_summary",         "ec_weekly_summary.sql",         "every day 23:15"),
    ("mart-ec_customer_profile",       "ec_customer_profile.sql",       "every day 23:20"),
    ("mart-ec_cohort_ltv",             "ec_cohort_ltv.sql",             "every day 23:25"),
    ("mart-ec_repeat_pattern",         "ec_repeat_pattern.sql",         "every day 23:30"),
    ("mart-ec_sku_trend",              "ec_sku_trend.sql",              "every day 23:35"),
    ("mart-ec_search_to_purchase",     "ec_search_to_purchase.sql",     "every day 23:40"),
    ("mart-ec_attribution_first_last", "ec_attribution_first_last.sql", "every day 23:45"),
    ("mart-ec_seo_opportunity",        "ec_seo_opportunity.sql",        "every day 23:50"),
    ("mart-ec_competitor_gap",         "ec_competitor_gap.sql",         "every day 23:55"),
    # 在庫系 (n8n openlogi-inventory-daily が 05:00 JST = 20:00 UTC に raw 投入後)
    # 倉庫移管 (OPENLOGI → はぴロジ) で停止中。ここに残すと同期時に disabled=False で再開されてしまう
    # ("mart-ec_inventory_health",          "ec_inventory_health.sql",          "every day 20:30"),
    # ("mart-ec_storage_cost_estimated",    "ec_storage_cost_estimated.sql",    "every day 20:35"),
    # ページ別 UX 健康度 (GA4 経由)。GA4 BQ Export が UTC 12-24h 遅延のため 23:00 UTC 以降
    # (旧 ec_ux_health は Clarity API 仕様変更で 5/25 以降 0 rows のまま稼働、KUBELL-XXX で廃止)
    ("mart-ec_page_ux_health",            "ec_page_ux_health.sql",            "every day 23:30"),
    # Judge.me レビュー wide fact (PII ゼロ、全社員アクセス可)
    ("mart-ec_review_enriched",           "ec_review_enriched.sql",           "every day 20:00"),
    # 施策自動記録 (Claude API 出力直後 = 03:25 JST、効果検証は 07:50 JST)
    ("mart-ec_initiatives",               "ec_initiatives.sql",               "every day 18:25"),
    ("mart-ec_initiative_results",        "ec_initiative_results.sql",        "every day 22:50"),
    # 横断分析 wide fact (Shopify n8n 04:30 JST + GA4 export 12-24h 後)
    # ※ ec_order_enriched が ec_customer_user_crosswalk を参照するので順序固定: crosswalk 先
    ("mart-ec_customer_user_crosswalk",   "ec_customer_user_crosswalk.sql",   "every day 22:25"),
    ("mart-ec_order_enriched",            "ec_order_enriched.sql",            "every day 22:30"),
    ("mart-ec_order_line_enriched",       "ec_order_line_enriched.sql",       "every day 22:35"),
    # 組織標準 attribution マート (詳細仕様: docs/attribution-model.md)
    ("mart-ec_channel_attribution_weekly","ec_channel_attribution_weekly.sql","every day 22:40"),
]

PARENT = f"projects/{PROJECT_NUMBER}/locations/{LOCATION}"
BASE_URL = "https://bigquerydatatransfer.googleapis.com/v1"


def get_token() -> str:
    # gcloud CLI のユーザートークンは定期的に再ログインを要求するため、ADC を優先する
    try:
        import google.auth
        import google.auth.transport.requests
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token
    except Exception:
        return subprocess.run([GCLOUD, "auth", "print-access-token"], capture_output=True, text=True).stdout.strip()


def api(method: str, path: str, token: str, body: dict | None = None):
    url = f"{BASE_URL}/{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}


def find_existing(token: str, display_name: str):
    code, data = api("GET", f"{PARENT}/transferConfigs?dataSourceIds=scheduled_query&pageSize=200", token)
    if code != 200:
        return None
    for tc in data.get("transferConfigs", []):
        if tc.get("displayName") == display_name:
            return tc
    return None


def read_sql(filename: str) -> str:
    path = MART / filename
    raw = path.read_bytes()
    if raw[:3] == b"\xef\xbb\xbf":
        raw = raw[3:]
    return raw.decode("utf-8")


def main():
    token = get_token()

    for display_name, filename, schedule in SCHEDULES:
        sql = read_sql(filename)
        body = {
            "displayName": display_name,
            "dataSourceId": "scheduled_query",
            "schedule": schedule,
            "params": {"query": sql},
            "disabled": False,
        }

        sa_param = f"serviceAccountName={urllib.parse.quote(SERVICE_ACCOUNT)}"

        existing = find_existing(token, display_name)
        if existing:
            # PATCH update — must specify updateMask
            name = existing["name"]
            mask = "displayName,schedule,params"
            url = f"{name}?updateMask={urllib.parse.quote(mask)}&{sa_param}"
            code, data = api("PATCH", url, token, body)
            if code == 200:
                print(f"  [updated] {display_name}: {data.get('name')}")
            else:
                print(f"  [ERROR-update] {display_name}: {code} {data}")
        else:
            # POST create with service account impersonation
            url = f"{PARENT}/transferConfigs?{sa_param}"
            code, data = api("POST", url, token, body)
            if code == 200:
                print(f"  [created] {display_name}: {data.get('name')}")
            else:
                print(f"  [ERROR-create] {display_name}: {code} {data}")


if __name__ == "__main__":
    main()
