-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- Runtime columns (additive) + asset-safety resolver (PHASE E) + the runtime
-- storefront generator (PHASE C/D). The generator FAILS CLOSED at the TEST gate
-- before persisting any production page, resolves only evidence-backed data,
-- selects a template deterministically, enforces claim + asset safety, and
-- persists the LOCKED RUNTIME CONTRACT. Reuses fn_generate_page_copy /
-- fn_create_pulse_store_draft / fn_ad_studio_claim_scan / fn_ad_studio_handoff.

-- ---------------------------------------------------------------------------
-- Additive runtime columns on the existing page table (back-compatible).
-- ---------------------------------------------------------------------------
ALTER TABLE public.commerce_product_pages
  ADD COLUMN IF NOT EXISTS country_code text,
  ADD COLUMN IF NOT EXISTS opportunity_decision_id uuid,
  ADD COLUMN IF NOT EXISTS template_family text,
  ADD COLUMN IF NOT EXISTS template_version text,
  ADD COLUMN IF NOT EXISTS ad_match_ref jsonb,
  ADD COLUMN IF NOT EXISTS supplier_asset_refs jsonb,
  ADD COLUMN IF NOT EXISTS generation_state text DEFAULT 'GENERATED',
  ADD COLUMN IF NOT EXISTS review_state text DEFAULT 'DRAFT',
  ADD COLUMN IF NOT EXISTS publication_state text DEFAULT 'UNPUBLISHED',
  ADD COLUMN IF NOT EXISTS runtime_contract jsonb;

-- ---------------------------------------------------------------------------
-- fn_resolve_storefront_assets: PHASE E asset safety. Reuses
-- supplier_product_assets. Only assets with valid availability + rights +
-- fulfilment-source provenance are usable. Reference-only assets (CJ sourcing
-- reference images, Fruugo/marketplace reference images) can NEVER resolve as
-- publishable storefront marketing assets. No fabricated replacement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_storefront_assets(
  p_supplier text, p_supplier_product_id text, p_market text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_fulfil text := lower(coalesce(p_supplier,''));
  v_usable jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_primary jsonb := NULL;
  r record; v_reason text;
BEGIN
  IF v_fulfil IN ('cj','cjdropshipping','cj_dropshipping') THEN v_fulfil := 'cjdropshipping'; END IF;

  FOR r IN
    SELECT * FROM public.supplier_product_assets
    WHERE p_supplier_product_id IS NOT NULL
      AND supplier_product_id = p_supplier_product_id
    ORDER BY is_primary DESC NULLS LAST, observed_at DESC NULLS LAST
  LOOP
    v_reason := NULL;
    -- Reference-only / rights / availability rejections (fail closed).
    IF coalesce(r.availability,'') <> 'AVAILABLE' THEN v_reason := 'UNAVAILABLE';
    ELSIF coalesce(r.rights_state,'UNKNOWN') NOT IN ('SUPPLIER_PROVIDED','LICENSED','OWNED') THEN v_reason := 'RIGHTS_NOT_ESTABLISHED';
    ELSIF coalesce(r.provenance->>'reference_only','false') = 'true' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.provenance->>'purpose','') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_identity,'') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_type,'') ILIKE '%reference%' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.asset_class,'') NOT IN ('SOURCE_PRODUCT_ASSET','GENERATED_CREATIVE','LICENSED_ASSET') THEN v_reason := 'DISALLOWED_ASSET_CLASS';
    ELSIF lower(coalesce(r.original_source,'')) IN ('fruugo','ebay','amazon','aliexpress-reference','reference') THEN v_reason := 'REFERENCE_ONLY_MARKETPLACE';
    ELSIF v_fulfil <> '' AND lower(coalesce(r.original_source,'')) <> v_fulfil AND lower(coalesce(r.supplier,'')) <> v_fulfil THEN v_reason := 'NOT_FULFILMENT_SUPPLIER_SOURCE';
    END IF;

    IF v_reason IS NULL THEN
      v_usable := v_usable || jsonb_build_object(
        'asset_id', r.id, 'asset_type', r.asset_type,
        'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
        'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
        'rights_state', r.rights_state, 'is_primary', coalesce(r.is_primary,false),
        'source_url', r.source_url, 'storage_ref', r.storage_ref, 'original_source', r.original_source);
      IF v_primary IS NULL AND coalesce(r.asset_type,'IMAGE') ILIKE '%image%' THEN
        v_primary := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
                       'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END);
      END IF;
    ELSE
      v_rejected := v_rejected || jsonb_build_object('asset_id', r.id, 'reason', v_reason,
        'original_source', r.original_source, 'rights_state', r.rights_state, 'availability', r.availability);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'state', CASE WHEN v_primary IS NOT NULL THEN 'ASSETS_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END,
    'primary_image', v_primary,
    'gallery', v_usable,
    'usable_count', jsonb_array_length(v_usable),
    'rejected', v_rejected,
    'rejected_count', jsonb_array_length(v_rejected),
    'fulfilment_supplier', v_fulfil,
    'supplier_product_id', p_supplier_product_id,
    'no_fabricated_replacement', true,
    'source_vs_generated_distinction', 'origin_kind on each asset (SOURCE_SUPPLIER vs GENERATED)');
