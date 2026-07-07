"""
施策自動記録システムの 6 workflow を n8n cloud に一括 create + activate するワンショット。

cmd_create との違い:
- credential ID 込みでそのまま POST (placeholder ではなく実 ID 埋め込み済前提)
- create 後に自動 activate
- workflow-ids.json を更新

実行: python scripts/n8n-sync/create-initiative-workflows.py
"""
import json
import sys
from pathlib import Path

# 同じディレクトリの sync.py を import
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync import (
    get_config,
    api_create_workflow,
    api_activate,
    api_list_workflows,
    strip_readonly,
    fixup_resource_locators,
    load_mapping,
    save_mapping,
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOWS_DIR = REPO_ROOT / "n8n" / "workflows"

# 依存順 (Slack → Backlog → Initiative-extract)
WORKFLOWS = [
    ("slack-messages-daily",          "slack-messages-daily.json"),
    ("backlog-issues-daily",          "backlog-issues-daily.json"),
    ("initiative-extract-daily",      "initiative-extract-daily.json"),
    ("re-slack-messages-daily",       "re-slack-messages-daily.json"),
    ("re-backlog-issues-daily",       "re-backlog-issues-daily.json"),
    ("re-initiative-extract-daily",   "re-initiative-extract-daily.json"),
]


def main():
    get_config()  # .env 検証
    mapping = load_mapping()

    # 既存 workflow との重複チェック
    remote_names = {wf["name"] for wf in api_list_workflows()}

    results = []
    for name, filename in WORKFLOWS:
        path = WORKFLOWS_DIR / filename
        if not path.exists():
            print(f"  [skip] file not found: {filename}")
            continue

        with path.open(encoding="utf-8") as f:
            local = json.load(f)

        wf_name = local.get("name", name)

        if name in mapping:
            print(f"  [skip] {name}: already in workflow-ids.json (id={mapping[name]})")
            continue

        if wf_name in remote_names:
            print(f"  [skip] {name}: workflow '{wf_name}' already exists on n8n cloud")
            continue

        body = strip_readonly(local)
        body.setdefault("settings", {"executionOrder": "v1"})
        for node in body.get("nodes", []):
            fixup_resource_locators(node)

        print(f"→ Creating: {name}")
        try:
            resp = api_create_workflow(body)
        except Exception as e:
            print(f"  [ERROR-create] {name}: {e}")
            results.append((name, "create-fail"))
            continue

        new_id = resp.get("id") or (resp.get("activeVersion") or {}).get("workflowId")
        if not new_id:
            print(f"  [ERROR-create] {name}: no id in response: {str(resp)[:300]}")
            results.append((name, "no-id"))
            continue

        print(f"  ✓ created id={new_id}")
        mapping[name] = new_id
        save_mapping(mapping)

        results.append((name, new_id))

    print("\n=== Activation (manual trigger 推奨のため activate は skip) ===")
    print("各 workflow を n8n UI で動作確認後に手動 activate するか、")
    print("'python scripts/n8n-sync/sync.py activate <name>' で個別 activate してください。")
    print("\nSummary:")
    for name, result in results:
        print(f"  {name:35s} {result}")


if __name__ == "__main__":
    main()
