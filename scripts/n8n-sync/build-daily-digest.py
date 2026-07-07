#!/usr/bin/env python3
"""
CAMPWILL デイリーダイジェスト workflow (daily-digest.json) を生成するワンショット。

JS Code ノードを手で JSON エスケープすると壊れやすいため、ここで dict を組み立てて
json.dump する。再生成したいときは:

    python scripts/n8n-sync/build-daily-digest.py

出力: n8n/workflows/daily-digest.json

仕様: CAMPWILL_デイリーダイジェスト_実装仕様書.md
- 毎平日 AM8:00 JST に Backlog / Google Calendar / Gmail / Slack を集約
- Claude API で「今日やるべきこと」を生成し個人専用 Slack channel に投稿
- フロー型 (BigQuery 蓄積なし)
"""
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OUT = REPO_ROOT / "n8n" / "workflows" / "daily-digest.json"

# ── 既存 credential (n8n cloud に登録済み、ID は workflow JSON 内で参照) ──
CRED_BACKLOG   = {"id": "SQjyvr3N3Fwux7Rp", "name": "Backlog API"}          # httpQueryAuth
CRED_SLACK_RD  = {"id": "e6HmFJZvXj23JwQF", "name": "Slack Bot (read)"}      # httpHeaderAuth
CRED_ANTHROPIC = {"id": "p7FCjP7Pvtv9IZ1F", "name": "Anthropic API"}         # httpHeaderAuth
CRED_SLACK_POST = {"id": "QkIO5PiBLGcuUZOd", "name": "Slack OAuth (n8n.cloud)"}  # slackOAuth2Api (chat:write)

# ── 要設定 placeholder (デプロイ前に埋める) ──
CRED_GOOGLE = {"id": "REPLACE_GOOGLE_OAUTH_CRED_ID", "name": "Google OAuth2 (readonly)"}  # oAuth2Api
DIGEST_CHANNEL_ID = "REPLACE_DIGEST_CHANNEL_ID"

# ── 個人特定用 (自分の Backlog / Slack 登録メール) ──
MY_EMAIL = "s_miyazaki@campwill.me"

ANTHROPIC_MODEL = "claude-sonnet-4-6"
ERROR_WORKFLOW_ID = "V72FkZBDign2AB1y"


def http_query(name, node_id, url, x, query=None, extra_opts=None, always=True):
    """Backlog 用 httpQueryAuth HTTP Request"""
    params = {
        "url": url,
        "authentication": "genericCredentialType",
        "genericAuthType": "httpQueryAuth",
    }
    if query is not None:
        params["sendQuery"] = True
        params["queryParameters"] = {"parameters": query}
    opts = {"response": {"response": {"responseFormat": "json", "neverError": True}}, "timeout": 60000}
    if extra_opts:
        opts.update(extra_opts)
    params["options"] = opts
    return {
        "parameters": params,
        "id": node_id, "name": name,
        "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
        "position": [x, -256], "alwaysOutputData": always,
        "credentials": {"httpQueryAuth": CRED_BACKLOG},
    }


def http_header(name, node_id, url, x, cred, query=None, extra_opts=None, always=True):
    """Slack 用 httpHeaderAuth HTTP Request"""
    params = {
        "url": url,
        "authentication": "genericCredentialType",
        "genericAuthType": "httpHeaderAuth",
    }
    if query is not None:
        params["sendQuery"] = True
        params["queryParameters"] = {"parameters": query}
    opts = {"response": {"response": {"responseFormat": "json", "neverError": True}}, "timeout": 60000}
    if extra_opts:
        opts.update(extra_opts)
    params["options"] = opts
    return {
        "parameters": params,
        "id": node_id, "name": name,
        "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
        "position": [x, -256], "alwaysOutputData": always,
        "credentials": {"httpHeaderAuth": cred},
    }


def http_oauth(name, node_id, url, x, query=None, extra_opts=None, always=True):
    """Google 用 generic OAuth2 HTTP Request"""
    params = {
        "url": url,
        "authentication": "genericCredentialType",
        "genericAuthType": "oAuth2",
    }
    if query is not None:
        params["sendQuery"] = True
        params["queryParameters"] = {"parameters": query}
    opts = {"response": {"response": {"responseFormat": "json", "neverError": True}}, "timeout": 60000}
    if extra_opts:
        opts.update(extra_opts)
    params["options"] = opts
    return {
        "parameters": params,
        "id": node_id, "name": name,
        "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
        "position": [x, -256], "alwaysOutputData": always,
        "credentials": {"oAuth2Api": CRED_GOOGLE},
    }


