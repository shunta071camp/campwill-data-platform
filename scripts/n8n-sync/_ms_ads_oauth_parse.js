// Microsoft OAuth /token endpoint レスポンス処理
// - 成功: refresh_token 更新 + history append
// - 失敗: last_error 更新 + history error append
// 出力: { status, access_token?, expires_at?, merge_sql }
//       後続の BQ ノードが merge_sql を実行 / Set OAuth Context が access_token を Set / If OAuth refresh failed が status を判定

const ROTATED_BY = "__ROTATED_BY__"; // 'microsoft-ads-incremental' or 'microsoft-ads-backfill' に置換

const httpResp = $input.first().json;
const statusCode = httpResp.statusCode;
const body = httpResp.body || {};

const oldToken = $('BQ Read: oauth_tokens').first().json.refresh_token;
const clientId = $('BQ Read: oauth_tokens').first().json.client_id || '';
const nowIso = new Date().toISOString();

const esc = (s) => String(s == null ? '' : s).replace(/\\/g, '\\\\').replace(/'/g, "\\'");

if (statusCode >= 200 && statusCode < 300 && body.access_token && body.refresh_token) {
  const newRt = body.refresh_token;
  const accessToken = body.access_token;
  const expiresIn = Number(body.expires_in || 3600);
  const expiresAtIso = new Date(Date.now() + expiresIn * 1000).toISOString();
  const scope = body.scope || 'https://ads.microsoft.com/msads.manage offline_access';

  const sql = `
BEGIN
  MERGE \`campwill-ec.raw.oauth_tokens\` T
  USING (SELECT 'microsoft_ads' AS provider) S
  ON T.provider = S.provider
  WHEN MATCHED THEN UPDATE SET
    refresh_token = '${esc(newRt)}',
    access_token  = '${esc(accessToken)}',
    expires_at    = TIMESTAMP('${expiresAtIso}'),
    scope         = '${esc(scope)}',
    rotated_at    = TIMESTAMP('${nowIso}'),
    rotated_by    = '${esc(ROTATED_BY)}',
    refresh_count = T.refresh_count + 1,
    last_error    = NULL,
    last_error_at = NULL,
    updated_at    = TIMESTAMP('${nowIso}')
  WHEN NOT MATCHED THEN INSERT
    (provider, refresh_token, access_token, expires_at, scope, rotated_at, rotated_by, refresh_count, client_id, updated_at)
  VALUES
    ('microsoft_ads', '${esc(newRt)}', '${esc(accessToken)}', TIMESTAMP('${expiresAtIso}'), '${esc(scope)}',
     TIMESTAMP('${nowIso}'), '${esc(ROTATED_BY)}', 1, '${esc(clientId)}', TIMESTAMP('${nowIso}'));

  INSERT INTO \`campwill-ec.raw.oauth_tokens_history\`
    (provider, refresh_token, access_token, expires_at, scope, rotated_at, rotated_by, status, error_message, http_code, recorded_at)
  VALUES
    ('microsoft_ads', '${esc(newRt)}', '${esc(accessToken)}', TIMESTAMP('${expiresAtIso}'),
     '${esc(scope)}', TIMESTAMP('${nowIso}'), '${esc(ROTATED_BY)}', 'success', NULL, ${statusCode}, CURRENT_TIMESTAMP());
END;
`;

  return [{
    json: {
      status: 'success',
      access_token: accessToken,
      expires_at: expiresAtIso,
      merge_sql: sql,
    }
  }];
}

// ── 失敗ケース ──
const errMessage = (body.error_description || body.error || JSON.stringify(body)).toString().substring(0, 1000);
const errCode = body.error || 'unknown';
const fullErr = errCode + ': ' + errMessage;

const sqlErr = `
BEGIN
  UPDATE \`campwill-ec.raw.oauth_tokens\`
  SET last_error = '${esc(fullErr)}',
      last_error_at = TIMESTAMP('${nowIso}'),
      updated_at = TIMESTAMP('${nowIso}')
  WHERE provider = 'microsoft_ads';

  INSERT INTO \`campwill-ec.raw.oauth_tokens_history\`
    (provider, refresh_token, rotated_at, rotated_by, status, error_message, http_code, recorded_at)
  VALUES
    ('microsoft_ads', '${esc(oldToken)}', TIMESTAMP('${nowIso}'), '${esc(ROTATED_BY)}',
     'error', '${esc(fullErr)}', ${statusCode || 'NULL'}, CURRENT_TIMESTAMP());
END;
`;

return [{
  json: {
    status: 'error',
    error_code: errCode,
    error_message: errMessage,
    http_code: statusCode,
    merge_sql: sqlErr,
  }
}];
