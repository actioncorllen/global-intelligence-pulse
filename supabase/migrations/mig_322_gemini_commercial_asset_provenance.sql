-- ============================================================================
-- mig_322_gemini_commercial_asset_provenance.sql
-- STRATELOQ — Google Gemini commercial-image generation: provenance, provider
-- status, and identity-validation persistence.
--
-- The Gemini image-to-image executor and the Gemini identity validator now run
-- in n8n (reusing the existing googlePalmApi credential and the pulse-generated-
-- media bucket). This migration adds the DB side, all honest and additive:
--
--   * commerce_generated_assets — a dedicated, tenant-isolated table for
--     AI-generated commercial product assets. Kept separate from media_assets
--     (the creative-ad launch pipeline) and from product_image_assets /
--     supplier_product_assets so a generated asset never overwrites or is
--     mistaken for a supplier-authorized or customer-owned source asset. The
--     original reference asset's provenance is never altered, and a generated
--     asset is NEVER labelled CUSTOMER_OWNED or SUPPLIER_PROVIDED.
--
--   * fn_register_generated_commercial_asset(...) — records a generated asset
--     with full honest provenance (reference asset + its provider/rights,
--     generation provider GOOGLE_GEMINI + model, n8n workflow/job ids, storage
--     ref, identity-validation verdict, commercial-asset status). A generated
--     asset is publishable-candidate ONLY when identity_validation_status =
--     'IDENTITY_VALIDATED'; a REJECT_GENERATED_ASSET verdict can never be
--     promoted.
--
--   * fn_commercial_image_provider_status() — reports the AI commercial-image
--     provider now connected (GOOGLE_GEMINI) plus the executor/validator n8n
--     workflow ids. Honest config signal; no secrets.
--
--   * fn_product_commercial_asset_readiness updated: when a product has an
--     eligible authorized reference AND the provider is connected, the AI
--     generation execution_state is reported 'AVAILABLE' (was
--     'BLOCKED_EXTERNAL_CONNECTION'); marketplace-only products stay
--     'NOT_ELIGIBLE'. Nothing about the rights model or publish gates changes.
--
-- RLS, tenant isolation, Product Asset Lock and publish gates unchanged.
-- Idempotent where practical.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.commerce_generated_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  supplier_product_id text,
  reference_asset_id uuid,
  reference_asset_url text,
  reference_provider text,
  reference_rights_state text,
  generation_provider text NOT NULL DEFAULT 'GOOGLE_GEMINI',
  generation_model text,
  generation_workflow text,
  generation_job_id text,
  storage_bucket text,
  storage_ref text,
  mime_type text,
  width integer,
  height integer,
  identity_validation_status text NOT NULL DEFAULT 'PENDING_IDENTITY_VALIDATION'
    CHECK (identity_validation_status IN ('PENDING_IDENTITY_VALIDATION','IDENTITY_VALIDATED','REJECT_GENERATED_ASSET','VALIDATION_ERROR')),
  identity_validation jsonb NOT NULL DEFAULT '{}'::jsonb,
  commercial_asset_status text NOT NULL DEFAULT 'GENERATED_REVIEW_REQUIRED'
    CHECK (commercial_asset_status IN ('GENERATED_REVIEW_REQUIRED','GENERATED_VALIDATED','REJECTED','PUBLISHED')),
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.commerce_generated_assets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cga_tenant_select ON public.commerce_generated_assets;
CREATE POLICY cga_tenant_select ON public.commerce_generated_assets
  FOR SELECT TO authenticated USING (tenant_id = auth.uid());
-- Writes go only through the SECURITY DEFINER registration function.
DROP POLICY IF EXISTS cga_no_direct_write ON public.commerce_generated_assets;
CREATE POLICY cga_no_direct_write ON public.commerce_generated_assets
  FOR ALL TO authenticated USING (false) WITH CHECK (false);

CREATE INDEX IF NOT EXISTS idx_cga_tenant_product ON public.commerce_generated_assets(tenant_id, product_id);

COMMENT ON TABLE public.commerce_generated_assets IS
  'AI-generated commercial product assets (e.g. Google Gemini). Separate from source assets; a generated asset is never labelled CUSTOMER_OWNED/SUPPLIER_PROVIDED and is publishable-candidate only when identity_validation_status = IDENTITY_VALIDATED. Original reference provenance is never altered here.';

