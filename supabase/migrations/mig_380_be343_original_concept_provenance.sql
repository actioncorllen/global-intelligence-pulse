-- mig_380 — BE343 ORIGINAL_CONCEPT provenance lane (prepared, NOT applied).
-- PURPOSE: the SQL half of the deployable AI Concept execution lane. Gives the
-- commercial-concept-generate edge (supabase/functions/commercial-concept-generate/)
-- a provenance store + register function for ORIGINAL_CONCEPT, text-only, original-
-- unbranded concept images that are NEVER a verified depiction of the real product.
--
-- SEPARATION (founder BE343 P1, lane requirement 8 + 12-13): concepts are stored in
-- their OWN table (concept_generated_assets), structurally distinct from
-- commerce_generated_assets. The table has NO commercial_asset_status, NO selected /
-- selected_at, and NO publish/clearance column, so a concept CANNOT be promoted to,
-- selected as, or exported as a commercial/product asset by construction. A concept
-- is registered with classification = AI_CONCEPT_NOT_PRODUCT_VERIFIED, rights_state =
-- ORIGINAL_CONCEPT, identity_validated = false, reference_asset = NONE (text-only).
-- fn_concept_asset_promotion_blocked always refuses (DB-level mirror of the lane's
-- rejectConceptPromotion), so even a direct DB caller cannot promote.
--
-- SPEND: this lane does not add a new budget mechanism. The edge reuses the existing
-- fn_provider_budget_open / fn_provider_budget_try_consume primitive under provider
-- key 'GEMINI_CONCEPT' (explicit, reserved, time-boxed spend authorisation). No paid
-- generation occurs unless a founder-opened budget is reserved.
--
-- IDENTITY-VERSION CONSISTENCY: the edge computes the deterministic identityVersion
-- server-side (FNV-1a over the authoritative identity-resolution fields, identical to
-- the client) and passes it in p_provenance.outputIdentityVersion; it is persisted on
-- the row so every concept output associates with the exact identity version used.
--
-- RLS mirrors commerce_generated_assets EXACTLY: no direct writes by anyone; owner can
-- SELECT only their own rows. All writes go through the SECURITY DEFINER register
-- function (service-role edge path). Additive and reversible: it creates a new table
-- and two new functions and changes no existing object.
--
-- NOT APPLIED TO PRODUCTION in this change (founder control BE343: no production
-- deployment / migration). Committed for a separate, authorised apply + edge deploy,
-- then a single controlled concept-generation pilot under an opened GEMINI_CONCEPT
-- budget. The apply-time selftest (fn_concept_provenance_selftest) is rolled back and
-- persists nothing.