def code(name, node_id, x, js, y=-256):
    return {
        "parameters": {"jsCode": js},
        "id": node_id, "name": name,
        "type": "n8n-nodes-base.code", "typeVersion": 2,
        "position": [x, y],
    }


# ──────────────────────────────────────────────────────────────────────
# JS Code 本体
# ──────────────────────────────────────────────────────────────────────

JS_PICK_BACKLOG_ID = f"""// Backlog ユーザー一覧から自分 (MY_EMAIL) の user id を解決
const MY_EMAIL = '{MY_EMAIL}';
const users = $input.all().map(i => i.json).filter(u => u && u.id != null);
let me = users.find(u => (u.mailAddress || '').toLowerCase() === MY_EMAIL.toLowerCase());
if (!me) me = users.find(u => (u.mailAddress || '').toLowerCase().startsWith(MY_EMAIL.split('@')[0].toLowerCase()));
if (!me) throw new Error('Backlog user not found for ' + MY_EMAIL + ' (users=' + users.length + ')');
return [{{ json: {{ backlog_user_id: me.id, backlog_user_name: me.name }} }}];
"""

JS_COLLECT_BACKLOG = """// 自分担当・期限が近い課題を整形 (期限昇順)
const issues = $('Backlog: my due-soon issues').all().map(i => i.json).filter(x => x && x.id != null);
const today = $now.setZone('Asia/Tokyo').toFormat('yyyy-LL-dd');
const rows = issues.map(i => ({
  key:      i.issueKey || null,
  title:    i.summary || null,
  status:   i.status ? i.status.name : null,
  priority: i.priority ? i.priority.name : null,
  due_date: i.dueDate ? String(i.dueDate).substring(0, 10) : null,
  overdue:  i.dueDate ? (String(i.dueDate).substring(0, 10) < today) : false,
  url:      i.issueKey ? ('https://campwill.backlog.com/view/' + i.issueKey) : null,
}));
rows.sort((a, b) => {
  if (!a.due_date && !b.due_date) return 0;
  if (!a.due_date) return 1;
  if (!b.due_date) return -1;
  return a.due_date < b.due_date ? -1 : 1;
});
return [{ json: { backlog: rows } }];
"""

JS_SPLIT_CHANNELS = """// bot が join 済みの channel を 1 channel = 1 item に展開
// 自分の Slack member id を lookup から取得 (取れなければ filter は空振り = 安全)
const resp = $('Slack: list channels (bot joined)').first().json;
const lookup = $('Slack: lookup my member id').first().json;
const myId = (lookup && lookup.ok && lookup.user) ? lookup.user.id : 'REPLACE_WITH_SLACK_MEMBER_ID';
const oldest = String(Math.floor((Date.now() / 1000) - 24 * 3600)); // 直近 24h
const chans = (resp && resp.ok && Array.isArray(resp.channels)) ? resp.channels : [];
if (chans.length === 0) {
  return [{ json: { channel_id: null, channel_name: null, my_member_id: myId, oldest, _empty: true } }];
}
return chans.map(c => ({ json: { channel_id: c.id, channel_name: c.name, my_member_id: myId, oldest } }));
"""

JS_COLLECT_SLACK = """// 各 channel history から「自分宛メンション (<@myId>)」のみ抽出
const chanItems = $('Code: split channels').all().map(i => i.json);
const hist = $input.all().map(i => i.json);
const myId = chanItems[0] ? chanItems[0].my_member_id : null;
const mention = myId ? ('<@' + myId + '>') : '@@@no-match@@@';
const out = [];
for (let i = 0; i < hist.length; i++) {
  const r = hist[i];
  const ch = chanItems[i] || {};
  if (!r || !r.ok || !Array.isArray(r.messages)) continue;
  for (const m of r.messages) {
    if (!m.text) continue;
    if (m.text.indexOf(mention) === -1) continue;
    out.push({
      channel: ch.channel_name || null,
      user: m.user || m.bot_id || null,
      text: m.text.substring(0, 1000),
      ts: m.ts,
    });
  }
}
return [{ json: { slack: out } }];
"""

