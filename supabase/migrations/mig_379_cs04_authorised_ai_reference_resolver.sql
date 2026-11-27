-- mig_379 — CS.04 ORIGINAL AI CREATIVE ASSET LANE: authorised generative-reference resolver.
-- PURPOSE: give the Gemini pipeline (commercial-image-generate edge) a reference resolver that selects an
-- ACTUAL authorised customer-owned / first-party / explicitly-licensed / AI-authorised product image, and that
-- NEVER substitutes a bare supplier (CJ), marketplace or research image. This is the SQL half of the smallest
-- CS.04 fix; the edge half (edge calls this instead of the supplier storefront) is the committed, undeployed
-- supabase/functions/commercial-image-generate/index.ts.
--
-- RIGHTS BASIS (BE239 / BE323 / BE324 / BE326, founder FAIL-CLOSED policy): image-analysis, research-display,
-- source-availability, ownership-assertion and Product Asset Lock identity validation are INDEPENDENT of
-- generative-AI-input rights. A CJ supplier photograph is NOT an authorised generative reference merely because
-- supplier product-DATA analysis is permitted (CJ reuse_creative_cleared / commercial_redistribution_cleared =
-- FALSE). So the resolver's candidate set is EXACTLY the per-image decomposition of the deployed BE326 readiness
-- gate (fn_product_commercial_asset_readiness) AI-eligibility predicate:
--   rank 1  CUSTOMER_OWNED upload with provenance.rights_confirmed=true
--   rank 2  FIRST_PARTY_OWNED
--   rank 3  EXPLICITLY_LICENSED / LICENSED / OWNED
--   rank 4  AUTHORIZED_FOR_AI_REFERENCE  (provenance.ai_reference_only=true)
--   rank 5  SUPPLIER_PROVIDED image whose EXACT supplier item carries an unrevoked, unexpired per-image
--           permission_scope.ai_input grant (commerce_supplier_image_rights)
-- Anything else (bare SUPPLIER_PROVIDED/SUPPLIER_AUTHORIZED, MARKETPLACE_PUBLIC_LISTING, research/discovery,
-- RIGHTS_UNKNOWN) is NEVER a candidate. No rights record is read as more than it is; nothing is fabricated.
--
-- NOT APPLIED TO PRODUCTION in this change (founder control CS.04: no production deployment). Committed for a
-- separate, authorised apply + edge deployment, then a single controlled generation pilot. The resolver is
-- additive and unwired until the companion edge is deployed; it changes no existing function or rights record.