-- ---------------------------------------------------------------------------
-- Provider status (honest config; no secrets).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_commercial_image_provider_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'provider','GOOGLE_GEMINI',
    'connected', true,
    'model','gemini-2.5-flash-image',
    'executor_workflow','OYjIUMd0GS7OanbY',
    'identity_validator_workflow','HjjGApAXKpWXPh4q',
    'identity_validator_model','gemini-2.5-flash',
    'infra','n8n',
    'note','AI commercial-image generation is available for products with an eligible authorized reference (supplier-authorized or customer-owned). Marketplace/reference imagery is never an eligible source. Existing OpenAI creative path is unchanged.');
$function$;

-- ---------------------------------------------------------------------------
-- Register a generated commercial asset with honest provenance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_register_generated_commercial_asset(
  p_tenant uuid,
  p_product_id uuid,
  p_storage_ref text,
  p_reference jsonb,
  p_generation jsonb,
  p_identity jsonb
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_id uuid; v_verdict text; v_idstate text; v_status text; v_sup jsonb;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_verdict := upper(coalesce(p_identity->>'verdict',''));
  v_idstate := CASE
    WHEN v_verdict = 'IDENTITY_VALIDATED' THEN 'IDENTITY_VALIDATED'
    WHEN v_verdict = 'REJECT_GENERATED_ASSET' THEN 'REJECT_GENERATED_ASSET'
    WHEN v_verdict = '' THEN 'PENDING_IDENTITY_VALIDATION'
    ELSE 'VALIDATION_ERROR' END;
  -- Only an identity-validated asset becomes a publishable candidate; a reject
  -- can never be promoted.
  v_status := CASE
    WHEN v_idstate = 'IDENTITY_VALIDATED' THEN 'GENERATED_VALIDATED'
    WHEN v_idstate = 'REJECT_GENERATED_ASSET' THEN 'REJECTED'
    ELSE 'GENERATED_REVIEW_REQUIRED' END;

  v_sup := public.fn_product_supplier_identity(p_product_id);

  INSERT INTO public.commerce_generated_assets(
    tenant_id, product_id, supplier_product_id,
    reference_asset_id, reference_asset_url, reference_provider, reference_rights_state,
    generation_provider, generation_model, generation_workflow, generation_job_id,
    storage_bucket, storage_ref, mime_type, width, height,
    identity_validation_status, identity_validation, commercial_asset_status, provenance)
  VALUES (
    p_tenant, p_product_id, v_sup->>'supplier_product_id',
    nullif(p_reference->>'asset_id','')::uuid, p_reference->>'url',
    p_reference->>'provider', p_reference->>'rights_state',
    coalesce(p_generation->>'provider','GOOGLE_GEMINI'), p_generation->>'model',
    p_generation->>'workflow', p_generation->>'job_id',
    coalesce(p_generation->>'bucket','pulse-generated-media'), p_storage_ref,
    coalesce(p_generation->>'mime','image/png'),
    coalesce((p_generation->>'width')::int,1024), coalesce((p_generation->>'height')::int,1024),
    v_idstate, coalesce(p_identity,'{}'::jsonb), v_status,
    jsonb_build_object(
      'generation_provider', coalesce(p_generation->>'provider','GOOGLE_GEMINI'),
      'generation_model', p_generation->>'model',
      'generation_workflow', p_generation->>'workflow',
      'generation_job_id', p_generation->>'job_id',
      'reference', p_reference,
      'identity_validation', coalesce(p_identity,'{}'::jsonb),
      'product_asset_lock','enforced: generated output validated against the authorized reference SKU',
      'rights_note','generated derivative from an authorized reference; NOT customer-owned and NOT the supplier source asset',
      'registered_at', now()))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok',true,'generated_asset_id',v_id,
    'identity_validation_status', v_idstate, 'commercial_asset_status', v_status,
    'publishable_candidate', (v_idstate='IDENTITY_VALIDATED'),
    'note','Registered as a generated commercial asset. Publishing still requires the normal review/publish gates; nothing is auto-published.');
END; $function$;