-- ============================================================================
-- 1) ORIGINAL_CONCEPT provenance store (separate from commercial assets).
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.concept_generated_assets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  product_id          uuid NOT NULL,
  market              text,
  storage_bucket      text NOT NULL DEFAULT 'pulse-generated-media',
  storage_ref         text NOT NULL,
  generation_provider text NOT NULL DEFAULT 'GOOGLE_GEMINI',
  generation_model    text,
  generation_job_id   text,
  mime_type           text NOT NULL DEFAULT 'image/png',
  scene               text,
  aspect_ratio        text,
  -- Fixed classification/rights for this table. CHECK constraints make it structurally
  -- impossible to store anything but an unvalidated ORIGINAL_CONCEPT here.
  classification      text NOT NULL DEFAULT 'AI_CONCEPT_NOT_PRODUCT_VERIFIED'
                        CHECK (classification = 'AI_CONCEPT_NOT_PRODUCT_VERIFIED'),
  rights_state        text NOT NULL DEFAULT 'ORIGINAL_CONCEPT'
                        CHECK (rights_state = 'ORIGINAL_CONCEPT'),
  identity_version    text,
  identity_validated  boolean NOT NULL DEFAULT false
                        CHECK (identity_validated = false),
  provenance          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_concept_generated_assets_tenant_created
  ON public.concept_generated_assets (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_concept_generated_assets_product
  ON public.concept_generated_assets (product_id);

-- RLS: mirror commerce_generated_assets — nobody writes directly; owner selects own.
ALTER TABLE public.concept_generated_assets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ccga_no_direct_write ON public.concept_generated_assets;
DROP POLICY IF EXISTS ccga_tenant_select ON public.concept_generated_assets;
CREATE POLICY ccga_no_direct_write ON public.concept_generated_assets
  AS PERMISSIVE FOR ALL TO public USING (false) WITH CHECK (false);
CREATE POLICY ccga_tenant_select ON public.concept_generated_assets
  AS PERMISSIVE FOR SELECT TO public USING (tenant_id = auth.uid());

-- Grants: authenticated may read (RLS limits to own rows); service_role manages.
GRANT SELECT ON public.concept_generated_assets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.concept_generated_assets TO service_role;

-- ============================================================================
-- 2) Register an ORIGINAL_CONCEPT asset (owner-scoped; the ONLY write path).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_register_concept_asset(
  p_tenant uuid,
  p_product_id uuid,
  p_market text,
  p_storage_ref text,
  p_generation jsonb,
  p_provenance jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_id uuid; v_identity_version text;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL OR coalesce(btrim(p_storage_ref),'')='' THEN
    RETURN jsonb_build_object('ok',false,'error','missing_args'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  -- Rights-safety: an ORIGINAL_CONCEPT asset must carry NO reference asset and must NOT
  -- be identity-validated. Reject anything that is not shaped as an original concept.
  IF coalesce(p_provenance->>'rightsState','ORIGINAL_CONCEPT') <> 'ORIGINAL_CONCEPT'
     OR coalesce(p_provenance->>'classification','AI_CONCEPT_NOT_PRODUCT_VERIFIED')
        <> 'AI_CONCEPT_NOT_PRODUCT_VERIFIED'
     OR (p_provenance->'inputProvenance'->'referenceAsset') IS NOT NULL
        AND (p_provenance->'inputProvenance'->>'referenceAsset') IS NOT NULL
     OR coalesce((p_provenance->>'identityValidated')::boolean, false) <> false THEN
    RETURN jsonb_build_object('ok',false,'error','not_original_concept_provenance'); END IF;

  v_identity_version := coalesce(p_provenance->>'outputIdentityVersion', p_generation->>'identity_version');

  INSERT INTO public.concept_generated_assets(
    tenant_id, product_id, market, storage_bucket, storage_ref,
    generation_provider, generation_model, generation_job_id, mime_type, scene, aspect_ratio,
    classification, rights_state, identity_version, identity_validated, provenance)
  VALUES (
    p_tenant, p_product_id, nullif(upper(btrim(coalesce(p_market,''))),''),
    coalesce(p_generation->>'bucket','pulse-generated-media'), p_storage_ref,
    coalesce(p_generation->>'provider','GOOGLE_GEMINI'), p_generation->>'model',
    p_generation->>'job_id', coalesce(p_generation->>'mime','image/png'),
    p_generation->>'scene', p_generation->>'aspect_ratio',
    'AI_CONCEPT_NOT_PRODUCT_VERIFIED', 'ORIGINAL_CONCEPT', v_identity_version, false,
    jsonb_build_object(
      'input_provenance', coalesce(p_provenance->'inputProvenance',
         jsonb_build_object('rightsBasis','ORIGINAL_CONCEPT_TEXT_ONLY','referenceAsset', null)),
      'prompt', p_provenance->>'prompt',
      'provider', coalesce(p_generation->>'provider','GOOGLE_GEMINI'),
      'model', p_generation->>'model',
      'output_identity_version', v_identity_version,
      'classification','AI_CONCEPT_NOT_PRODUCT_VERIFIED',
      'rights_state','ORIGINAL_CONCEPT',
      'identity_validated', false,
      'promotion','blocked: an AI concept is not a verified product asset; no automatic commercial clearance or export',
      'registered_at', now()))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok',true,'concept_asset_id',v_id,
    'classification','AI_CONCEPT_NOT_PRODUCT_VERIFIED','rights_state','ORIGINAL_CONCEPT',
    'identity_validated',false,'identity_version',v_identity_version,'promotion_allowed',false,
    'note','Registered as an ORIGINAL_CONCEPT asset. It is NOT a verified product depiction and can never be promoted, cleared, or exported as a product/commercial image.');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_register_concept_asset(uuid,uuid,text,text,jsonb,jsonb) TO service_role;

-- ============================================================================
-- 3) Promotion is always refused (DB-level mirror of rejectConceptPromotion).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_concept_asset_promotion_blocked(p_concept_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  RETURN jsonb_build_object(
    'allowed', false,
    'reason', 'AI concept is not a verified product asset; validation + commercial clearance required',
    'concept_asset_id', p_concept_asset_id);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_concept_asset_promotion_blocked(uuid) TO authenticated, service_role;

-- ============================================================================
-- 4) Selftest (rolled-back synthetic fixtures; nothing persists). Runs at apply.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_concept_provenance_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int; v_fail int; v_r jsonb;
  v_prod uuid; v_owner uuid; v_other uuid := '11111111-1111-4111-8111-111111111111';
  v_good jsonb := jsonb_build_object(
    'rightsState','ORIGINAL_CONCEPT','classification','AI_CONCEPT_NOT_PRODUCT_VERIFIED',
    'identityValidated', false, 'outputIdentityVersion','piv-deadbeef',
    'prompt','AI CONCEPT — NOT PRODUCT VERIFIED. Create an original, unbranded concept...',
    'inputProvenance', jsonb_build_object('rightsBasis','ORIGINAL_CONCEPT_TEXT_ONLY','referenceAsset', null));
  v_gen jsonb := jsonb_build_object('provider','GOOGLE_GEMINI','model','gemini-2.5-flash-image',
    'job_id','ccg-selftest','bucket','pulse-generated-media','mime','image/png','scene','LIFESTYLE','aspect_ratio','1:1');
