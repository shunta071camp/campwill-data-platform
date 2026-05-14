"""
Inject OAuth refresh nodes into microsoft-ads.json / microsoft-ads-backfill.json.

Usage:
    python _ms_ads_oauth_inject.py incremental
    python _ms_ads_oauth_inject.py backfill
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
WF_DIR = ROOT / "n8n" / "workflows"
PARSE_JS = Path(__file__).parent / "_ms_ads_oauth_parse.js"

CRED_BASIC = {"id": "Bf4kZm9AZY7xt1rm", "name": "Microsoft Ads Client (Basic)"}
CRED_BQ = {"id": "WCCQWQHLcPs05bNu", "name": "Google Service Account account（EC）"}

PROJECT_RL = {"__rl": True, "mode": "list", "value": "campwill-ec", "cachedResultName": "campwill-ec"}


def build_oauth_block(rotated_by: str):
    """Returns list of new nodes (in order) and connection updates."""
    parse_js = PARSE_JS.read_text(encoding="utf-8").replace("__ROTATED_BY__", rotated_by)

    nodes = [
        # 1. BQ Read: oauth_tokens
        {
            "parameters": {
                "authentication": "serviceAccount",
                "operation": "executeQuery",
                "projectId": PROJECT_RL,
                "sqlQuery": "SELECT provider, refresh_token, client_id, client_secret FROM `campwill-ec.raw.oauth_tokens` WHERE provider = 'microsoft_ads' LIMIT 1",
                "options": {"useLegacySql": False},
            },
            "id": "oauth-bq-read",
            "name": "BQ Read: oauth_tokens",
            "type": "n8n-nodes-base.googleBigQuery",
            "typeVersion": 2,
            "position": [-1300, -100],
            "credentials": {"googleApi": CRED_BQ},
        },
        # 2. HTTP: Refresh Microsoft Token
        {
            "parameters": {
                "method": "POST",
                "url": "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                "authentication": "none",
                "sendHeaders": True,
                "headerParameters": {
                    "parameters": [
                        {"name": "Content-Type", "value": "application/x-www-form-urlencoded"}
                    ]
                },
                "sendBody": True,
                "contentType": "form-urlencoded",
                "bodyParameters": {
                    "parameters": [
                        {"name": "grant_type", "value": "refresh_token"},
                        {"name": "client_id", "value": "={{ $json.client_id }}"},
                        {"name": "client_secret", "value": "={{ $json.client_secret }}"},
                        {"name": "refresh_token", "value": "={{ $json.refresh_token }}"},
                        {"name": "scope", "value": "https://ads.microsoft.com/msads.manage offline_access"},
                    ]
                },
                "options": {
                    "response": {"response": {"neverError": True, "fullResponse": True}},
                    "timeout": 30000,
                    "retry": {"enabled": True, "maxRetries": 2, "waitBetweenRetries": 5000},
                },
            },
            "id": "oauth-http-refresh",
            "name": "HTTP: Refresh Microsoft Token",
            "type": "n8n-nodes-base.httpRequest",
            "typeVersion": 4.2,
            "position": [-1100, -100],
        },
        # 3. Code: Parse Refresh Response
        {
            "parameters": {"jsCode": parse_js},
            "id": "oauth-parse",
            "name": "Code: Parse Refresh Response",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [-900, -100],
        },
        # 4. BQ Write: MERGE oauth_tokens
        {
            "parameters": {
                "authentication": "serviceAccount",
                "operation": "executeQuery",
                "projectId": PROJECT_RL,
                "sqlQuery": "={{ $json.merge_sql }}",
                "options": {"useLegacySql": False},
            },
            "id": "oauth-bq-write",
            "name": "BQ Write: MERGE oauth_tokens",
            "type": "n8n-nodes-base.googleBigQuery",
            "typeVersion": 2,
            "position": [-700, -100],
            "credentials": {"googleApi": CRED_BQ},
        },
        # 5. Set: OAuth Context
        {
            "parameters": {
                "assignments": {
                    "assignments": [
                        {
                            "id": "status",
                            "name": "oauth_status",
                            "value": "={{ $('Code: Parse Refresh Response').item.json.status }}",
                            "type": "string",
                        },
                        {
                            "id": "access-token",
                            "name": "access_token",
                            "value": "={{ $('Code: Parse Refresh Response').item.json.access_token }}",
                            "type": "string",
                        },
                        {
                            "id": "expires-at",
                            "name": "expires_at",
                            "value": "={{ $('Code: Parse Refresh Response').item.json.expires_at }}",
                            "type": "string",
                        },
                    ]
                },
                "options": {},
            },
            "id": "oauth-set-context",
            "name": "Set: OAuth Context",
            "type": "n8n-nodes-base.set",
            "typeVersion": 3.4,
            "position": [-500, -100],
        },
        # 6. If: OAuth refresh failed
        {
            "parameters": {
                "conditions": {
                    "options": {"caseSensitive": True, "typeValidation": "strict", "version": 1},
                    "conditions": [
                        {
                            "leftValue": "={{ $json.oauth_status }}",
                            "rightValue": "success",
                            "operator": {"type": "string", "operation": "notEquals"},
                        }
                    ],
                    "combinator": "and",
                },
                "options": {},
            },
            "id": "oauth-if-failed",
            "name": "If: OAuth refresh failed",
            "type": "n8n-nodes-base.if",
            "typeVersion": 2,
            "position": [-300, -100],
        },
        # 7. Throw: OAuth refresh dead (for true branch of If)
        {
            "parameters": {
                "errorMessage": "Microsoft Ads OAuth refresh failed. Check raw.oauth_tokens.last_error and raw.oauth_tokens_history. Probably refresh_token revoked - run bootstrap again.",
            },
            "id": "oauth-throw",
            "name": "Throw: OAuth refresh dead",
            "type": "n8n-nodes-base.stopAndError",
            "typeVersion": 1,
            "position": [-100, -200],
        },
    ]
    return nodes


def update_existing_node(node, set_node_name="Set: Date Range + Customer/Account"):
    """Patch Submit/Poll nodes: remove n8n OAuth, add Authorization header."""
    if node.get("type") != "n8n-nodes-base.httpRequest":
        return
    name = node.get("name", "")
    if name not in ("Submit Campaign Performance Report", "Submit Backfill Report", "Poll Report Status"):
        return

    # Remove n8n OAuth credential
    if "credentials" in node and "oAuth2Api" in node.get("credentials", {}):
        del node["credentials"]["oAuth2Api"]
        if not node["credentials"]:
            del node["credentials"]

    # Switch authentication to none
    p = node["parameters"]
    p["authentication"] = "none"
    p.pop("nodeCredentialType", None)

    # Add Authorization header at the front
    headers = p.get("headerParameters", {}).get("parameters", [])
    # Remove existing Authorization if present
    headers = [h for h in headers if h.get("name", "").lower() != "authorization"]
    auth_header = {
        "name": "Authorization",
        "value": "=Bearer {{ $('Set: OAuth Context').item.json.access_token }}",
    }
    headers.insert(0, auth_header)
    p["headerParameters"]["parameters"] = headers


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("incremental", "backfill"):
        print("Usage: python _ms_ads_oauth_inject.py [incremental|backfill]")
        sys.exit(1)

    target = sys.argv[1]
    if target == "incremental":
        wf_path = WF_DIR / "microsoft-ads.json"
        rotated_by = "microsoft-ads-incremental"
        trigger_name = "Schedule: 3:30 AM JST"
    else:
        wf_path = WF_DIR / "microsoft-ads-backfill.json"
        rotated_by = "microsoft-ads-backfill"
        trigger_name = "Manual Trigger"

    wf = json.loads(wf_path.read_text(encoding="utf-8"))

    # Detect existing trigger node
    nodes = wf["nodes"]
    trigger_node = next((n for n in nodes if n["name"] == trigger_name), None)
    if not trigger_node:
        sys.exit(f"ERROR: trigger node '{trigger_name}' not found in {wf_path}")

    # Build oauth block
    oauth_nodes = build_oauth_block(rotated_by)

    # Detect "Set: Date Range..." existing node (after which trigger originally connects)
    set_node = next(n for n in nodes if n["name"].startswith("Set: Date Range"))
    set_node_name = set_node["name"]

    # Remove old connection trigger -> Set, replace with trigger -> oauth chain
    conns = wf["connections"]
    # Remove existing trigger -> Set
    if trigger_name in conns:
        conns[trigger_name]["main"][0] = [{"node": "BQ Read: oauth_tokens", "type": "main", "index": 0}]
    # Insert oauth chain
    conns["BQ Read: oauth_tokens"] = {"main": [[{"node": "HTTP: Refresh Microsoft Token", "type": "main", "index": 0}]]}
    conns["HTTP: Refresh Microsoft Token"] = {"main": [[{"node": "Code: Parse Refresh Response", "type": "main", "index": 0}]]}
    conns["Code: Parse Refresh Response"] = {"main": [[{"node": "BQ Write: MERGE oauth_tokens", "type": "main", "index": 0}]]}
    conns["BQ Write: MERGE oauth_tokens"] = {"main": [[{"node": "Set: OAuth Context", "type": "main", "index": 0}]]}
    conns["Set: OAuth Context"] = {"main": [[{"node": "If: OAuth refresh failed", "type": "main", "index": 0}]]}
    # If: true(failed) -> Throw, false(ok) -> existing Set: Date Range
    conns["If: OAuth refresh failed"] = {
        "main": [
            [{"node": "Throw: OAuth refresh dead", "type": "main", "index": 0}],  # true branch
            [{"node": set_node_name, "type": "main", "index": 0}],  # false branch
        ]
    }

    # Patch existing Submit/Poll nodes
    for n in nodes:
        update_existing_node(n)

    # Remove existing oauth nodes if re-running
    nodes = [n for n in nodes if n["name"] not in {
        "BQ Read: oauth_tokens", "HTTP: Refresh Microsoft Token", "Code: Parse Refresh Response",
        "BQ Write: MERGE oauth_tokens", "Set: OAuth Context", "If: OAuth refresh failed",
        "Throw: OAuth refresh dead"
    }]
    # Insert new oauth nodes
    nodes.extend(oauth_nodes)
    wf["nodes"] = nodes

    wf_path.write_text(json.dumps(wf, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Patched {wf_path.name}: {len(oauth_nodes)} oauth nodes inserted, Submit/Poll auth replaced")


if __name__ == "__main__":
    main()
