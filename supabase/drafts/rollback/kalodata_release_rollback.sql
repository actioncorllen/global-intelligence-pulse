-- ============================================================================
-- KALODATA RELEASE — DURABLE ROLLBACK (captured 2026-11-12 from production
-- nxaunmyihhjixxxljcqt; committed to the repo so it is not scratchpad-only).
--
-- The release (M1 20261111000000 + M2 20261111010000, applied under fresh
-- versions > frontier) is ADDITIVE => rollback needs NO database restore.
--
-- APPLIED PRODUCTION MIGRATIONS (6; recorded in supabase_migrations.schema_migrations, 2026-11-13):
--   20261113061729 kalodata_detail_video_caller            (M1 — product detail + video intel + caller wiring)
--   20261113063155 kalodata_selftest_fixture_fixes          (self-test fixture only: approval_key + commerce cols)
--   20261113063724 kalodata_caller_selftest_transient_price (self-test fixture only: txn-local price)
--   20261113064209 kalodata_caller_selftest_authuid_claim   (self-test fixture only: request.jwt.claim.sub)
--   20261113064907 kalodata_product_images                  (M2 — multi-image cache + req-10 reclass + signing)
--   20261113065224 kalodata_product_images_selftest_fixtures(self-test fixture only: txn-local public.users)
-- The 4 correction migrations ONLY CREATE OR REPLACE the two/one self-test utility functions
-- (fn_kalodata_caller_lifecycle_selftest, fn_kalodata_e2e_mock_lifecycle_selftest,
--  fn_kalodata_product_images_selftest) — all of which are DROP-ed by section 2 below, so this rollback
-- already reverts them. They change no deployed caller/credit/image logic; no extra rollback step is needed.
--
-- SAFETY (founder directive):
--   * Preserves all unrelated records, user accounts, tenant data, credits,
--     provider settings and working functionality.
--   * Dropping the 4 additive cache columns removes ONLY cache metadata; it does
--     NOT delete any of the ~257 existing product_image_assets rows.
--   * kalodata_video_research is a NEW table (video METADATA only, no media) — it
--     holds no pre-existing business data.
--   * Do NOT delete the pulse-research-reference bucket if it still holds cached
--     objects; empty it first or leave it (private, harmless).
--   * Review and run in a transaction; confirm each object before executing.
-- ============================================================================
BEGIN;

