"""
mart 4 SQL を BigQuery Scheduled Query として登録/更新する。

実行時刻 (JST 08:00 - 08:15 = UTC 23:00 - 23:15):
  ec_daily_pnl          08:00 JST = 23:00 UTC
  ec_channel_roi        08:05 JST = 23:05 UTC
  ec_klaviyo_conversion 08:10 JST = 23:10 UTC
  ec_weekly_summary     08:15 JST = 23:15 UTC

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
]

PARENT = f"projects/{PROJECT_NUMBER}/locations/{LOCATION}"
BASE_URL = "https://bigquerydatatransfer.googleapis.com/v1"


def get_token() -> str:
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