END; $function$;

COMMENT ON FUNCTION public.fn_resolve_storefront_assets(text,text,text) IS
 'Asset-safety resolver: usable storefront assets from supplier_product_assets (available + rights-clear + fulfilment-source). Reference-only assets (CJ sourcing reference, Fruugo/marketplace) can never resolve. No fabricated replacement; IMAGE_UNAVAILABLE when none.';

-- ---------------------------------------------------------------------------
-- fn_generate_storefront_runtime: the launch-critical runtime path.
-- Product×Country -> TEST gate -> template selection -> evidence-safe content
-- -> asset safety -> publishable DRAFT resolving the LOCKED RUNTIME CONTRACT.
-- Refuses (creates nothing) when not TEST_ELIGIBLE. FIXTURE source may render an
-- isolated, explicitly non-publishable dev preview only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_generate_storefront_runtime(
  p_user_id uuid,
  p_gate_inputs jsonb,
  p_selection_input jsonb,
  p_context jsonb,
  p_decision jsonb,
  p_destination text DEFAULT 'PULSE_HOSTED',
  p_source_kind text DEFAULT 'REAL',
  p_product_id uuid DEFAULT NULL,
  p_country_code text DEFAULT NULL,
  p_opportunity_decision_id uuid DEFAULT NULL,
  p_persist boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_gate jsonb; v_sel jsonb; v_assets jsonb; v_copy jsonb; v_scan jsonb;
  v_family text; v_market text := upper(coalesce(p_decision->>'target_market', p_country_code, ''));
  v_contract jsonb; v_draft jsonb; v_page_id uuid; v_marketing_text text; v_ad_match jsonb;
  v_dest text := upper(coalesce(p_destination,'PULSE_HOSTED'));
BEGIN
  -- STEP 1 — HARD TEST eligibility gate (fail closed).
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  IF NOT (v_gate->>'test_eligible')::boolean THEN
    IF p_source_kind = 'FIXTURE' THEN
      -- Isolated dev preview ONLY: never a real publishable product.
      v_sel := public.fn_select_conversion_template(p_selection_input);
      RETURN jsonb_build_object('status','REFUSED_PRODUCTION_DEV_PREVIEW_ONLY',
        'test_eligible', false, 'generation_state','DEV_PREVIEW_NON_PUBLISHABLE',
        'publication_state','BLOCKED_NON_PUBLISHABLE', 'is_fixture', true,
        'gate', v_gate, 'template_preview', v_sel->>'recommended_template_family',
        'note','Fixture/dev preview only; not eligible; nothing persisted as a real product.');
    END IF;
    RETURN jsonb_build_object('status','REFUSED','test_eligible', false,
      'generation_state','REFUSED','reason_codes', v_gate->'reason_codes',
      'decision_state', v_gate->>'decision_state', 'gate', v_gate,
      'note','Not TEST_ELIGIBLE; no storefront generated. Fail-closed.');
  END IF;

  -- STEP 2 — deterministic template selection.
  v_sel := public.fn_select_conversion_template(p_selection_input);
  v_family := v_sel->>'recommended_template_family';

  -- STEP 3 — evidence-safe base copy (reuse existing claim-safe generator).
  v_copy := public.fn_generate_page_copy(p_decision, p_context);

  -- STEP 4 — asset safety (reference-only can never resolve).
  v_assets := public.fn_resolve_storefront_assets(
                p_context->>'supplier', p_context->>'supplier_product_id', p_country_code);

  -- Defense-in-depth claim scan across assembled marketing copy.
  v_marketing_text := concat_ws(' ',
     v_copy->'hero'->>'headline', v_copy->'hero'->>'subheadline', v_copy->>'short_description',
     v_copy->'problem_solution'->>'problem', v_copy->'problem_solution'->>'solution',
     (SELECT string_agg(b,' ') FROM jsonb_array_elements_text(coalesce(v_copy->'benefits','[]'::jsonb)) b),
     v_copy->'trust'->>'copy', v_copy->'announcement'::text);
  v_scan := public.fn_ad_studio_claim_scan(v_marketing_text);

  -- Ad->page message match (Ad Studio addressability).
  v_ad_match := coalesce(p_selection_input->'ad_match', jsonb_build_object(
      'state','NO_AD_MATCH_YET',
      'addressable_by', jsonb_build_object('product_id', p_product_id, 'country_code', p_country_code, 'market', v_market),
      'offer_version','v1'));

  -- LOCKED RUNTIME CONTRACT
  v_contract := jsonb_build_object(
    'product_id', p_product_id,
    'country_code', p_country_code,
    'opportunity_decision_id', p_opportunity_decision_id,
    'template_family', v_family,
    'template_version', v_sel->>'template_version',
    'market', v_market,
    'destination', v_dest,
    'source_currency', coalesce(p_decision->'economics'->>'landed_cost_currency', p_context->>'source_currency'),
    'display_currency', p_context->>'display_currency',
    'economics_state', p_decision->'economics'->>'economics_state',
    'ad_match_ref', v_ad_match,
    'sections', v_sel->'sections',
    'hero_variant', v_sel->>'hero_variant',
    'cta_structure', v_sel->'cta_structure',
    'claim_safety', (coalesce(v_copy->'claim_safety','{}'::jsonb)
                     || jsonb_build_object('runtime_claim_scan', v_scan,
                          'claim_scan_clean', (jsonb_array_length(v_scan)=0),
                          'unsafe_sections_editable_placeholder', (jsonb_array_length(v_scan) > 0))),
    'copy_provenance', v_copy->'copy_provenance',
    'supplier_asset_refs', v_assets,
    'assets_state', v_assets->>'state',
    'selection', v_sel,
    'generation_state', 'GENERATED',
    'review_state', 'DRAFT',
    'publication_state', 'UNPUBLISHED',
    'terminology_guard','BEST_FIT_PRE_PERFORMANCE_NOT_PROVEN');

  IF NOT p_persist THEN
    RETURN jsonb_build_object('status','ok_preview','test_eligible',true,'persisted',false,
      'runtime_contract', v_contract, 'gate', v_gate);
  END IF;

  -- STEP 5 — persist. Reuse fn_create_pulse_store_draft (re-enforces TEST +
  -- creates page + project + Ad Studio handoff + conversion identity), then
  -- stamp the runtime-contract columns onto the created page.
  v_draft := public.fn_create_pulse_store_draft(p_user_id, p_decision, p_context, p_source_kind, p_product_id);
  IF coalesce((v_draft->>'created')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','REFUSED_AT_PERSIST','gate',v_gate,'draft',v_draft,
      'note','Eligibility passed but canonical draft creation refused (decision not TEST at persist).');
  END IF;
  v_page_id := (v_draft->>'product_page_id')::uuid;

  UPDATE public.commerce_product_pages SET
    country_code = p_country_code,
    opportunity_decision_id = p_opportunity_decision_id,
    template_family = v_family,
    template_version = v_sel->>'template_version',
    ad_match_ref = v_ad_match,
    supplier_asset_refs = v_assets,
    generation_state = 'GENERATED',
    review_state = 'DRAFT',
    publication_state = 'UNPUBLISHED',
    runtime_contract = v_contract,
    page_model = page_model
      || jsonb_build_object('template_family', v_family, 'template_version', v_sel->>'template_version',
           'sections', v_sel->'sections', 'hero_variant', v_sel->>'hero_variant',
           'assets_runtime', v_assets, 'ad_match_ref', v_ad_match),
    updated_at = now()
  WHERE id = v_page_id;

  RETURN jsonb_build_object('status','ok','test_eligible',true,'persisted',true,
    'product_page_id', v_page_id, 'store_project_id', v_draft->>'store_project_id',
    'template_family', v_family, 'template_version', v_sel->>'template_version',
    'review_state','DRAFT','publication_state','UNPUBLISHED','generation_state','GENERATED',
    'assets_state', v_assets->>'state', 'claim_scan_clean', (jsonb_array_length(v_scan)=0),
    'runtime_contract', v_contract, 'ad_studio_handoff', v_draft->'ad_studio_handoff',
    'preview', v_draft->'preview', 'gate', v_gate);
END; $function$;

COMMENT ON FUNCTION public.fn_generate_storefront_runtime(uuid,jsonb,jsonb,jsonb,jsonb,text,text,uuid,text,uuid,boolean) IS
 'Runtime storefront generator. Fails closed at the hard TEST gate before persisting; resolves only evidence-backed data; deterministic template selection; claim + asset safety; persists the locked runtime contract. FIXTURE source yields a non-publishable dev preview only.';