-- mart.ec_review_enriched: Judge.me レビュー 1 行 = 1 row の wide fact (PII ゼロ)
--
-- ソース: raw.ec_judgeme_reviews_latest (dedup view)
-- 設計:
--   - reviewer_email を SHA256 hash 化 → mart の他テーブルと同じ customer_email_hash で JOIN 可能
--   - ip_address / raw_payload は除外 (PII 保護 & マート軽量化)
--   - mart.ec_customer_profile と LEFT JOIN して顧客 lifetime context 追加
--   - 「初回購入 → レビュー投稿」のリードタイム算出
--
-- 用途:
--   - 商品別評価分析 / 低評価レビュー監視 / リピーター vs 新規の評価傾向
--   - dashboards (Looker Studio 等) の元ソース
--   - 注文/CV mart との JOIN による attribution × review クロス分析

CREATE OR REPLACE TABLE `campwill-ec.mart.ec_review_enriched`
PARTITION BY DATE(review_created_at)
CLUSTER BY product_handle, rating
AS
WITH reviews AS (
  SELECT
    review_id,
    product_external_id,
    product_handle,
    product_title,
    rating,
    title,
    body,
    reviewer_name,
    LOWER(reviewer_email)                            AS reviewer_email_lower,
    verified,
    verified_buyer,
    curated,
    published,
    hidden,
    featured,
    source,
    has_published_pictures,
    has_published_videos,
    -- pictures_url_count を派生 (JSON 配列の要素数)
    ARRAY_LENGTH(JSON_EXTRACT_ARRAY(IFNULL(pictures_json, '[]'))) AS pictures_url_count,
    review_created_at,
    review_updated_at
  FROM `campwill-ec.raw.ec_judgeme_reviews_latest`
)
SELECT
  r.review_id,
  r.product_external_id,
  r.product_handle,
  r.product_title,
  r.rating,
  r.title,
  r.body,
  r.reviewer_name,
  TO_HEX(SHA256(r.reviewer_email_lower)) AS customer_email_hash,
  r.verified,
  r.verified_buyer,
  r.curated,
  r.published,
  r.hidden,
  r.featured,
  r.source,
  r.has_published_pictures,
  r.has_published_videos,
  r.pictures_url_count,
  r.review_created_at,
  r.review_updated_at,
  -- ===== 顧客 lifetime context (mart.ec_customer_profile JOIN) =====
  cp.customer_id,
  cp.first_order_date,
  cp.last_order_date,
  cp.total_orders                                                   AS customer_total_orders,
  CAST(cp.total_revenue AS INT64)                                   AS customer_total_revenue,
  cp.is_repeater                                                    AS customer_is_repeater,
  cp.is_dormant                                                     AS customer_is_dormant,
  cp.first_channel                                                  AS customer_first_channel,
  cp.favorite_sku                                                   AS customer_favorite_sku,
  -- 初回購入 → レビュー投稿のリードタイム
  IF(cp.first_order_date IS NOT NULL,
     DATE_DIFF(DATE(r.review_created_at), cp.first_order_date, DAY),
     NULL)                                                          AS days_first_order_to_review,
  -- 顧客識別がある = Shopify との突合 OK
  (cp.customer_email_hash IS NOT NULL)                              AS has_customer_match,
  CURRENT_TIMESTAMP() AS generated_at
FROM reviews r
LEFT JOIN `campwill-ec.mart.ec_customer_profile` cp
  ON cp.customer_email_hash = TO_HEX(SHA256(r.reviewer_email_lower))
WHERE r.reviewer_email_lower IS NOT NULL;
