"""
campwill-realestate raw 5 テーブルへの日次 sync。

tenant-leasing アプリの /api/export/* を Bearer token で叩いて全件取得し、
BigQuery raw テーブルを truncate + insert で更新する。

データ規模が小さい (master 数百〜数千件) ので full sync で十分。差分計算なし。

実行:
    python3 scripts/realestate-sync.py

必要な env:
    EXPORT_API_KEY  : tenant-leasing 側 EXPORT_API_KEY と一致
    EXPORT_BASE_URL : 例 https://tenant-leasing.onrender.com (デフォルト)
    GOOGLE_APPLICATION_CREDENTIALS : SA key path
                                     (n8n-pipeline@campwill-realestate.iam.gserviceaccount.com 推奨)

cron: Render Cron Job で毎日 04:30 JST (= 19:30 UTC) を推奨。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

EXPORT_API_KEY = (os.environ.get("EXPORT_API_KEY") or "").strip()
EXPORT_BASE_URL = os.environ.get("EXPORT_BASE_URL", "https://tenant-leasing.onrender.com").rstrip("/")

# env が無い / 不正な場合は対話入力に fallback (PowerShell 経由のコピペ事故を回避)
if not EXPORT_API_KEY:
    import getpass
    EXPORT_API_KEY = getpass.getpass("EXPORT_API_KEY (hidden, paste then Enter): ").strip()

if not EXPORT_API_KEY.isascii():
    bad = [(i, c, hex(ord(c))) for i, c in enumerate(EXPORT_API_KEY) if ord(c) > 127]
    raise RuntimeError(
        f"EXPORT_API_KEY contains non-ASCII characters at: {bad[:5]}. "
        "Paste again from Render Dashboard."
    )

print(f"==> EXPORT_API_KEY length: {len(EXPORT_API_KEY)} (expect 44 for base64-32)")
PROJECT = "campwill-realestate"
DATASET = "raw"

RESOURCES = [
    # (endpoint suffix, BQ table name)
    ("tenants",    "re_tenants"),
    ("deals",      "re_deals"),
    ("activities", "re_activities"),
    ("properties", "re_properties"),
    ("owners",     "re_owners"),
]


def fetch_all(resource: str) -> list[dict]:
    """1 リソースの全件を cursor pagination で取得。"""
    items: list[dict] = []
    cursor: int | None = None
    while True:
        params = {"limit": "5000"}
        if cursor is not None:
            params["cursor"] = str(cursor)
        url = f"{EXPORT_BASE_URL}/api/export/{resource}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {EXPORT_API_KEY}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {e.code} fetching {resource}: {body}")

        page = data.get("items", [])
        items.extend(page)
        next_cursor = data.get("next_cursor")
        if not next_cursor:
            break
        cursor = next_cursor

    return items


def normalize_row(row: dict, inserted_at: str) -> dict:
    """Prisma JSON の Date/DateTime を BQ TIMESTAMP/DATE 文字列に揃える。"""
    out = {}
    for k, v in row.items():
        if v is None:
            out[k] = None
        elif isinstance(v, (str, int, float, bool)):
            out[k] = v
        elif isinstance(v, dict) or isinstance(v, list):
            out[k] = json.dumps(v, ensure_ascii=False)
        else:
            out[k] = str(v)
    out["inserted_at"] = inserted_at
    return out


_BQ_CLIENT = None


def get_bq_client():
    """BQ client を生成 (cached)。

    認証ソース優先順:
      1. env GOOGLE_APPLICATION_CREDENTIALS_JSON (SA key の JSON 文字列、Render Cron 向け)
      2. env GOOGLE_APPLICATION_CREDENTIALS (SA key のファイルパス、ローカル向け)
      3. デフォルト (gcloud auth application-default login)
    """
    global _BQ_CLIENT
    if _BQ_CLIENT is not None:
        return _BQ_CLIENT
    from google.cloud import bigquery

    json_creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS_JSON")
    if json_creds:
        from google.oauth2 import service_account
        info = json.loads(json_creds)
        credentials = service_account.Credentials.from_service_account_info(info)
        _BQ_CLIENT = bigquery.Client(project=PROJECT, credentials=credentials)
    else:
        _BQ_CLIENT = bigquery.Client(project=PROJECT)
    return _BQ_CLIENT


def write_to_bq(table_name: str, rows: list[dict]) -> None:
    """raw テーブルを truncate + insert (insert_rows_json で stream)。"""
    from google.cloud import bigquery

    client = get_bq_client()
    fqn = f"{PROJECT}.{DATASET}.{table_name}"
    inserted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    # 1) truncate
    client.query(f"TRUNCATE TABLE `{fqn}`").result()

    if not rows:
        print(f"  [OK] {table_name}: 0 rows")
        return

    # 2) insert (stream)
    payload = [normalize_row(r, inserted_at) for r in rows]

    # truncate 直後の streaming buffer 衝突を避けるため、load job を使う
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
    )
    ndjson = "\n".join(json.dumps(r, ensure_ascii=False) for r in payload).encode("utf-8")
    from io import BytesIO
    job = client.load_table_from_file(BytesIO(ndjson), fqn, job_config=job_config)
    job.result()
    print(f"  [OK] {table_name}: {len(payload)} rows")


def main() -> None:
    if not EXPORT_API_KEY:
        print("ERROR: EXPORT_API_KEY env var is required", file=sys.stderr)
        sys.exit(1)

    print(f"==> realestate sync from {EXPORT_BASE_URL}")
    print(f"==> target: {PROJECT}:{DATASET}")
    print()

    for resource, table_name in RESOURCES:
        print(f"==> {resource} -> {table_name}")
        t0 = time.time()
        items = fetch_all(resource)
        write_to_bq(table_name, items)
        print(f"    elapsed: {time.time() - t0:.1f}s")
        print()

    print("==> sync completed")


if __name__ == "__main__":
    main()