BEGIN
  -- Promotion is always refused (no row needed).
  v_r := public.fn_concept_asset_promotion_blocked('00000000-0000-4000-8000-000000000000');
  v_checks := v_checks || jsonb_build_object('check','PROMOTION_ALWAYS_BLOCKED',
    'ok', (v_r->>'allowed')='false', 'detail', v_r->>'allowed');

  -- Missing args.
  v_r := public.fn_register_concept_asset(null, null, 'US', '', v_gen, v_good);
  v_checks := v_checks || jsonb_build_object('check','MISSING_ARGS_REJECTED',
    'ok', (v_r->>'ok')='false' AND v_r->>'error'='missing_args', 'detail', v_r->>'error');

  -- Find a real owned product to exercise the owner-scoped write path (rolled back).
  SELECT id, user_id INTO v_prod, v_owner FROM public.commerce_products
    WHERE user_id IS NOT NULL AND coalesce(is_fixture,false)=false ORDER BY created_at ASC LIMIT 1;

  IF v_prod IS NOT NULL THEN
    BEGIN
      -- Cross-tenant write is rejected.
      v_r := public.fn_register_concept_asset(v_other, v_prod, 'US', 'pulse-generated-media/concept/x.png', v_gen, v_good);
      v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED',
        'ok', (v_r->>'ok')='false' AND v_r->>'error'='cross_tenant_rejected', 'detail', v_r->>'error');

      -- Non-original provenance (identity validated) is rejected.
      v_r := public.fn_register_concept_asset(v_owner, v_prod, 'US', 'pulse-generated-media/concept/x.png', v_gen,
        v_good || jsonb_build_object('identityValidated', true));
      v_checks := v_checks || jsonb_build_object('check','NON_ORIGINAL_PROVENANCE_REJECTED',
        'ok', (v_r->>'ok')='false' AND v_r->>'error'='not_original_concept_provenance', 'detail', v_r->>'error');

      -- Reference-asset-bearing provenance is rejected (text-only lane).
      v_r := public.fn_register_concept_asset(v_owner, v_prod, 'US', 'pulse-generated-media/concept/x.png', v_gen,
        jsonb_set(v_good, '{inputProvenance,referenceAsset}', '"some-asset-id"'::jsonb));
      v_checks := v_checks || jsonb_build_object('check','REFERENCE_ASSET_REJECTED',
        'ok', (v_r->>'ok')='false' AND v_r->>'error'='not_original_concept_provenance', 'detail', v_r->>'error');

      -- Happy path: owner + original-concept provenance registers with fixed fields.
      v_r := public.fn_register_concept_asset(v_owner, v_prod, 'US', 'pulse-generated-media/concept/ok.png', v_gen, v_good);
      v_checks := v_checks || jsonb_build_object('check','REGISTERED_ORIGINAL_CONCEPT',
        'ok', (v_r->>'ok')='true'
           AND v_r->>'classification'='AI_CONCEPT_NOT_PRODUCT_VERIFIED'
           AND v_r->>'rights_state'='ORIGINAL_CONCEPT'
           AND (v_r->>'identity_validated')='false'
           AND (v_r->>'promotion_allowed')='false'
           AND v_r->>'identity_version'='piv-deadbeef',
        'detail', v_r);

      -- The row exists, is classified correctly, and carries no commercial status column.
      v_checks := v_checks || jsonb_build_object('check','ROW_PERSISTED_AS_CONCEPT',
        'ok', EXISTS(SELECT 1 FROM public.concept_generated_assets
                     WHERE id=(v_r->>'concept_asset_id')::uuid
                       AND classification='AI_CONCEPT_NOT_PRODUCT_VERIFIED'
                       AND rights_state='ORIGINAL_CONCEPT' AND identity_validated=false),
        'detail', v_r->>'concept_asset_id');

      RAISE EXCEPTION 'concept_provenance_selftest_rollback';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  ELSE
    v_checks := v_checks || jsonb_build_object('check','WRITE_PATH_SKIPPED_NO_PRODUCT','ok',true,'detail','no owned product available');
  END IF;

  v_checks := v_checks || jsonb_build_object('check','NO_SYNTHETIC_PERSISTED',
    'ok', NOT EXISTS(SELECT 1 FROM public.concept_generated_assets WHERE generation_job_id='ccg-selftest'),
    'detail', (SELECT count(*) FROM public.concept_generated_assets WHERE generation_job_id='ccg-selftest'));

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'checks', v_checks, 'contract','pulse_concept_provenance_selftest_v1','generated_at', now());
END; $function$;
