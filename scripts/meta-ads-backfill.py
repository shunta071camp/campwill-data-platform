"""
Meta Ads backfill: 指定期間の insights + actions を Meta Marketing API から取得して raw に投入。

n8n workflow (meta-ads-daily) と同じロジックを Python で実装。日を跨いで反復する。

Usage:
    python scripts/meta-ads-backfill.py 2026-06-30 2026-07-04
"""
import json
import os
import sys
import time
from datetime import datetime, date, timedelta, timezone

import requests
from google.cloud import bigquery

PROJECT = "campwill-ec"


def daterange(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def fetch_day(token: str, ad_account_id: str, d: date) -> tuple[list, list]:
    """Fetch one day of insights + return (insights_rows, action_rows).

    Retries on rate-limit (code=4 / 17 / subcode 1504022) with exponential backoff.
    """
    for attempt in range(6):
        resp = requests.get(
            f"https://graph.facebook.com/v21.0/act_{ad_account_id}/insights",
            params={
                "access_token": token,
                "level": "ad",
                "time_range": json.dumps({"since": d.isoformat(), "until": d.isoformat()}),
                "time_increment": "1",
                "fields": (
                    "campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,"
                    "objective,buying_type,account_currency,impressions,clicks,spend,"
                    "reach,frequency,cpc,cpm,cpp,ctr,unique_clicks,unique_ctr,"
                    "inline_link_clicks,inline_post_engagement,outbound_clicks,actions"
                ),
                "action_attribution_windows": "['1d_click','1d_view','7d_click','7d_view','28d_click','28d_view']",
                "limit": 500,
            },
            timeout=60,
        )
        body = resp.json()
        err = body.get("error")
        if err and err.get("code") in (4, 17, 32) and attempt < 5:
            wait = 60 * (attempt + 1)
            print(f"  rate limit for {d} (attempt {attempt + 1}), waiting {wait}s")
            time.sleep(wait)
            continue
        if err:
            raise RuntimeError(f"Meta API error for {d}: {err}")
        break

    now = datetime.now(timezone.utc).isoformat()
    date_str = d.isoformat()

    def to_num(v):
        return None if v in (None, "") else float(v)

    def to_str(v):
        return None if v is None else str(v)

    insights = []
    actions = []
    for r in body.get("data", []):
        outbound = sum(int(x.get("value", 0)) for x in r.get("outbound_clicks", []) or []) or None
        insights.append({
            "DateStart": date_str,
            "AdAccountId": ad_account_id,
            "CampaignId": to_str(r.get("campaign_id")),
            "CampaignName": r.get("campaign_name"),
            "AdSetId": to_str(r.get("adset_id")),
            "AdSetName": r.get("adset_name"),
            "AdId": to_str(r.get("ad_id")),
            "AdName": r.get("ad_name"),
            "Objective": r.get("objective"),
            "BuyingType": r.get("buying_type"),
            "Impressions": to_num(r.get("impressions")),
            "Clicks": to_num(r.get("clicks")),
            "Spend": to_num(r.get("spend")),
            "Reach": to_num(r.get("reach")),
            "Frequency": to_num(r.get("frequency")),
            "CPC": to_num(r.get("cpc")),
            "CPM": to_num(r.get("cpm")),
            "CPP": to_num(r.get("cpp")),
            "CTR": to_num(r.get("ctr")),
            "UniqueClicks": to_num(r.get("unique_clicks")),
            "UniqueCTR": to_num(r.get("unique_ctr")),
            "InlineLinkClicks": to_num(r.get("inline_link_clicks")),
            "InlinePostEngagement": to_num(r.get("inline_post_engagement")),
            "OutboundClicks": outbound,
            "Level": "ad",
            "AccountCurrency": r.get("account_currency"),
            "inserted_at": now,
        })
        for a in r.get("actions", []) or []:
            actions.append({
                "DateStart": date_str,
                "AdAccountId": ad_account_id,
                "CampaignId": to_str(r.get("campaign_id")),
                "AdSetId": to_str(r.get("adset_id")),
                "AdId": to_str(r.get("ad_id")),
                "ActionType": a.get("action_type"),
                "ActionCollection": "Actions",
                "ActionValue": int(a["value"]) if a.get("value") not in (None, "") else None,
                "Action1dClick": to_str(a.get("1d_click")),
                "Action1dView": to_str(a.get("1d_view")),
                "Action7dClick": to_str(a.get("7d_click")),
                "Action7dView": to_str(a.get("7d_view")),
                "Action28dClick": to_str(a.get("28d_click")),
                "Action28dView": to_str(a.get("28d_view")),
                "inserted_at": now,
            })
    return insights, actions


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python scripts/meta-ads-backfill.py YYYY-MM-DD YYYY-MM-DD", file=sys.stderr)
        return 1

    start = date.fromisoformat(sys.argv[1])
    end = date.fromisoformat(sys.argv[2])

    client = bigquery.Client(project=PROJECT)
    row = list(client.query(
        "SELECT access_token, JSON_VALUE(metadata, '$.ad_account_id') AS aid "
        "FROM `campwill-ec.raw.oauth_tokens` WHERE provider='meta_ads'"
    ).result())[0]
    token = row["access_token"]
    aid = row["aid"]

    total_i = 0
    total_a = 0
    for d in daterange(start, end):
        insights, actions = fetch_day(token, aid, d)
        print(f"[{d}] insights={len(insights)} actions={len(actions)}")
        if insights:
            errs = client.insert_rows_json("campwill-ec.raw.ec_meta_ads_insights", insights)
            if errs:
                print(f"  insights insert errors: {errs[:3]}", file=sys.stderr)
                return 2
        if actions:
            errs = client.insert_rows_json("campwill-ec.raw.ec_meta_ads_insights_actions", actions)
            if errs:
                print(f"  actions insert errors: {errs[:3]}", file=sys.stderr)
                return 2
        total_i += len(insights)
        total_a += len(actions)

    print()
    print(f"[DONE] total insights={total_i}, actions={total_a}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