-- ---------------------------------------------------------------------------
-- Readiness: report AI generation AVAILABLE (not blocked) when eligible + connected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_commercial_asset_readiness(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_sup jsonb; v_resolve jsonb; v_state text; v_provider text;
  v_has_supplier_authorized boolean := false; v_has_customer_owned boolean := false;
  v_has_marketplace boolean := false; v_total_images int := 0;
  v_readiness text; v_path text; v_basis text; v_gemini_eligible boolean;
  v_provider_connected boolean; v_exec_state text; v_validated_generated int := 0;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  SELECT
    count(*),
    bool_or(rights_state='SUPPLIER_PROVIDED'),
    bool_or(rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
            AND coalesce(provenance->>'rights_confirmed','false')='true'),
    bool_or(rights_state='MARKETPLACE_PUBLIC_LISTING')
  INTO v_total_images, v_has_supplier_authorized, v_has_customer_owned, v_has_marketplace
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false)=false;
  v_sup := public.fn_product_supplier_identity(p_product_id);
  v_provider := v_sup->>'provider';
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    v_resolve := public.fn_resolve_storefront_assets(v_provider, v_sup->>'supplier_product_id', p_market);
    v_state := v_resolve->>'state';
  END IF;
  v_gemini_eligible := (v_has_supplier_authorized OR v_has_customer_owned
                        OR (v_sup->>'has_supplier')::boolean IS TRUE);
  v_provider_connected := coalesce((public.fn_commercial_image_provider_status()->>'connected')::boolean,false);

  SELECT count(*) INTO v_validated_generated FROM public.commerce_generated_assets
   WHERE product_id = p_product_id AND identity_validation_status='IDENTITY_VALIDATED';

  IF v_state = 'ASSETS_AVAILABLE' THEN
    v_readiness := 'READY'; v_path := 'SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET';
    v_basis := 'Connected supplier provides a rights-cleared product image for this exact supplier product.';
  ELSIF v_has_customer_owned THEN
    v_readiness := 'READY'; v_path := 'CUSTOMER_OWNED_ASSET';
    v_basis := 'A rights-confirmed customer-owned product image is available.';
  ELSIF v_has_supplier_authorized OR coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    v_readiness := 'GENERATABLE_FROM_AUTHORIZED_REFERENCE'; v_path := 'SUPPLIER_AUTHORIZED_REFERENCE';
    v_basis := 'An authorized supplier reference exists; a commercial image can be generated from it (identity-validated) rather than republishing a marketplace image.';
  ELSIF v_has_marketplace THEN
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'Only marketplace/reference imagery is available. Image access is not republishing rights, so a customer-owned or supplier-authorized image is required to publish.';
  ELSIF v_total_images = 0 THEN
    v_readiness := 'UNAVAILABLE'; v_path := 'NONE';
    v_basis := 'No product imagery has been observed for this product.';
  ELSE
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'No rights-cleared commercial image path is established yet.';
  END IF;

  v_exec_state := CASE
    WHEN NOT v_gemini_eligible THEN 'NOT_ELIGIBLE'
    WHEN v_provider_connected THEN 'AVAILABLE'
    ELSE 'BLOCKED_EXTERNAL_CONNECTION' END;

  RETURN jsonb_build_object(
    'status','ok','product_id', p_product_id, 'market', upper(coalesce(p_market,'')),
    'commercial_asset_readiness', v_readiness,
    'publishable_asset_path', v_path,
    'basis', v_basis,
    'has_supplier_match', coalesce((v_sup->>'has_supplier')::boolean,false),
    'supplier_provider', v_provider,
    'supplier_product_id', v_sup->>'supplier_product_id',
    'supplier_resolution_state', coalesce(v_state,'NOT_RESOLVED'),
    'validated_generated_assets', v_validated_generated,
    'images', jsonb_build_object('total', v_total_images,
      'has_supplier_authorized', v_has_supplier_authorized,
      'has_customer_owned', v_has_customer_owned,
      'has_marketplace_reference', v_has_marketplace),
    'ai_generation', jsonb_build_object(
      'reference_eligible', v_gemini_eligible,
      'reference_basis', CASE
        WHEN v_has_customer_owned THEN 'CUSTOMER_OWNED'
        WHEN v_has_supplier_authorized OR coalesce((v_sup->>'has_supplier')::boolean,false) THEN 'SUPPLIER_AUTHORIZED'
        ELSE 'NONE' END,
      'provider','GOOGLE_GEMINI',
      'provider_connected', v_provider_connected,
      'execution_state', v_exec_state,
      'requires', CASE WHEN v_exec_state='AVAILABLE'
        THEN 'Ready: a publishable image can be generated from the authorized reference, then identity-validated before use.'
        WHEN v_exec_state='NOT_ELIGIBLE'
        THEN 'No eligible authorized reference. Marketplace/competitor imagery is never an eligible reference; a customer-owned or supplier-authorized image is required.'
        ELSE 'Google Gemini image-generation access is not connected.' END,
      'product_asset_lock','Generated output must preserve exact product identity/SKU and pass identity validation (IDENTITY_VALIDATED) before it becomes a commercial asset; a materially different SKU is REJECT_GENERATED_ASSET.'),
    'note','Marketplace/reference images are never a publishable or generation-eligible source. Rights are never fabricated.');
END; $function$;