JS_COLLECT_CALENDAR = """// Google Calendar events list レスポンス (1 item, object) を整形
const resp = $('Google Calendar: today events').first().json;
const items = (resp && Array.isArray(resp.items)) ? resp.items : [];
const out = items
  .filter(e => e.status !== 'cancelled')
  .map(e => {
    const start = e.start ? (e.start.dateTime || e.start.date) : null;
    const end = e.end ? (e.end.dateTime || e.end.date) : null;
    return {
      summary: e.summary || '(無題)',
      start, end,
      all_day: !!(e.start && e.start.date && !e.start.dateTime),
      location: e.location || null,
      hangout: e.hangoutLink || null,
    };
  });
return [{ json: { calendar: out } }];
"""

JS_SPLIT_GMAIL = """// Gmail list レスポンスから message id を 1 id = 1 item に展開
const resp = $('Gmail: list unread').first().json;
const msgs = (resp && Array.isArray(resp.messages)) ? resp.messages : [];
if (msgs.length === 0) return [{ json: { id: '', _empty: true } }];
return msgs.slice(0, 20).map(m => ({ json: { id: m.id } }));
"""

JS_COLLECT_GMAIL = """// 各 message の metadata + snippet を整形
const gets = $('Gmail: get message').all().map(i => i.json);
const out = [];
for (const g of gets) {
  if (!g || !g.id || g.error) continue;
  const headers = (g.payload && Array.isArray(g.payload.headers)) ? g.payload.headers : [];
  const h = (n) => {
    const x = headers.find(z => z.name && z.name.toLowerCase() === n);
    return x ? x.value : null;
  };
  out.push({
    from: h('from'),
    subject: h('subject'),
    date: h('date'),
    snippet: (g.snippet || '').substring(0, 400),
  });
}
return [{ json: { gmail: out } }];
"""

JS_BUILD_PROMPT = """// 4 ソースを 1 つの prompt にまとめて Claude へ
const backlog  = ($('Code: collect Backlog').first().json.backlog) || [];
const slack    = ($('Code: collect Slack mentions').first().json.slack) || [];
const calendar = ($('Code: collect Calendar').first().json.calendar) || [];
const gmail    = ($('Code: collect Gmail').first().json.gmail) || [];

const dt = $now.setZone('Asia/Tokyo');
const dateStr = dt.toFormat('M/d');
const jpWeek = { 1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土', 7: '日' }[Number(dt.weekday)];

const system = [
  'あなたは CAMPWILL の個人秘書 AI です。',
  '以下の情報から「今日やるべきこと」を整理し、Slack 投稿用メッセージを作成してください。',
  '',
  '# 出力ルール',
  '1. 以下のセクション構成でまとめる (該当データが無いセクションは省略可):',
  '   :sunny: *おはようございます。今日やるべきこと（' + dateStr + ' ' + jpWeek + '）*',
  '   *【今日の予定】* カレンダーの予定を開始時刻順に',
  '   *【締切が近いタスク】* Backlog を期限順に（:red_circle: 今日まで/超過 :large_yellow_circle: 明日以降）',
  '   *【要対応メール】* Gmail（要返信・確認のみ、要約付き。情報共有のみは省略）',
  '   *【Slack で自分宛の未対応】* メンション',
  '   *【今日の重点】* 予定とタスクの兼ね合いから、今日の動き方を 1-2 文で助言',
  '2. 各項目にはリンクがあれば <URL|ラベル> 形式で添える',
  '3. 緊急度の高いものを上に',
  '4. メールは「要返信」のものだけ載せる（情報共有のみは省略）',
  '5. 簡潔に。ダラダラ書かない',
  '6. 「今日の重点」は予定の合間にどのタスクを差し込むべきか現実的な提案をする',
  '',
  '# 記法',
  'Slack の mrkdwn で出力する: *太字*、行頭「・」で箇条書き、<URL|ラベル> でリンク。',
  'Markdown の見出し(#)やテーブルは使わない。前置き・後置き・コードブロックは不要、本文のみ。',
].join('\\n');

const user = [
  '今日は ' + dateStr + '（' + jpWeek + '）です。以下の情報から「今日やるべきこと」を整理してください。',
  '',
  '--- Googleカレンダー（今日の予定）---',
  JSON.stringify(calendar, null, 2),
  '',
  '--- Backlog（自分担当・期限が近い課題）---',
  JSON.stringify(backlog, null, 2),
  '',
  '--- Gmail（未読・要対応メール）---',
  JSON.stringify(gmail, null, 2),
  '',
  '--- Slack（自分宛メンション）---',
  JSON.stringify(slack, null, 2),
].join('\\n');

return [{ json: { system, user, has_data: (backlog.length + slack.length + calendar.length + gmail.length) > 0 } }];
"""

