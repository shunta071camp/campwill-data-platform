#!/usr/bin/env python3
"""
n8n cloud workflow 同期スクリプト

ローカル `n8n/workflows/*.json` を master として n8n cloud に push する。
本番 → ローカルの pull / diff / activate / deactivate もサポート。

使い方:
    python sync.py init                       # 本番から workflow 一覧取得 → mapping 自動生成
    python sync.py list                       # 本番 workflow 一覧表示
    python sync.py push <name>                # 1 件 push
    python sync.py push --all                 # 全件 push
    python sync.py push <name> --no-keep-active  # active 自動維持を無効化
    python sync.py pull <name>                # 1 件 pull (本番 → ローカル)
    python sync.py diff <name>                # 差分表示
    python sync.py activate <name>            # Activate
    python sync.py deactivate <name>          # Deactivate

事前準備:
    .env (リポジトリルート) に以下を設定:
        N8N_BASE_URL=https://<instance>.app.n8n.cloud
        N8N_API_KEY=<your-api-key>
"""

import argparse
import difflib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Windows cp932 環境でも UTF-8 出力できるように
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# ──────────────────────────────────────────────────────────────────────
# 設定
# ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
WORKFLOWS_DIR = REPO_ROOT / "n8n" / "workflows"
MAPPING_FILE = SCRIPT_DIR / "workflow-ids.json"
ENV_FILE = REPO_ROOT / ".env"

# n8n の workflow 更新時に拒否される read-only field
# PUT 時にこれらを含むと「request/body must NOT have additional properties」エラー
READONLY_FIELDS = {"id", "createdAt", "updatedAt", "versionId", "active", "tags", "meta", "pinData", "triggerCount", "shared", "isArchived", "homeProject", "activeVersion", "activeVersionId", "description", "staticData", "versionCounter"}

# n8n Public API が settings オブジェクト内で許可するフィールドのみ
# それ以外は「settings must NOT have additional properties」エラー
SETTINGS_ALLOWED = {
    "saveExecutionProgress",
    "saveManualExecutions",
    "saveDataErrorExecution",
    "saveDataSuccessExecution",
    "executionTimeout",
    "errorWorkflow",
    "timezone",
    "executionOrder",
}

# ──────────────────────────────────────────────────────────────────────
# .env loader (依存ゼロ)
# ──────────────────────────────────────────────────────────────────────

def load_env() -> dict:
    """`.env` を読み取る（python-dotenv に依存せず stdlib のみ）"""
    env = {}
    if not ENV_FILE.exists():
        return env
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        env[key.strip()] = val.strip().strip('"').strip("'")
    return env

def get_config():
    env = load_env()
    base_url = env.get("N8N_BASE_URL") or os.environ.get("N8N_BASE_URL")
    api_key = env.get("N8N_API_KEY") or os.environ.get("N8N_API_KEY")
    if not base_url or not api_key:
        sys.exit(
            "ERROR: N8N_BASE_URL と N8N_API_KEY を .env に設定してください。\n"
            f"  .env: {ENV_FILE}\n"
            "  例: N8N_BASE_URL=https://kubell.app.n8n.cloud\n"
            "      N8N_API_KEY=eyJhbGciOi..."
        )
    return base_url.rstrip("/"), api_key

# ──────────────────────────────────────────────────────────────────────
# n8n REST API client (stdlib のみ)
# ──────────────────────────────────────────────────────────────────────

def api_request(method: str, path: str, body: dict | None = None) -> dict:
    base_url, api_key = get_config()
    url = f"{base_url}/api/v1{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "X-N8N-API-KEY": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"ERROR: {method} {path} → HTTP {e.code}\n  {err_body}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: {method} {path} → {e.reason}")

def api_list_workflows() -> list[dict]:
    """全 workflow を取得（pagination 対応）"""
    items = []
    cursor = None
    while True:
        path = "/workflows?limit=250"
        if cursor:
            path += f"&cursor={urllib.parse.quote(cursor)}"
        resp = api_request("GET", path)
        items.extend(resp.get("data", []))
        cursor = resp.get("nextCursor")
        if not cursor:
            break
    return items

def api_get_workflow(wf_id: str) -> dict:
    return api_request("GET", f"/workflows/{wf_id}")

def api_update_workflow(wf_id: str, body: dict) -> dict:
    return api_request("PUT", f"/workflows/{wf_id}", body)

def api_create_workflow(body: dict) -> dict:
    return api_request("POST", "/workflows", body)

def api_activate(wf_id: str) -> dict:
    return api_request("POST", f"/workflows/{wf_id}/activate")

def api_deactivate(wf_id: str) -> dict:
    return api_request("POST", f"/workflows/{wf_id}/deactivate")

# ──────────────────────────────────────────────────────────────────────
# mapping (workflow-ids.json)
# ──────────────────────────────────────────────────────────────────────

