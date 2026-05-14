"""
Meta Ads DTS backfill loop (1 day at a time, with polling).

DTS が PENDING/RUNNING 中は新しい manual run を作れないので、
- 各日: 現在の active run が無いことを確認 → startManualRuns → 完了まで polling
- ~80 days x ~3 min = 3-5 hours

Usage:
    python dts-meta-backfill.py [--start 2026-02-07] [--end 2026-04-27]
"""
import argparse
import datetime
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONFIG = "projects/61470654236/locations/asia-northeast1/transferConfigs/69f8f10d-0000-2cb7-b8d4-30fd38139dd0"
GCLOUD = r"C:\Users\user\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def get_token():
    return subprocess.run([GCLOUD, "auth", "print-access-token"], capture_output=True, text=True).stdout.strip()


def api_call(method, path, body=None, token=None):
    url = f"https://bigquerydatatransfer.googleapis.com/v1/{path}"
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read())
        except Exception:
            err_body = {}
        return e.code, err_body


def list_active_runs(token):
    """Return PENDING/RUNNING runs."""
    code, data = api_call("GET", f"{CONFIG}/runs?states=PENDING&states=RUNNING&pageSize=10", token=token)
    if code != 200:
        return []
    return data.get("transferRuns", [])


def trigger_day(day, token):
    body = {"requestedRunTime": day.strftime("%Y-%m-%dT00:00:00Z")}
    code, data = api_call("POST", f"{CONFIG}:startManualRuns", body=body, token=token)
    if code == 200:
        return data["runs"][0]["name"], None
    return None, f"{code}: {(data.get('error') or {}).get('message') or data}"


def wait_idle(token, max_wait=600):
    """Wait until no PENDING/RUNNING runs (or timeout)."""
    waited = 0
    while waited < max_wait:
        runs = list_active_runs(token)
        if not runs:
            return True
        time.sleep(20)
        waited += 20
    return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--start", default="2026-02-07")
    p.add_argument("--end", default="2026-04-27", help="exclusive")
    p.add_argument("--max-wait-per-day", type=int, default=900)
    args = p.parse_args()

    start = datetime.datetime.strptime(args.start, "%Y-%m-%d").date()
    end = datetime.datetime.strptime(args.end, "%Y-%m-%d").date()
    total = (end - start).days
    print(f"Backfill {start} ~ {end} ({total} days)")

    token = get_token()
    refresh_at = time.time() + 600  # refresh token every 10 min (gcloud token TTL is 1h but be safe)

    ok = 0
    err = 0
    day = start
    while day < end:
        # Refresh token periodically
        if time.time() > refresh_at:
            token = get_token()
            refresh_at = time.time() + 600

        # Wait for idle state
        if not wait_idle(token, max_wait=args.max_wait_per_day):
            print(f"\n[{day}] timeout waiting for idle state, skipping")
            err += 1
            day += datetime.timedelta(days=1)
            continue

        # Trigger
        run_name, error = trigger_day(day, token)
        if error:
            print(f"\n[{day}] FAIL: {error}")
            err += 1
        else:
            ok += 1
            elapsed_pct = ((day - start).days + 1) * 100 // total
            print(f"[{day}] queued ({ok}/{total}, {elapsed_pct}%)")

        day += datetime.timedelta(days=1)
        time.sleep(2)  # small pause to let state update

    print(f"\nDone. Triggered: {ok}, Errors: {err}")


if __name__ == "__main__":
    main()
