"""
campwill-realestate mart 5 SQL を BigQuery Scheduled Query として登録/更新する。

実行時刻 (JST 05:00 - 05:20 = UTC 20:00 - 20:20):
  re_lead_funnel              05:00 JST = 20:00 UTC
  re_case_pipeline            05:05 JST = 20:05 UTC
  re_seo_inquiry_attribution  05:10 JST = 20:10 UTC
  re_property_performance     05:15 JST = 20:15 UTC
  re_weekly_summary           05:20 JST = 20:20 UTC

  → realestate-sync.py を 04:30 JST に走らせる前提

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

PROJECT = "campwill-realestate"
PROJECT_NUMBER_ENV = "REALESTATE_PROJECT_NUMBER"  # 取得方法: gcloud projects describe campwill-realestate --format='value(projectNumber)'
LOCATION = "asia-northeast1"
SERVICE_ACCOUNT = "n8n-pipeline@campwill-realestate.iam.gserviceaccount.com"
GCLOUD = r"C:\Users\user\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
ROOT = Path(__file__).resolve().parent.parent
MART = ROOT / "bigquery" / "campwill-realestate" / "mart"

SCHEDULES = [
    ("re-lead_funnel",              "re_lead_funnel.sql",              "every day 20:00"),
    ("re-case_pipeline",            "re_case_pipeline.sql",            "every day 20:05"),
    ("re-seo_inquiry_attribution",  "re_seo_inquiry_attribution.sql",  "every day 20:10"),
    ("re-property_performance",     "re_property_performance.sql",     "every day 20:15"),
    ("re-weekly_summary",           "re_weekly_summary.sql",           "every day 20:20"),
]

BASE_URL = "https://bigquerydatatransfer.googleapis.com/v1"


def get_project_number() -> str:
    """campwill-realestate のプロジェクト番号を gcloud で取得 (env でも上書き可)。"""
    import os
    if os.environ.get(PROJECT_NUMBER_ENV):
        return os.environ[PROJECT_NUMBER_ENV]
    res = subprocess.run(
        [GCLOUD, "projects", "describe", PROJECT, "--format=value(projectNumber)"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"gcloud projects describe failed: {res.stderr}")
    return res.stdout.strip()


def get_token() -> str:
    return subprocess.run(
        [GCLOUD, "auth", "print-access-token"],
        capture_output=True, text=True,
    ).stdout.strip()


def api(method: str, path: str, token: str, body: dict | None = None):
    url = f"{BASE_URL}/{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data,
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


def find_existing(parent: str, token: str, display_name: str):
    code, data = api("GET", f"{parent}/transferConfigs?dataSourceIds=scheduled_query&pageSize=200", token)
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
    project_number = get_project_number()
    parent = f"projects/{project_number}/locations/{LOCATION}"
    token = get_token()

    print(f"==> Project: {PROJECT} (number: {project_number})")
    print(f"==> Service account: {SERVICE_ACCOUNT}")
    print()

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
        existing = find_existing(parent, token, display_name)
        if existing:
            name = existing["name"]
            mask = "displayName,schedule,params"
            url = f"{name}?updateMask={urllib.parse.quote(mask)}&{sa_param}"
            code, data = api("PATCH", url, token, body)
            if code == 200:
                print(f"  [updated] {display_name}: {data.get('name')}")
            else:
                print(f"  [ERROR-update] {display_name}: {code} {data}")
        else:
            url = f"{parent}/transferConfigs?{sa_param}"
            code, data = api("POST", url, token, body)
            if code == 200:
                print(f"  [created] {display_name}: {data.get('name')}")
            else:
                print(f"  [ERROR-create] {display_name}: {code} {data}")


if __name__ == "__main__":
    main()
