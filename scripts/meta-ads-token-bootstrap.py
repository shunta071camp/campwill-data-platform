"""
Meta Ads OAuth token bootstrap.

Registers the initial long-lived System User token to raw.oauth_tokens
so that meta-ads-daily.json and meta-ads-token-refresh.json workflows
can consume/rotate it.

Usage (PowerShell):
    $env:META_APP_ID = "1569364718102062"
    $env:META_APP_SECRET = "<app-secret>"
    $env:META_ACCESS_TOKEN = "<60-day-system-user-token>"
    $env:META_AD_ACCOUNT_ID = "2812178249004505"
    python scripts/meta-ads-token-bootstrap.py

After running, verify:
    SELECT provider, expires_at, refresh_count, LEFT(access_token, 20) AS token_head
    FROM `campwill-ec.raw.oauth_tokens`
    WHERE provider = 'meta_ads';
"""
import os
import sys
from datetime import datetime, timedelta, timezone

from google.cloud import bigquery

PROJECT = "campwill-ec"
DATASET = "raw"
TABLE = "oauth_tokens"
PROVIDER = "meta_ads"


def main() -> int:
    app_id = os.environ.get("META_APP_ID", "").strip()
    app_secret = os.environ.get("META_APP_SECRET", "").strip()
    access_token = os.environ.get("META_ACCESS_TOKEN", "").strip()
    ad_account_id = os.environ.get("META_AD_ACCOUNT_ID", "").strip()

    missing = [
        n
        for n, v in [
            ("META_APP_ID", app_id),
            ("META_APP_SECRET", app_secret),
            ("META_ACCESS_TOKEN", access_token),
            ("META_AD_ACCOUNT_ID", ad_account_id),
        ]
        if not v
    ]
    if missing:
        print(f"[ERROR] missing env vars: {', '.join(missing)}", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=60)
    scope = "ads_read"

    client = bigquery.Client(project=PROJECT)
    table_ref = f"`{PROJECT}.{DATASET}.{TABLE}`"

    query = f"""
    MERGE {table_ref} T
    USING (SELECT @provider AS provider) S
    ON T.provider = S.provider
    WHEN MATCHED THEN UPDATE SET
        access_token   = @access_token,
        refresh_token  = @access_token,
        expires_at     = @expires_at,
        scope          = @scope,
        client_id      = @client_id,
        client_secret  = @client_secret,
        rotated_at     = @now,
        rotated_by     = 'meta-ads-token-bootstrap',
        last_error     = NULL,
        last_error_at  = NULL,
        updated_at     = @now,
        metadata       = TO_JSON_STRING(STRUCT(@ad_account_id AS ad_account_id))
    WHEN NOT MATCHED THEN INSERT
        (provider, access_token, refresh_token, expires_at, scope,
         client_id, client_secret, rotated_at, rotated_by,
         refresh_count, updated_at, metadata)
    VALUES
        (@provider, @access_token, @access_token, @expires_at, @scope,
         @client_id, @client_secret, @now, 'meta-ads-token-bootstrap',
         0, @now, TO_JSON_STRING(STRUCT(@ad_account_id AS ad_account_id)));
    """

    job = client.query(
        query,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("provider", "STRING", PROVIDER),
                bigquery.ScalarQueryParameter("access_token", "STRING", access_token),
                bigquery.ScalarQueryParameter("expires_at", "TIMESTAMP", expires_at),
                bigquery.ScalarQueryParameter("scope", "STRING", scope),
                bigquery.ScalarQueryParameter("client_id", "STRING", app_id),
                bigquery.ScalarQueryParameter("client_secret", "STRING", app_secret),
                bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
                bigquery.ScalarQueryParameter("ad_account_id", "STRING", ad_account_id),
            ]
        ),
    )
    job.result()

    print(f"[OK] provider={PROVIDER} registered")
    print(f"     expires_at = {expires_at.isoformat()}")
    print(f"     ad_account_id = {ad_account_id}")
    print(f"     client_id = {app_id}")
    print(f"     access_token = {access_token[:20]}... (len={len(access_token)})")
    print()
    print("Next: apply schema addition if `metadata` column doesn't exist:")
    print("  ALTER TABLE `campwill-ec.raw.oauth_tokens` ADD COLUMN IF NOT EXISTS metadata STRING;")
    return 0


if __name__ == "__main__":
    sys.exit(main())