JS_EXTRACT = """// Claude レスポンスから本文テキストを取り出す
const resp = $input.first().json;
let text = '';
if (resp && Array.isArray(resp.content)) text = resp.content.map(c => c.text || '').join('');
text = (text || '').trim();
if (!text) text = ':warning: デイリーダイジェストの生成に失敗しました（Claude 応答が空でした）。';
return [{ json: { text } }];
"""

ANTHROPIC_BODY = (
    "={{ JSON.stringify({ model: '" + ANTHROPIC_MODEL + "', max_tokens: 2000, temperature: 0.3, "
    "system: $json.system, messages: [{ role: 'user', content: $json.user }] }) }}"
)


def build():
    nodes = []
    x = 240
    step = 224

    nodes.append({
        "parameters": {"rule": {"interval": [{"field": "cronExpression", "expression": "0 8 * * 1-5"}]}},
        "id": "schedule-trigger", "name": "Schedule: 8:00 AM JST (Mon-Fri)",
        "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.1, "position": [x, -256],
    })

    x += step
    nodes.append(http_query(
        "Backlog: list users", "http-backlog-users",
        "https://campwill.backlog.com/api/v2/users", x))

    x += step
    nodes.append(code("Code: pick my Backlog id", "code-pick-backlog-id", x, JS_PICK_BACKLOG_ID))

    x += step
    nodes.append(http_query(
        "Backlog: my due-soon issues", "http-backlog-issues",
        "https://campwill.backlog.com/api/v2/issues", x,
        query=[
            {"name": "assigneeId[]", "value": "={{ $json.backlog_user_id }}"},
            {"name": "statusId[]", "value": "1"},
            {"name": "statusId[]", "value": "2"},
            {"name": "dueDateUntil", "value": "={{ $now.setZone('Asia/Tokyo').plus({ days: 3 }).toFormat('yyyy-LL-dd') }}"},
            {"name": "sort", "value": "dueDate"},
            {"name": "order", "value": "asc"},
            {"name": "count", "value": "50"},
        ]))

    x += step
    nodes.append(code("Code: collect Backlog", "code-collect-backlog", x, JS_COLLECT_BACKLOG))

    x += step
    nodes.append(http_header(
        "Slack: list channels (bot joined)", "http-slack-channels",
        "https://slack.com/api/users.conversations", x, CRED_SLACK_RD,
        query=[
            {"name": "types", "value": "public_channel,private_channel"},
            {"name": "exclude_archived", "value": "true"},
            {"name": "limit", "value": "200"},
        ]))

    x += step
    nodes.append(http_header(
        "Slack: lookup my member id", "http-slack-lookup",
        "https://slack.com/api/users.lookupByEmail", x, CRED_SLACK_RD,
        query=[{"name": "email", "value": MY_EMAIL}]))

    x += step
    nodes.append(code("Code: split channels", "code-split-channels", x, JS_SPLIT_CHANNELS))

    x += step
    nodes.append(http_header(
        "Slack: conversations.history per channel", "http-slack-history",
        "https://slack.com/api/conversations.history", x, CRED_SLACK_RD,
        query=[
            {"name": "channel", "value": "={{ $json.channel_id }}"},
            {"name": "oldest", "value": "={{ $json.oldest }}"},
            {"name": "limit", "value": "100"},
        ],
        extra_opts={"batching": {"batch": {"batchSize": 1, "batchInterval": 1200}}}))

    x += step
    nodes.append(code("Code: collect Slack mentions", "code-collect-slack", x, JS_COLLECT_SLACK))

    x += step
    nodes.append(http_oauth(
        "Google Calendar: today events", "http-gcal",
        "https://www.googleapis.com/calendar/v3/calendars/primary/events", x,
        query=[
            {"name": "timeMin", "value": "={{ $now.setZone('Asia/Tokyo').startOf('day').toISO() }}"},
            {"name": "timeMax", "value": "={{ $now.setZone('Asia/Tokyo').endOf('day').toISO() }}"},
            {"name": "singleEvents", "value": "true"},
            {"name": "orderBy", "value": "startTime"},
            {"name": "maxResults", "value": "50"},
        ]))

    x += step
    nodes.append(code("Code: collect Calendar", "code-collect-calendar", x, JS_COLLECT_CALENDAR))

    x += step
    nodes.append(http_oauth(
        "Gmail: list unread", "http-gmail-list",
        "https://gmail.googleapis.com/gmail/v1/users/me/messages", x,
        query=[
            {"name": "q", "value": "is:unread -category:promotions -category:social newer_than:2d"},
            {"name": "maxResults", "value": "20"},
        ]))

    x += step
    nodes.append(code("Code: split gmail ids", "code-split-gmail", x, JS_SPLIT_GMAIL))

    x += step
    nodes.append(http_oauth(
        "Gmail: get message", "http-gmail-get",
        "=https://gmail.googleapis.com/gmail/v1/users/me/messages/{{ $json.id }}", x,
        query=[
            {"name": "format", "value": "metadata"},
            {"name": "metadataHeaders", "value": "From"},
            {"name": "metadataHeaders", "value": "Subject"},
            {"name": "metadataHeaders", "value": "Date"},
        ],
        extra_opts={"batching": {"batch": {"batchSize": 5, "batchInterval": 300}}}))

    x += step
    nodes.append(code("Code: collect Gmail", "code-collect-gmail", x, JS_COLLECT_GMAIL))

    x += step
    nodes.append(code("Code: build digest prompt", "code-build-prompt", x, JS_BUILD_PROMPT))

    x += step
    nodes.append({
        "parameters": {
            "method": "POST",
            "url": "https://api.anthropic.com/v1/messages",
            "authentication": "genericCredentialType",
            "genericAuthType": "httpHeaderAuth",
            "sendHeaders": True,
            "headerParameters": {"parameters": [
                {"name": "anthropic-version", "value": "2023-06-01"},
                {"name": "Content-Type", "value": "application/json"},
            ]},
            "sendBody": True,
            "specifyBody": "json",
            "jsonBody": ANTHROPIC_BODY,
            "options": {"response": {"response": {"responseFormat": "json", "neverError": True}}, "timeout": 120000},
        },
        "id": "http-claude", "name": "Anthropic API: generate digest",
        "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
        "position": [x, -256], "credentials": {"httpHeaderAuth": CRED_ANTHROPIC},
    })

    x += step
    nodes.append(code("Code: extract digest text", "code-extract", x, JS_EXTRACT))

    x += step
    nodes.append({
        "parameters": {
            "authentication": "oAuth2",
            "select": "channel",
            "channelId": {"__rl": True, "value": DIGEST_CHANNEL_ID, "mode": "id", "cachedResultName": "daily-digest"},
            "text": "={{ $json.text }}",
            "otherOptions": {"mrkdwn": True, "link_names": True},
        },
        "id": "slack-post", "name": "Slack: post digest",
        "type": "n8n-nodes-base.slack", "typeVersion": 2.3,
        "position": [x, -256], "credentials": {"slackOAuth2Api": CRED_SLACK_POST},
    })

    # ── connections (linear spine) ──
    chain = [
        "Schedule: 8:00 AM JST (Mon-Fri)",
        "Backlog: list users",
        "Code: pick my Backlog id",
        "Backlog: my due-soon issues",
        "Code: collect Backlog",
        "Slack: list channels (bot joined)",
        "Slack: lookup my member id",
        "Code: split channels",
        "Slack: conversations.history per channel",
        "Code: collect Slack mentions",
        "Google Calendar: today events",
        "Code: collect Calendar",
        "Gmail: list unread",
        "Code: split gmail ids",
        "Gmail: get message",
        "Code: collect Gmail",
        "Code: build digest prompt",
        "Anthropic API: generate digest",
        "Code: extract digest text",
        "Slack: post digest",
    ]
    connections = {}
    for a, b in zip(chain, chain[1:]):
        connections[a] = {"main": [[{"node": b, "type": "main", "index": 0}]]}

    wf = {
        "name": "daily_digest",
        "nodes": nodes,
        "connections": connections,
        "settings": {
            "executionOrder": "v1",
            "timezone": "Asia/Tokyo",
            "errorWorkflow": ERROR_WORKFLOW_ID,
        },
    }
    return wf


def main():
    wf = build()
    OUT.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO_ROOT)}  ({len(wf['nodes'])} nodes)")


if __name__ == "__main__":
    main()