def load_mapping() -> dict:
    if not MAPPING_FILE.exists():
        return {}
    return json.loads(MAPPING_FILE.read_text(encoding="utf-8"))

def save_mapping(mapping: dict):
    MAPPING_FILE.write_text(
        json.dumps(mapping, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

def resolve_workflow_id(name: str) -> str:
    mapping = load_mapping()
    if name not in mapping:
        sys.exit(
            f"ERROR: workflow '{name}' が workflow-ids.json にありません。\n"
            f"  python sync.py init で mapping を生成してください。\n"
            f"  または python sync.py list で本番の workflow ID を確認してください。"
        )
    return mapping[name]

# ──────────────────────────────────────────────────────────────────────
# workflow JSON 操作
# ──────────────────────────────────────────────────────────────────────

def load_local(name: str) -> dict:
    path = WORKFLOWS_DIR / f"{name}.json"
    if not path.exists():
        sys.exit(f"ERROR: ローカルファイルが見つかりません: {path}")
    return json.loads(path.read_text(encoding="utf-8"))

def save_local(name: str, data: dict):
    path = WORKFLOWS_DIR / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

def strip_readonly(wf: dict) -> dict:
    """PUT 時に拒否される read-only フィールドを削除 + settings をフィルタ"""
    cleaned = {k: v for k, v in wf.items() if k not in READONLY_FIELDS}
    # settings 内も API 許可フィールドのみに絞る
    if "settings" in cleaned and isinstance(cleaned["settings"], dict):
        cleaned["settings"] = {
            k: v for k, v in cleaned["settings"].items() if k in SETTINGS_ALLOWED
        }
    return cleaned

def fixup_resource_locators(obj):
    """__rl: true のリソースロケータに cachedResultName を補完。
    BigQuery などのノードで projectId/datasetId/tableId が validation でこけるため。
    """
    if isinstance(obj, dict):
        if obj.get("__rl") is True and obj.get("mode") == "list" and "value" in obj:
            obj.setdefault("cachedResultName", str(obj["value"]))
        for v in obj.values():
            fixup_resource_locators(v)
    elif isinstance(obj, list):
        for item in obj:
            fixup_resource_locators(item)

def unwrap_remote(remote: dict) -> dict:
    """n8n cloud の GET レスポンスから workflow 本体を取り出す。
    新しい n8n は `activeVersion` 配下に nodes/connections を入れるラッパー形式。
    settings は top-level に保持される。
    """
    if "activeVersion" in remote and isinstance(remote["activeVersion"], dict):
        av = remote["activeVersion"]
        merged = {
            "name": remote.get("name") or av.get("name"),
            "nodes": av.get("nodes", []),
            "connections": av.get("connections", {}),
            # settings は top-level 優先（activeVersion.settings は通常 None）
            "settings": remote.get("settings") or av.get("settings", {}),
        }
        for key in ("staticData", "pinData"):
            if key in av:
                merged[key] = av[key]
        return merged
    return remote

def slugify(name: str) -> str:
    """workflow name を ファイル名向けに変換"""
    return name.lower().replace(" ", "-").replace("_", "-").replace(":", "").replace("(", "").replace(")", "").replace(",", "")

# ──────────────────────────────────────────────────────────────────────
# コマンド
# ──────────────────────────────────────────────────────────────────────

def cmd_init(args):
    """本番から全 workflow を取得 → mapping 自動生成"""
    print("Fetching workflows from n8n cloud...")
    workflows = api_list_workflows()
    print(f"  Found {len(workflows)} workflows on n8n cloud.\n")

    mapping = load_mapping()
    local_files = {p.stem for p in WORKFLOWS_DIR.glob("*.json")}

    print(f"{'Local file':<40} {'n8n name':<45} {'ID'}")
    print("─" * 110)
    matched = 0
    for wf in workflows:
        wf_name = wf["name"]
        wf_id = wf["id"]
        # ローカルファイル名候補（n8n name の slug、または既存 mapping から逆引き）
        slug = slugify(wf_name)
        existing_local = next((k for k, v in mapping.items() if v == wf_id), None)

        local_match = None
        if existing_local and existing_local in local_files:
            local_match = existing_local
        elif slug in local_files:
            local_match = slug
        else:
            # 既存ローカルファイル名と部分一致
            for f in local_files:
                if slug.startswith(f) or f.startswith(slug.split("-")[0]):
                    local_match = f
                    break

        if local_match:
            mapping[local_match] = wf_id
            matched += 1
            print(f"{local_match:<40} {wf_name[:44]:<45} {wf_id}")
        else:
            print(f"{'(no match)':<40} {wf_name[:44]:<45} {wf_id}")

    save_mapping(mapping)
    print(f"\n{matched}/{len(workflows)} workflows matched. Mapping saved to {MAPPING_FILE.relative_to(REPO_ROOT)}")
    print("⚠️  '(no match)' と出た workflow はローカルにファイルがないか、ファイル名規則と一致していません。")
    print("   手動で workflow-ids.json を編集してください。")

def cmd_list(args):
    """本番 workflow 一覧表示"""
    workflows = api_list_workflows()
    mapping = load_mapping()
    rev_map = {v: k for k, v in mapping.items()}

    print(f"{'Active':<8} {'ID':<25} {'Name':<55} Local file")
    print("─" * 130)
    for wf in sorted(workflows, key=lambda w: w["name"]):
        active = "✓" if wf.get("active") else " "
        local = rev_map.get(wf["id"], "—")
        print(f"  {active:<6} {wf['id']:<25} {wf['name'][:54]:<55} {local}")

def cmd_push(args):
    """ローカル → 本番"""
    targets = []
    if args.all:
        mapping = load_mapping()
        targets = list(mapping.keys())
    else:
        if not args.name:
            sys.exit("ERROR: workflow name または --all を指定してください")
        targets = [args.name]

    keep_active = args.keep_active

    for name in targets:
        wf_id = resolve_workflow_id(name)
        local = load_local(name)
        print(f"\n→ {name} (id: {wf_id})")

        # 現在の active 状態を取得
        was_active = False
        if keep_active:
            current = api_get_workflow(wf_id)
            was_active = current.get("active", False) or (current.get("activeVersion") or {}).get("active", False)

        body = strip_readonly(local)
        # n8n PUT は settings オブジェクトが必須
        body.setdefault("settings", {"executionOrder": "v1"})
        # resource locator (BigQuery などの projectId/datasetId/tableId) に cachedResultName を補完
        for node in body.get("nodes", []):
            fixup_resource_locators(node)

        api_update_workflow(wf_id, body)
        print(f"  ✓ Updated workflow")

        if keep_active and was_active:
            api_activate(wf_id)
            print(f"  ✓ Re-activated (was active before push)")

def cmd_create(args):
    """ローカル JSON を本番に新規作成 + workflow-ids.json に追加"""
    if not args.name:
        sys.exit("ERROR: workflow name を指定してください")
    mapping = load_mapping()
    if args.name in mapping:
        sys.exit(f"ERROR: '{args.name}' は既に mapping にあります (id: {mapping[args.name]})。push を使ってください。")

    local = load_local(args.name)
    body = strip_readonly(local)
    body.setdefault("settings", {"executionOrder": "v1"})
    for node in body.get("nodes", []):
        fixup_resource_locators(node)
        # placeholder の credential 参照は新規作成時にエラーになるので削除（UI で後紐付け）
        if "credentials" in node:
            del node["credentials"]

    print(f"→ Creating new workflow: {args.name}")
    resp = api_create_workflow(body)
    new_id = resp.get("id") or (resp.get("activeVersion") or {}).get("workflowId")
    if not new_id:
        sys.exit(f"ERROR: workflow ID 取得失敗。レスポンス: {json.dumps(resp, ensure_ascii=False)[:300]}")

    print(f"  ✓ Created workflow id: {new_id}")
    mapping[args.name] = new_id
    save_mapping(mapping)
    print(f"  ✓ Added to workflow-ids.json")
    print(f"\n⚠️  各ノードに credential 紐付けが必要な場合は n8n UI で手動設定してください。")
    print(f"   その後 'python sync.py pull {args.name}' で本番状態を取り込み直し。")

def cmd_pull(args):
    """本番 → ローカル（復旧用）"""
    if not args.name:
        sys.exit("ERROR: workflow name を指定してください")
    wf_id = resolve_workflow_id(args.name)
    wf = api_get_workflow(wf_id)
    # unwrap → strip_readonly → fixup で push できる形に正規化
    cleaned = strip_readonly(unwrap_remote(wf))
    for node in cleaned.get("nodes", []):
        fixup_resource_locators(node)
    save_local(args.name, cleaned)
    print(f"✓ Pulled '{args.name}' → {WORKFLOWS_DIR.relative_to(REPO_ROOT) / (args.name + '.json')}")

def cmd_diff(args):
    """ローカル vs 本番の差分（unified diff）"""
    if not args.name:
        sys.exit("ERROR: workflow name を指定してください")
    wf_id = resolve_workflow_id(args.name)

    local = load_local(args.name)
    remote = unwrap_remote(api_get_workflow(wf_id))

    # 比較前に両側に cachedResultName 補完を適用（push 時に自動付与されるが、本番が常に保持するとは限らない）
    for node in local.get("nodes", []):
        fixup_resource_locators(node)
    for node in remote.get("nodes", []):
        fixup_resource_locators(node)

    local_norm = json.dumps(strip_readonly(local), indent=2, ensure_ascii=False, sort_keys=True).splitlines()
    remote_norm = json.dumps(strip_readonly(remote), indent=2, ensure_ascii=False, sort_keys=True).splitlines()

    diff = list(difflib.unified_diff(
        remote_norm, local_norm,
        fromfile=f"remote: {args.name}",
        tofile=f"local: {args.name}",
        lineterm="",
        n=3,
    ))
    if not diff:
        print(f"✓ No diff: '{args.name}' は本番と一致しています")
    else:
        print("\n".join(diff))

def cmd_activate(args):
    if not args.name:
        sys.exit("ERROR: workflow name を指定してください")
    wf_id = resolve_workflow_id(args.name)
    api_activate(wf_id)
    print(f"✓ Activated: {args.name}")

def cmd_deactivate(args):
    if not args.name:
        sys.exit("ERROR: workflow name を指定してください")
    wf_id = resolve_workflow_id(args.name)
    api_deactivate(wf_id)
    print(f"✓ Deactivated: {args.name}")

def cmd_executions(args):
    """直近の実行を一覧 or 詳細表示。"""
    wf_id = resolve_workflow_id(args.name) if args.name else None
    qs = {"limit": str(args.limit)}
    if wf_id:
        qs["workflowId"] = wf_id
    if args.status:
        qs["status"] = args.status
    url = f"/executions?{urllib.parse.urlencode(qs)}"
    data = api_request("GET", url)
    items = data.get("data", [])
    if not items:
        print("(no executions)")
        return
    for e in items:
        eid = e.get("id")
        status = e.get("status")
        stopped = e.get("stoppedAt", "")
        mode = e.get("mode", "")
        wf_name = (e.get("workflowData") or {}).get("name") or e.get("workflowId")
        print(f"  {eid:>6} | {status:8} | {mode:10} | {stopped} | {wf_name}")

    if args.detail and items:
        target_id = items[0]["id"]
        print(f"\n--- detail: execution {target_id} ---")
        det = api_request("GET", f"/executions/{target_id}?includeData=true")
        run = (det.get("data") or {}).get("resultData", {}).get("runData", {})
        any_err = False
        for node, runs in run.items():
            for r in runs:
                err = r.get("error")
                if err:
                    any_err = True
                    print(f"\n[ERROR] node: {node}")
                    print(f"  message: {err.get('message')}")
                    print(f"  description: {err.get('description')}")
                    print(f"  httpCode: {err.get('httpCode')}")
                    msgs = err.get("messages") or []
                    for m in msgs:
                        print(f"  raw: {m[:1000]}")
        if not any_err:
            print("(execution succeeded — no error data)")

# ──────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="n8n cloud workflow 同期スクリプト")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="本番 → mapping 自動生成")
    sub.add_parser("list", help="本番 workflow 一覧")

    p_create = sub.add_parser("create", help="ローカル → 本番に新規作成")
    p_create.add_argument("name", help="workflow ファイル名 (例: yahoo-ads)")

    p_push = sub.add_parser("push", help="ローカル → 本番")
    p_push.add_argument("name", nargs="?", help="workflow ファイル名 (例: klaviyo-profiles)")
    p_push.add_argument("--all", action="store_true", help="全 workflow を push")
    p_push.add_argument("--no-keep-active", dest="keep_active", action="store_false", default=True,
                       help="active 状態の自動維持を無効化")

    p_pull = sub.add_parser("pull", help="本番 → ローカル")
    p_pull.add_argument("name", help="workflow ファイル名")

    p_diff = sub.add_parser("diff", help="ローカル vs 本番 差分")
    p_diff.add_argument("name", help="workflow ファイル名")

    p_act = sub.add_parser("activate", help="Activate")
    p_act.add_argument("name", help="workflow ファイル名")

    p_deact = sub.add_parser("deactivate", help="Deactivate")
    p_deact.add_argument("name", help="workflow ファイル名")

    p_exec = sub.add_parser("executions", help="実行履歴 + 直近エラー詳細")
    p_exec.add_argument("name", nargs="?", help="workflow ファイル名 (省略可)")
    p_exec.add_argument("--limit", type=int, default=5, help="取得件数 (default: 5)")
    p_exec.add_argument("--status", choices=["success","error","waiting","running"], help="status filter")
    p_exec.add_argument("--detail", action="store_true", help="最新実行のエラー詳細を表示")

    args = parser.parse_args()
    {
        "init": cmd_init,
        "list": cmd_list,
        "create": cmd_create,
        "push": cmd_push,
        "pull": cmd_pull,
        "diff": cmd_diff,
        "activate": cmd_activate,
        "deactivate": cmd_deactivate,
        "executions": cmd_executions,
    }[args.cmd](args)

if __name__ == "__main__":
    main()
