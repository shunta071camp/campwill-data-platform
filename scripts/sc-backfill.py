"""
Search Console Search Analytics API で過去 16 ヶ月分の日次データを backfill。

出力テーブル: campwill-ec.searchconsole.sc_history
スキーマ: data_date, site_url, url, query, clicks, impressions, ctr, position

Usage:
    python sc-backfill.py [--start 2024-01-01] [--end 2026-05-07] [--site https://ku-bell.com/]
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PROJECT = "campwill-ec"
DEFAULT_SITE = "https://ku-bell.com/"
DEFAULT_DATASET = "searchconsole"
DEFAULT_TABLE = "sc_history"
GCLOUD_DIR = r"C:\Users\user\AppData\Roaming\gcloud"
ROW_LIMIT = 25000


def get_token() -> str:
    adc = json.loads(Path(GCLOUD_DIR, "application_default_credentials.json").read_text())
    body = {
        "client_id": adc["client_id"],
        "client_secret": adc["client_secret"],
        "refresh_token": adc["refresh_token"],
        "grant_type": "refresh_token",
    }
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(body).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return json.loads(urllib.request.urlopen(req).read())["access_token"]


def http_post_with_retry(url: str, body: dict, headers: dict, max_retries: int = 5):
    """POST with exponential backoff for transient network/5xx errors."""
    for attempt in range(max_retries):
        try:
            req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, json.loads(resp.read()), None
        except urllib.error.HTTPError as e:
            err = e.read().decode()[:300]
            if e.code in (429, 500, 502, 503, 504) and attempt < max_retries - 1:
                wait = 2 ** attempt
                print(f"    retry {attempt+1}/{max_retries} after {wait}s ({e.code})")
                time.sleep(wait)
                continue
            return e.code, None, err
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            if attempt < max_retries - 1:
                wait = 2 ** attempt
                print(f"    retry {attempt+1}/{max_retries} after {wait}s ({type(e).__name__}: {e})")
                time.sleep(wait)
                continue
            return None, None, str(e)
    return None, None, "max retries exceeded"


def query_sc(token: str, site: str, day: datetime.date) -> list[dict]:
    """Fetch one day of data with pagination."""
    url = f"https://searchconsole.googleapis.com/webmasters/v3/sites/{urllib.parse.quote(site, safe='')}/searchAnalytics/query"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "x-goog-user-project": PROJECT,
    }

    all_rows = []
    start_row = 0
    while True:
        body = {
            "startDate": day.isoformat(),
            "endDate": day.isoformat(),
            "dimensions": ["date", "page", "query"],
            "rowLimit": ROW_LIMIT,
            "startRow": start_row,
        }
        code, data, err = http_post_with_retry(url, body, headers)
        if data is None:
            print(f"  ERR {day} startRow={start_row}: {code} {err}")
            return []

        rows = data.get("rows", [])
        if not rows:
            break
        all_rows.extend(rows)
        if len(rows) < ROW_LIMIT:
            break
        start_row += ROW_LIMIT

    return all_rows


def write_bq(token: str, site: str, day: datetime.date, rows: list[dict], table_fqn: str) -> int:
    """Stream insert to BQ. Returns inserted count."""
    if not rows:
        return 0
    bq_url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT}/datasets/{DEFAULT_DATASET}/tables/{DEFAULT_TABLE}/insertAll"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "x-goog-user-project": PROJECT,
    }

    bq_rows = []
    for r in rows:
        keys = r.get("keys") or []
        if len(keys) < 3:
            continue
        bq_rows.append({"json": {
            "data_date": keys[0],
            "site_url": site,
            "url": keys[1],
            "query": keys[2],
            "clicks": int(r.get("clicks") or 0),
            "impressions": int(r.get("impressions") or 0),
            "ctr": float(r.get("ctr") or 0.0),
            "position": float(r.get("position") or 0.0),
        }})

    # Stream insert in chunks of 5000
    inserted = 0
    for i in range(0, len(bq_rows), 5000):
        chunk = bq_rows[i:i+5000]
        body_dict = {"rows": chunk, "skipInvalidRows": False, "ignoreUnknownValues": False}
        code, result, err = http_post_with_retry(bq_url, body_dict, headers)
        if result is None:
            print(f"    BQ ERR after retries: {code} {err}")
        elif result.get("insertErrors"):
            print(f"    BQ insertErrors: {json.dumps(result['insertErrors'][:2], default=str)[:300]}")
        else:
            inserted += len(chunk)
    return inserted


def ensure_table(token: str):
    """Create destination table if missing (via bq CLI fallback to REST)."""
    schema = [
        {"name": "data_date",   "type": "DATE",      "mode": "REQUIRED"},
        {"name": "site_url",    "type": "STRING",    "mode": "REQUIRED"},
        {"name": "url",         "type": "STRING",    "mode": "NULLABLE"},
        {"name": "query",       "type": "STRING",    "mode": "NULLABLE"},
        {"name": "clicks",      "type": "INTEGER",   "mode": "REQUIRED"},
        {"name": "impressions", "type": "INTEGER",   "mode": "REQUIRED"},
        {"name": "ctr",         "type": "FLOAT",     "mode": "NULLABLE"},
        {"name": "position",    "type": "FLOAT",     "mode": "NULLABLE"},
    ]
    url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT}/datasets/{DEFAULT_DATASET}/tables"
    body = {
        "tableReference": {"projectId": PROJECT, "datasetId": DEFAULT_DATASET, "tableId": DEFAULT_TABLE},
        "schema": {"fields": schema},
        "timePartitioning": {"type": "DAY", "field": "data_date"},
        "clustering": {"fields": ["query"]},
    }
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "x-goog-user-project": PROJECT}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        urllib.request.urlopen(req)
        print(f"  Created table {DEFAULT_DATASET}.{DEFAULT_TABLE}")
    except urllib.error.HTTPError as e:
        if e.code == 409:
            print(f"  Table {DEFAULT_DATASET}.{DEFAULT_TABLE} exists, reusing")
        else:
            print(f"  ensure_table ERR: {e.code} {e.read().decode()[:200]}")


def main():
    p = argparse.ArgumentParser()
    today = datetime.date.today()
    p.add_argument("--start", default=(today - datetime.timedelta(days=480)).isoformat())
    p.add_argument("--end",   default=(today - datetime.timedelta(days=3)).isoformat())  # SC has 2-3 day delay
    p.add_argument("--site",  default=DEFAULT_SITE)
    args = p.parse_args()

    start = datetime.datetime.strptime(args.start, "%Y-%m-%d").date()
    end = datetime.datetime.strptime(args.end, "%Y-%m-%d").date()
    site = args.site

    token = get_token()
    refresh_at = time.time() + 1800

    ensure_table(token)

    day = start
    total_rows = 0
    total_days = (end - start).days + 1
    print(f"Backfill {site} from {start} to {end} ({total_days} days)")

    while day <= end:
        if time.time() > refresh_at:
            token = get_token()
            refresh_at = time.time() + 1800

        rows = query_sc(token, site, day)
        inserted = write_bq(token, site, day, rows, f"{PROJECT}.{DEFAULT_DATASET}.{DEFAULT_TABLE}")
        total_rows += inserted
        pct = ((day - start).days + 1) * 100 // total_days
        print(f"  [{day}] {len(rows)} rows fetched, {inserted} inserted to BQ ({pct}%)")

        day += datetime.timedelta(days=1)
        time.sleep(0.5)  # avoid rate limit

    print(f"\nDone. Total rows inserted: {total_rows}")


if __name__ == "__main__":
    main()
