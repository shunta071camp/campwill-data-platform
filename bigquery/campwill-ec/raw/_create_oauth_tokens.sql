-- OAuth refresh_token を BigQuery で永続化するためのテーブル
-- microsoft-ads / yahoo-ads 等の workflow の頭部で読み書きする
-- See: plans/ai-joyful-starlight.md (Microsoft Ads OAuth 恒久安定化)

-- 1) 現行 token (provider 単位 1 row)
CREATE TABLE IF NOT EXISTS `campwill-ec.raw.oauth_tokens` (
  provider        STRING    NOT NULL OPTIONS(description="プロバイダ識別子（例: microsoft_ads, yahoo_ads）"),
  refresh_token   STRING    NOT NULL OPTIONS(description="現行 refresh_token（rotate-on-use 後の最新値）"),
  access_token    STRING             OPTIONS(description="直近 refresh で得た access_token（cache 用）"),
  expires_at      TIMESTAMP          OPTIONS(description="access_token の expiry (UTC)"),
  scope           STRING             OPTIONS(description="現在認可されている scope 文字列"),
  rotated_at      TIMESTAMP NOT NULL OPTIONS(description="refresh_token を最後に書き換えた時刻"),
  rotated_by      STRING             OPTIONS(description="どのworkflowが書いたか"),
  refresh_count   INT64     NOT NULL OPTIONS(description="累計 refresh 成功回数"),
  last_error      STRING             OPTIONS(description="直近 refresh 失敗のエラー本文"),
  last_error_at   TIMESTAMP          OPTIONS(description="last_error を記録した時刻"),
  client_id       STRING             OPTIONS(description="Azure App の Application (client) ID"),
  updated_at      TIMESTAMP NOT NULL OPTIONS(description="この行を最後に書いた時刻")
)
CLUSTER BY provider;

-- 2) 履歴 (audit + 緊急復旧用)
CREATE TABLE IF NOT EXISTS `campwill-ec.raw.oauth_tokens_history` (
  provider       STRING    NOT NULL,
  refresh_token  STRING    NOT NULL,
  access_token   STRING,
  expires_at     TIMESTAMP,
  scope          STRING,
  rotated_at     TIMESTAMP NOT NULL,
  rotated_by     STRING,
  status         STRING    NOT NULL OPTIONS(description="success | error"),
  error_message  STRING,
  http_code      INT64,
  recorded_at    TIMESTAMP NOT NULL OPTIONS(description="行を記録した時刻")
)
PARTITION BY DATE(rotated_at)
CLUSTER BY provider, status;