-- ============================================================================
-- Authorised generative-reference resolver (service_role / edge; explicit tenant).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_authorised_ai_reference(
  p_tenant uuid,
  p_product_id uuid,
  p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_owner uuid;
  r record;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL THEN
    RETURN jsonb_build_object('status','INVALID_ARGS'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  -- Tenant isolation (defence in depth; the edge already checked ownership).
  IF v_owner <> p_tenant THEN
    RETURN jsonb_build_object('status','CROSS_TENANT_REJECTED'); END IF;

  -- Highest-ranked AUTHORISED generative reference among THIS product's exact imagery.
  -- The ranking mirrors the deployed BE326 readiness gate at the per-IMAGE level (see header). A bare supplier /
  -- marketplace / research / rights-unknown image yields NULL rank and is excluded.
  SELECT z.* INTO r FROM (
    SELECT
      pia.id, pia.rights_state, pia.source_provider, pia.source_entity_id,
      pia.image_url, pia.source_url,
      -- Authoritative private storage object reference ("bucket/path"). Customer uploads store it in
      -- provenance.storage_ref (the storage_ref COLUMN is left null by fn_product_image_import_register),
      -- so coalesce surfaces it reliably. The edge signs a FRESH short-lived URL from this at execution time
      -- rather than relying on any stored long-lived signed URL.
      coalesce(pia.storage_ref, pia.provenance->>'storage_ref') AS storage_ref,
      pia.is_primary, pia.observed_at,
      CASE
        WHEN upper(coalesce(pia.rights_state,''))='CUSTOMER_OWNED'
             AND pia.source_provider='CUSTOMER_UPLOAD'
             AND coalesce(pia.provenance->>'rights_confirmed','false')='true' THEN 1
        WHEN upper(coalesce(pia.rights_state,''))='FIRST_PARTY_OWNED' THEN 2
        WHEN upper(coalesce(pia.rights_state,'')) IN ('EXPLICITLY_LICENSED','LICENSED','OWNED') THEN 3
        WHEN coalesce(pia.provenance->>'ai_reference_only','false')='true' THEN 4
        WHEN upper(coalesce(pia.rights_state,''))='SUPPLIER_PROVIDED'
             AND pia.source_entity_id IS NOT NULL
             AND EXISTS (
               SELECT 1 FROM public.commerce_supplier_image_rights cr
               WHERE cr.revoked_at IS NULL
                 AND coalesce((cr.permission_scope->>'ai_input')::boolean,false)=true
                 AND coalesce((cr.permission_scope->>'expires_at')::timestamptz,'infinity'::timestamptz) > now()
                 AND cr.supplier_product_id = pia.source_entity_id) THEN 5
        ELSE NULL
      END AS rnk
    FROM public.product_image_assets pia
    WHERE pia.product_id = p_product_id
      AND coalesce(pia.is_fixture,false)=false
      AND coalesce(upper(pia.availability),'AVAILABLE') <> 'UNAVAILABLE'
  ) z
  WHERE z.rnk IS NOT NULL
  ORDER BY z.rnk ASC, z.is_primary DESC NULLS LAST, z.observed_at DESC NULLS LAST
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN jsonb_build_object(
      'status','NO_AUTHORISED_REFERENCE',
      'product_id', p_product_id,
      'reason','No customer-owned, first-party, explicitly-licensed, AI-authorised or per-image-AI-permitted product image is available. A bare supplier / marketplace / research image is never an authorised generative reference.',
      'contract','pulse_authorised_ai_reference_v1');
  END IF;

  RETURN jsonb_build_object(
    'status','AUTHORISED_REFERENCE_AVAILABLE',
    'product_id', p_product_id,
    'reference', jsonb_build_object(
      'asset_id', r.id,
      'rights_state', r.rights_state,
      'origin_rank', r.rnk,
      'origin_basis', CASE r.rnk
        WHEN 1 THEN 'CUSTOMER_OWNED_UPLOAD'
        WHEN 2 THEN 'FIRST_PARTY_OWNED'
        WHEN 3 THEN 'OWNED_OR_LICENSED'
        WHEN 4 THEN 'AUTHORISED_AI_REFERENCE'
        WHEN 5 THEN 'PER_IMAGE_AI_INPUT_EVIDENCE' END,
      'image_url', r.image_url,
      'source_url', r.source_url,
      'storage_ref', r.storage_ref,
      'source_provider', r.source_provider),
    'notes', jsonb_build_array(
      'Reference selection mirrors the fail-closed readiness gate (BE324/BE326) at the per-image level.',
      'A bare supplier (SUPPLIER_PROVIDED/SUPPLIER_AUTHORIZED), marketplace or research image is never returned as a generative reference.',
      'storage_ref is the authoritative private object ref (coalesced from the column or provenance.storage_ref); the edge signs a FRESH short-lived URL from it at execution, never relying on a stored long-lived signed URL. image_url/source_url are used only when no private object exists.'),
    'contract','pulse_authorised_ai_reference_v1');
END; $function$;

-- ============================================================================
-- Selftest (rolled-back synthetic fixtures; nothing persists). Runs at apply time.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_authorised_ai_reference_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb:='[]'::jsonb; v_pass int; v_fail int; v_r jsonb;
  v_founder uuid:='7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid:='e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_other uuid:='11111111-1111-4111-8111-111111111111';
  v_mkt text:='GB';
BEGIN
  -- Real-data: e453 currently has only supplier + marketplace imagery (no authorised reference). Expect none.
  v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
  v_checks := v_checks || jsonb_build_object('check','REAL_SUPPLIER_MARKETPLACE_ONLY_NO_REF',
    'ok', v_r->>'status'='NO_AUTHORISED_REFERENCE', 'detail', v_r->>'status');

  -- Tenant isolation.
  v_r := public.fn_resolve_authorised_ai_reference(v_other, v_prod, v_mkt);
  v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED',
    'ok', v_r->>'status'='CROSS_TENANT_REJECTED', 'detail', v_r->>'status');

  -- Missing product.
  v_r := public.fn_resolve_authorised_ai_reference(v_founder, '00000000-0000-4000-8000-000000000000', v_mkt);
  v_checks := v_checks || jsonb_build_object('check','PRODUCT_NOT_FOUND',
    'ok', v_r->>'status'='PRODUCT_NOT_FOUND', 'detail', v_r->>'status');

  -- NOTE: product_image_assets has UNIQUE(product_id, content_hash) and UNIQUE(product_id, image_url).
  -- Every synthetic row therefore uses a DISTINCT content_hash + image_url (all prefixed 'CS04STQ' /
  -- 'https://cs04st.example/...'), and cleanup is by the 'CS04STQ%' prefix so no sub-check collides and the
  -- rank assertions are never silently skipped by a swallowed unique-violation.
  BEGIN
    -- rank 1: customer-owned upload, shaped exactly as fn_product_image_import_register stores it
    -- (image_url = a stored signed URL; source_url + provenance.storage_ref = the private object ref;
    -- storage_ref COLUMN null). Also add a bare supplier image: owned must still win, AND the resolver
    -- must surface the private object ref (so the edge can sign a fresh short-lived URL).
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES
      (v_founder,v_prod,v_mkt,'https://sb.example/storage/v1/object/sign/pulse-product-imports/o.png?token=x',
         'CUSTOMER_UPLOAD','pulse-product-imports/'||v_founder::text||'/'||v_prod::text||'/o.png',
         NULL,'CUSTOMER_OWNED','AVAILABLE',true,now(),
         jsonb_build_object('rights_confirmed','true','bucket','pulse-product-imports',
           'storage_ref','pulse-product-imports/'||v_founder::text||'/'||v_prod::text||'/o.png'),
         false,'CS04STQOWN'),
      (v_founder,v_prod,v_mkt,'https://cs04st.example/sup1.jpg','CJ_SUPPLIER','https://cs04st.example/sup1.jpg',
         'CS04_BARE_SUP','SUPPLIER_PROVIDED','AVAILABLE',false,now(),'{}'::jsonb,false,'CS04STQSUP1');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','RANK1_CUSTOMER_OWNED_WINS_AND_SURFACES_PRIVATE_REF',
      'ok', v_r->>'status'='AUTHORISED_REFERENCE_AVAILABLE'
         AND (v_r->'reference'->>'origin_rank')='1'
         AND (v_r->'reference'->>'origin_basis')='CUSTOMER_OWNED_UPLOAD'
         AND (v_r->'reference'->>'storage_ref') LIKE 'pulse-product-imports/%',
      'detail', v_r->'reference');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';

    -- rank 2: first-party owned.
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/fp.png','FIRST_PARTY',NULL,
         'FIRST_PARTY_OWNED','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQFP');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','RANK2_FIRST_PARTY',
      'ok', (v_r->'reference'->>'origin_rank')='2' AND (v_r->'reference'->>'origin_basis')='FIRST_PARTY_OWNED',
      'detail', v_r->'reference'->>'origin_basis');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';

    -- rank 3: explicitly licensed.
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/lic.png','LICENSOR',NULL,
         'EXPLICITLY_LICENSED','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQLIC');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','RANK3_LICENSED',
      'ok', (v_r->'reference'->>'origin_rank')='3' AND (v_r->'reference'->>'origin_basis')='OWNED_OR_LICENSED',
      'detail', v_r->'reference'->>'origin_basis');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';

    -- rank 4: explicit AI-reference authorisation on an otherwise-supplier image.
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/air.jpg','CJ_SUPPLIER','https://cs04st.example/air.jpg',
         'CS04_AIR','SUPPLIER_PROVIDED','AVAILABLE',true,now(),'{"ai_reference_only":"true"}'::jsonb,false,'CS04STQAIR');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','RANK4_AI_REFERENCE_FLAG',
      'ok', (v_r->'reference'->>'origin_rank')='4' AND (v_r->'reference'->>'origin_basis')='AUTHORISED_AI_REFERENCE',
      'detail', v_r->'reference'->>'origin_basis');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';

    -- rank 5: supplier image WITH unrevoked, unexpired per-image ai_input evidence (distinct synthetic supplier id).
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES ('cs04x','CS04_SUP_OK','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true}'::jsonb, now(), true);
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/ok.jpg','CJ_SUPPLIER','https://cs04st.example/ok.jpg',
         'CS04_SUP_OK','SUPPLIER_PROVIDED','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQOK');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','RANK5_SUPPLIER_WITH_AI_EVIDENCE',
      'ok', (v_r->'reference'->>'origin_rank')='5' AND (v_r->'reference'->>'origin_basis')='PER_IMAGE_AI_INPUT_EVIDENCE',
      'detail', v_r->'reference'->>'origin_basis');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';
    DELETE FROM public.commerce_supplier_image_rights WHERE source='cs04x';

    -- rank 5 excluded when evidence is REVOKED.
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,revoked_at,is_synthetic)
      VALUES ('cs04x','CS04_SUP_REV','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true}'::jsonb, now(), true);
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/rev.jpg','CJ_SUPPLIER','https://cs04st.example/rev.jpg',
         'CS04_SUP_REV','SUPPLIER_PROVIDED','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQREV');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','REVOKED_AI_EVIDENCE_EXCLUDED',
      'ok', v_r->>'status'='NO_AUTHORISED_REFERENCE', 'detail', v_r->>'status');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';
    DELETE FROM public.commerce_supplier_image_rights WHERE source='cs04x';

    -- rank 5 excluded when evidence is EXPIRED.
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES ('cs04x','CS04_SUP_EXP','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true,"expires_at":"2000-01-01T00:00:00Z"}'::jsonb, now(), true);
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/exp.jpg','CJ_SUPPLIER','https://cs04st.example/exp.jpg',
         'CS04_SUP_EXP','SUPPLIER_PROVIDED','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQEXP');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','EXPIRED_AI_EVIDENCE_EXCLUDED',
      'ok', v_r->>'status'='NO_AUTHORISED_REFERENCE', 'detail', v_r->>'status');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';
    DELETE FROM public.commerce_supplier_image_rights WHERE source='cs04x';

    -- marketplace image alone → never a reference.
    INSERT INTO public.product_image_assets(tenant_id,product_id,market,image_url,source_provider,source_url,
        source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture,content_hash)
      VALUES (v_founder,v_prod,v_mkt,'https://cs04st.example/mkt.jpg','EBAY_BROWSE','https://cs04st.example/mkt.jpg',
         NULL,'MARKETPLACE_PUBLIC_LISTING','AVAILABLE',true,now(),'{}'::jsonb,false,'CS04STQMKT');
    v_r := public.fn_resolve_authorised_ai_reference(v_founder, v_prod, v_mkt);
    v_checks := v_checks || jsonb_build_object('check','MARKETPLACE_NEVER_REFERENCE',
      'ok', v_r->>'status'='NO_AUTHORISED_REFERENCE', 'detail', v_r->>'status');
    DELETE FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%';

    RAISE EXCEPTION 'cs04_resolver_selftest_rollback';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  v_checks := v_checks || jsonb_build_object('check','NO_SYNTHETIC_PERSISTED',
    'ok', NOT EXISTS(SELECT 1 FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%')
      AND NOT EXISTS(SELECT 1 FROM public.commerce_supplier_image_rights WHERE source='cs04x'),
    'detail', (SELECT count(*) FROM public.product_image_assets WHERE content_hash LIKE 'CS04STQ%'));

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass,v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok',v_fail=0,'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_authorised_ai_reference_selftest_v1','generated_at',now());
END; $function$;