-- 1) REVERT the ONE replaced pre-existing function to its captured pre-deploy
--    body (current prod maps KALODATA -> ELSE -> RIGHTS_UNKNOWN = fail-closed).
CREATE OR REPLACE FUNCTION public.fn_asset_rights_class(p_rights_state text, p_source_provider text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN upper(coalesce(p_rights_state,'')) = 'RESTRICTED' THEN 'RESTRICTED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('CUSTOMER_OWNED','CUSTOMER_UPLOAD')
         AND coalesce(p_provenance->>'rights_confirmed','false') = 'true' THEN 'CUSTOMER_OWNED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('CUSTOMER_OWNED','CUSTOMER_UPLOAD') THEN 'RIGHTS_UNKNOWN'
    WHEN upper(coalesce(p_rights_state,'')) IN ('EXPLICITLY_LICENSED','LICENSED','COMMERCIAL_LICENSE') THEN 'EXPLICITLY_LICENSED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('SUPPLIER_PROVIDED','SUPPLIER_AUTHORIZED')
         AND coalesce(p_provenance->>'ai_reference_only','false') = 'true' THEN 'AUTHORIZED_FOR_AI_REFERENCE'
    WHEN upper(coalesce(p_rights_state,'')) IN ('SUPPLIER_PROVIDED','SUPPLIER_AUTHORIZED') THEN 'SUPPLIER_AUTHORIZED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('MARKETPLACE_PUBLIC_LISTING','RESEARCH_REFERENCE_ONLY','COMPETITOR','SOCIAL')
      OR upper(coalesce(p_source_provider,'')) IN ('EBAY_BROWSE','EBAY','AMAZON','META','FACEBOOK','INSTAGRAM','TIKTOK','GOOGLE','COMPETITOR','COMPETITOR_STORE')
      THEN 'RESEARCH_REFERENCE_ONLY'
    ELSE 'RIGHTS_UNKNOWN'
  END;
$function$;

-- 2) DROP the NEW functions (each name is unique in prod => no-arg DROP is valid).
--    If the migration overloaded any name, add the arg signature before running.
DROP FUNCTION IF EXISTS public.fn_kalodata_detail_request;
DROP FUNCTION IF EXISTS public.fn_kalodata_video_rank_request;
DROP FUNCTION IF EXISTS public.fn_kalodata_video_detail_request;
DROP FUNCTION IF EXISTS public.fn_kalodata_video_url_request;          -- blocked stub
DROP FUNCTION IF EXISTS public.fn_kalodata_images_request;
DROP FUNCTION IF EXISTS public.fn_kalodata_op_reserve;
DROP FUNCTION IF EXISTS public.fn_kalodata_op_fire;
DROP FUNCTION IF EXISTS public.fn_kalodata_op_complete_from_edge;
DROP FUNCTION IF EXISTS public.fn_kalodata_run_product_detail;
DROP FUNCTION IF EXISTS public.fn_kalodata_run_video_rank;
DROP FUNCTION IF EXISTS public.fn_kalodata_run_video_detail;
DROP FUNCTION IF EXISTS public.fn_kalodata_run_product_images;
DROP FUNCTION IF EXISTS public.fn_kalodata_ingest_video_rank;
DROP FUNCTION IF EXISTS public.fn_persist_kalodata_video_detail;
DROP FUNCTION IF EXISTS public.fn_persist_kalodata_research_image;
DROP FUNCTION IF EXISTS public.fn_kalodata_product_images_cached;
DROP FUNCTION IF EXISTS public.fn_kalodata_research_image_exists;
DROP FUNCTION IF EXISTS public.fn_product_image_signed_ref;
DROP FUNCTION IF EXISTS public.fn_kalodata_product_detail_selftest();
DROP FUNCTION IF EXISTS public.fn_kalodata_video_selftest();
DROP FUNCTION IF EXISTS public.fn_kalodata_caller_lifecycle_selftest();
DROP FUNCTION IF EXISTS public.fn_kalodata_e2e_mock_lifecycle_selftest();
DROP FUNCTION IF EXISTS public.fn_kalodata_product_images_selftest();
-- NOTE: fn_persist_kalodata_product_detail is PRE-EXISTING (reused) — do NOT drop.

-- 3) DROP new table + additive index/constraint/columns on product_image_assets.
DROP TABLE IF EXISTS public.kalodata_video_research;   -- new; video metadata only
DROP INDEX IF EXISTS public.product_image_assets_content_hash_uniq;
DROP INDEX IF EXISTS public.product_image_assets_storage_ref_uniq;
ALTER TABLE public.product_image_assets DROP CONSTRAINT IF EXISTS product_image_assets_cache_state_chk;
ALTER TABLE public.product_image_assets
  DROP COLUMN IF EXISTS storage_ref,
  DROP COLUMN IF EXISTS source_url_expires_at,
  DROP COLUMN IF EXISTS cache_state,
  DROP COLUMN IF EXISTS content_hash;
-- (existing product_image_assets rows and their source_url are preserved.)

COMMIT;

-- 4) NON-SQL rollback (outside the transaction):
--    - Delete the 5 new edge slugs: kalodata-product-detail, kalodata-video-rank,
--      kalodata-video-detail, kalodata-product-images, kalodata-research-image-url.
--    - pulse-research-reference bucket: delete ONLY if empty; otherwise leave it.
--    - Lovable: republish the prior frontend revision.
-- ============================================================================
