#!/usr/bin/env python3
"""
Shopify Orders Initial Backfill — Bulk Operations API edition.

What this does:
  1. Get short-lived access token via OAuth client_credentials grant
     (or use SHOPIFY_ACCESS_TOKEN if set in .env)
  2. Submit Shopify Bulk Operations GraphQL query to dump ALL orders
  3. Poll status until COMPLETED
  4. Download the JSONL file from Shopify CDN
  5. Transform to BigQuery raw.ec_shopify_orders schema (1 line_item = 1 row)
  6. Run `bq load` to upload to BigQuery

Why a Python script instead of n8n:
  - n8n cloud's memory limit OOMs on 15k+ orders
  - Bulk Operations is async, doesn't tie up an n8n execution slot
  - `bq load` is dramatically faster than streaming insert for large batches

Stdlib only — no `pip install` needed.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
ENV_PATH = SCRIPT_DIR / ".env"
DATA_DIR = SCRIPT_DIR / "data"
RAW_JSONL = DATA_DIR / "shopify-orders-raw.jsonl"
TRANSFORMED_JSONL = DATA_DIR / "shopify-orders-bq.jsonl"

API_VERSION = "2024-10"

# Force unbuffered stdout so progress prints show up immediately when run
# via Bash run_in_background or `python ... > file` pipelines.
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


# ---------------------------------------------------------------------------
# Env loading
# ---------------------------------------------------------------------------

def load_env(path: Path) -> dict:
    if not path.exists():
        sys.exit(f"ERROR: {path} not found. Copy .env.example to .env and fill in.")
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def get_access_token(shop: str, client_id: str, client_secret: str) -> str:
    """OAuth client_credentials grant. Requires the app to be installed on the shop."""
    url = f"https://{shop}/admin/oauth/access_token"
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "grant_type": "client_credentials",
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        # Try to extract just the human readable error from Shopify's HTML 4xx page
        m = re.search(r'(?:What happened\?|error|Error)[\s\S]{0,500}', body_text)
        snippet = m.group(0) if m else body_text[:1500]
        snippet = re.sub(r'<[^>]+>', ' ', snippet)
        snippet = re.sub(r'\s+', ' ', snippet).strip()
        sys.exit(f"Failed to get access token (HTTP {e.code}): {snippet}")
    return data["access_token"]


# ---------------------------------------------------------------------------
# GraphQL
# ---------------------------------------------------------------------------

def graphql(shop: str, token: str, query: str, variables: dict = None) -> dict:
    url = f"https://{shop}/admin/api/{API_VERSION}/graphql.json"
    body = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Shopify-Access-Token": token,
        },
    )
    with urllib.request.urlopen(req) as resp:
        data = json.load(resp)
    if data.get("errors"):
        sys.exit(f"GraphQL errors: {json.dumps(data['errors'], indent=2)}")
    return data["data"]


BULK_QUERY_MUTATION = r'''
mutation {
  bulkOperationRunQuery(
    query: """
    {
      orders {
        edges {
          node {
            id
            name
            createdAt
            email
            customer { id email }
            displayFinancialStatus
            totalPriceSet { shopMoney { amount } }
            subtotalPriceSet { shopMoney { amount } }
            totalDiscountsSet { shopMoney { amount } }
            totalTaxSet { shopMoney { amount } }
            totalRefundedSet { shopMoney { amount } }
            sourceName
            landingPageUrl
            referrerUrl
            tags
            lineItems {
              edges {
                node {
                  id
                  product { id }
                  variant { id }
                  sku
                  title
                  variantTitle
                  quantity
                  originalUnitPriceSet { shopMoney { amount } }
                  discountAllocations {
                    allocatedAmountSet { shopMoney { amount } }
                  }
                }
              }
            }
            refunds {
              id
              createdAt
              note
            }
          }
        }
      }
    }
    """
  ) {
    bulkOperation { id status }
    userErrors { field message }
  }
}
'''


CURRENT_BULK_QUERY = """
{
  currentBulkOperation {
    id
    status
    errorCode
    createdAt
    completedAt
    objectCount
    fileSize
    url
  }
}
"""


def submit_bulk_operation(shop: str, token: str):
    print("[1/5] Submitting bulk operation...")
    data = graphql(shop, token, BULK_QUERY_MUTATION)
    r = data["bulkOperationRunQuery"]
    if r["userErrors"]:
        # If there's already a bulk operation running (e.g. from a previous killed run),
        # don't error out — just skip submission and poll the existing one.
        msgs = " ".join(str(e.get("message", "")) for e in r["userErrors"])
        if "already in progress" in msgs:
            print(f"      Existing bulk op detected, will poll it instead: {msgs}")
            return
        sys.exit(f"User errors: {r['userErrors']}")
    print(f"      Started bulk op id={r['bulkOperation']['id']} status={r['bulkOperation']['status']}")


def poll_bulk_operation(shop: str, token: str, interval_sec: int = 15) -> str:
    print(f"[2/5] Polling status every {interval_sec}s...")
    while True:
        data = graphql(shop, token, CURRENT_BULK_QUERY)
        op = data["currentBulkOperation"]
        if not op:
            sys.exit("No current bulk operation found.")
        status = op["status"]
        count = op.get("objectCount") or "?"
        size = op.get("fileSize") or "?"
        print(f"      [{datetime.now().strftime('%H:%M:%S')}] status={status} objectCount={count} fileSize={size}")
        if status == "COMPLETED":
            url = op.get("url")
            if not url:
                sys.exit("Completed but no URL returned (empty result?). Check the shop has orders.")
            return url
        if status in ("FAILED", "CANCELED", "EXPIRED"):
            sys.exit(f"Bulk operation ended unexpectedly: {op}")
        time.sleep(interval_sec)


def download_jsonl(url: str, dest: Path):
    print(f"[3/5] Downloading JSONL -> {dest}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as resp, dest.open("wb") as f:
        bytes_total = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            bytes_total += len(chunk)
    print(f"      Saved {bytes_total:,} bytes")


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

def to_int_yen(v):
    if v is None or v == "":
        return None
    try:
        return round(float(v))
    except (ValueError, TypeError):
        return None


def to_date(iso):
    return iso.split("T")[0] if iso else None


def parse_utm(url):
    if not url:
        return (None, None, None)
    try:
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        return (
            qs.get("utm_source", [None])[0],
            qs.get("utm_medium", [None])[0],
            qs.get("utm_campaign", [None])[0],
        )
    except Exception:
        return (None, None, None)


def gid_to_id(gid):
    if not gid:
        return None
    return gid.split("/")[-1]


def money(node, field):
    """Extract amount from MoneyBag-like {shopMoney: {amount: '...'}} structure."""
    d = (node or {}).get(field) or {}
    sm = d.get("shopMoney") or {}
    return to_int_yen(sm.get("amount"))


def transform_jsonl(raw: Path, out: Path):
    print(f"[4/5] Transforming {raw.name} -> {out.name}")

    orders = {}
    line_items_by_order = {}
    refunds_by_order = {}

    with raw.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            id_ = obj.get("id", "")
            parent = obj.get("__parentId")
            if "/Order/" in id_ and not parent:
                orders[id_] = obj
            elif "/LineItem/" in id_:
                line_items_by_order.setdefault(parent, []).append(obj)
            elif "/Refund/" in id_:
                refunds_by_order.setdefault(parent, []).append(obj)
            # else: silently skip

    print(f"      Parsed: {len(orders):,} orders, {sum(len(v) for v in line_items_by_order.values()):,} line items, {sum(len(v) for v in refunds_by_order.values()):,} refunds")

    now = datetime.now(timezone.utc).isoformat()
    out.parent.mkdir(parents=True, exist_ok=True)
    row_count = 0
    skipped_no_email = 0

    with out.open("w", encoding="utf-8") as f:
        for order_gid, o in orders.items():
            customer = o.get("customer") or {}
            customer_email = customer.get("email") or o.get("email")
            if not customer_email:
                skipped_no_email += 1
                continue

            refunds = refunds_by_order.get(order_gid, [])
            first_refund = refunds[0] if refunds else None
            refund_date = None
            refund_amount = None
            refund_reason = None
            if first_refund:
                refund_date = to_date(first_refund.get("createdAt"))
                refund_reason = first_refund.get("note")
                # Use order-level totalRefundedSet (sum across all refunds for this order)
                refund_amount = money(o, "totalRefundedSet")

            utm_source, utm_medium, utm_campaign = parse_utm(o.get("landingPageUrl"))
            tags_raw = o.get("tags")
            tags = ",".join(tags_raw) if isinstance(tags_raw, list) else tags_raw

            for li in line_items_by_order.get(order_gid, []):
                line_disc_total = sum(
                    float((da.get("allocatedAmountSet", {}).get("shopMoney", {}) or {}).get("amount", 0) or 0)
                    for da in (li.get("discountAllocations") or [])
                )
                row = {
                    "order_id": gid_to_id(order_gid),
                    "order_name": o.get("name"),
                    "created_at": o.get("createdAt"),
                    "order_date": to_date(o.get("createdAt")),
                    "customer_id": gid_to_id(customer.get("id")) if customer.get("id") else None,
                    "customer_email": customer_email,
                    "financial_status": (o.get("displayFinancialStatus") or "").lower() or None,
                    "total_price": money(o, "totalPriceSet"),
                    "subtotal_price": money(o, "subtotalPriceSet"),
                    "total_discounts": money(o, "totalDiscountsSet"),
                    "total_tax": money(o, "totalTaxSet"),
                    "line_item_id": gid_to_id(li.get("id")),
                    "product_id": gid_to_id((li.get("product") or {}).get("id")),
                    "variant_id": gid_to_id((li.get("variant") or {}).get("id")),
                    "sku": li.get("sku") or "",
                    "sku_title": li.get("title"),
                    "variant_title": li.get("variantTitle"),
                    "quantity": li.get("quantity"),
                    "unit_price": money(li, "originalUnitPriceSet"),
                    "line_discount": to_int_yen(line_disc_total) if line_disc_total > 0 else None,
                    "is_refunded": first_refund is not None,
                    "refund_date": refund_date,
                    "refund_amount": refund_amount,
                    "refund_reason": refund_reason,
                    "source_name": o.get("sourceName"),
                    "landing_site": o.get("landingPageUrl"),
                    "referring_site": o.get("referrerUrl"),
                    "utm_source": utm_source,
                    "utm_medium": utm_medium,
                    "utm_campaign": utm_campaign,
                    "tags": tags,
                    "inserted_at": now,
                }
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
                row_count += 1

    print(f"      Wrote {row_count:,} rows; skipped {skipped_no_email} orders without email")


# ---------------------------------------------------------------------------
# bq load
# ---------------------------------------------------------------------------

def bq_load(jsonl: Path, project_id: str):
    print(f"[5/5] bq load -> {project_id}:raw.ec_shopify_orders")
    # On Windows, bq is bq.cmd (batch file). Python's subprocess can't find it
    # by bare name without shell=True; resolve the full path first.
    bq_exe = shutil.which("bq") or shutil.which("bq.cmd") or shutil.which("bq.bat")
    if not bq_exe:
        sys.exit("bq command not found in PATH. Verify gcloud SDK is installed and on PATH.")
    cmd = [
        bq_exe, "load",
        "--source_format=NEWLINE_DELIMITED_JSON",
        f"--project_id={project_id}",
        f"{project_id}:raw.ec_shopify_orders",
        str(jsonl),
    ]
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    print(f"      $ {' '.join(cmd)}")
    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        sys.exit(f"bq load failed (exit {result.returncode}). Check rows in data/shopify-orders-bq.jsonl")
    print("      bq load OK")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    env = load_env(ENV_PATH)
    shop = env["SHOPIFY_SHOP"]
    project_id = env["GCP_PROJECT_ID"]

    token = env.get("SHOPIFY_ACCESS_TOKEN")
    if token:
        print("Using SHOPIFY_ACCESS_TOKEN from .env (skipping client_credentials grant)")
    else:
        client_id = env.get("SHOPIFY_CLIENT_ID")
        client_secret = env.get("SHOPIFY_CLIENT_SECRET")
        if not (client_id and client_secret):
            sys.exit("Need either SHOPIFY_ACCESS_TOKEN or both SHOPIFY_CLIENT_ID and SHOPIFY_CLIENT_SECRET in .env")
        token = get_access_token(shop, client_id, client_secret)
        print(f"Got access token via client_credentials grant (length={len(token)})")

    submit_bulk_operation(shop, token)
    url = poll_bulk_operation(shop, token)
    download_jsonl(url, RAW_JSONL)
    transform_jsonl(RAW_JSONL, TRANSFORMED_JSONL)
    bq_load(TRANSFORMED_JSONL, project_id)

    print("\nAll done. Verify with:")
    print(f"  bq query --use_legacy_sql=false --project_id={project_id} \\")
    print(f"    'SELECT EXTRACT(YEAR FROM created_at) AS y, COUNT(DISTINCT order_id) AS orders \\")
    print(f"     FROM `{project_id}.raw.ec_shopify_orders` GROUP BY y ORDER BY y'")


if __name__ == "__main__":
    main()
