-- ============================================================================
-- mig_324_commercial_asset_rights_and_recovery_engine.sql
-- STRATELOQ — Commercial Asset Rights & Recovery Engine (permanent, canonical).
--
-- Principle: DISCOVERY DOES NOT IMPLY PUBLICATION RIGHTS. Discovery imagery
-- (marketplace/competitor/social) is research-only and is NEVER a publishable
-- asset nor a Gemini-eligible reference. Commercial publication requires a
-- verified legitimate asset path (customer-owned / supplier-authorized /
-- explicitly licensed), or an authorized reference from which the EXISTING
-- Gemini v5 pipeline may generate an identity-validated commercial image.
--
-- Reuses/extends existing contracts; does NOT rebuild Gemini, Product Asset
-- Lock, supplier identity, or storefront resolution. Backward compatible: every
-- existing key of fn_product_commercial_asset_readiness is preserved.
--
-- NOTE: fn_product_commercial_asset_readiness is superseded by mig_326/mig_327
-- (NULL-safety coalesces). This file records its first form for history.
-- ============================================================================

-- 1) Canonical asset-specific rights classification (pure mapping) -------------
CREATE OR REPLACE FUNCTION public.fn_asset_rights_class(
  p_rights_state text, p_source_provider text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO ''
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

-- 2) Per-product rights summary (read-only over stored provenance) -------------
CREATE OR REPLACE FUNCTION public.fn_product_commercial_rights(p_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_build_object(
    'checked_at', now(),
    'rights_scope', 'GLOBAL',
    'by_class', coalesce(jsonb_object_agg(cls, cnt) FILTER (WHERE cls IS NOT NULL), '{}'::jsonb),
    'publishable_present', coalesce(bool_or(cls IN ('CUSTOMER_OWNED','SUPPLIER_AUTHORIZED','EXPLICITLY_LICENSED')), false),
    'ai_reference_present', coalesce(bool_or(cls IN ('CUSTOMER_OWNED','SUPPLIER_AUTHORIZED','EXPLICITLY_LICENSED','AUTHORIZED_FOR_AI_REFERENCE')), false),
    'research_only_count', coalesce(sum(cnt) FILTER (WHERE cls = 'RESEARCH_REFERENCE_ONLY'), 0),
    'unknown_count', coalesce(sum(cnt) FILTER (WHERE cls = 'RIGHTS_UNKNOWN'), 0),
    'total', coalesce(sum(cnt), 0)
  ) INTO v
  FROM (
    SELECT public.fn_asset_rights_class(rights_state, source_provider, coalesce(provenance,'{}'::jsonb)) AS cls,
           count(*) AS cnt
    FROM public.product_image_assets
    WHERE product_id = p_product_id AND coalesce(is_fixture,false) = false
    GROUP BY 1
  ) z;
  RETURN coalesce(v, jsonb_build_object('checked_at', now(), 'rights_scope','GLOBAL',
    'by_class','{}'::jsonb, 'publishable_present', false, 'ai_reference_present', false,
    'research_only_count', 0, 'unknown_count', 0, 'total', 0));
END; $function$;

-- 3) Concise readiness badge for Product Opportunity / search cards ------------
CREATE OR REPLACE FUNCTION public.fn_product_commercial_readiness_badge(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE r jsonb; st text;
BEGIN
  r := public.fn_product_commercial_asset_readiness(p_product_id, p_market);
  st := coalesce(r->>'commercial_asset_readiness', 'UNKNOWN');
  RETURN jsonb_build_object(
    'readiness', st,
    'testability', coalesce(r->>'commercial_testability','NOT_CURRENTLY_LAUNCHABLE'),
    'label', CASE st
      WHEN 'READY' THEN 'Commercial assets: Ready'
      WHEN 'GENERATABLE_FROM_AUTHORIZED_REFERENCE' THEN 'Commercial assets: Generatable from authorized supplier reference'
      WHEN 'SUPPLIER_ASSET_REQUIRED' THEN 'Commercial assets: Supplier asset required'
      WHEN 'CUSTOMER_ASSET_REQUIRED' THEN 'Commercial assets: Customer image required'
      WHEN 'UNAVAILABLE' THEN 'Commercial assets: Unavailable'
      ELSE 'Commercial assets: Rights verification pending' END,
    'reason', coalesce(r->>'basis','Rights verification pending.'));
END; $function$;

-- 4) Extended canonical readiness (see mig_327 for the final NULL-safe body). ---
-- The authoritative body lives in mig_327_readiness_resolve_available_coalesce.sql.
