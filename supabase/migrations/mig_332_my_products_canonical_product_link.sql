-- mig_332_my_products_canonical_product_link.sql
-- Product Detail Integration: connect "My Products" acquisitions to the existing enriched
-- product-detail drawer (ExplorerDrawer / ProductIntelligenceDrawer) by preserving the VERIFIED
-- CANONICAL commerce_products.id identity on each acquisition, AND completing upstream identity
-- propagation through the established acquisition workflow.
--
-- STATUS: PREPARED FOR FOUNDER REVIEW — *** NOT YET APPLIED TO PROD nxaunmyihhjixxxljcqt ***.
--
-- Architecture facts verified before this change (read-only on prod):
--   * The live Recommendations/opportunity path is product_opportunity_decisions JOIN commerce_products
--     (fn_monday_top_opportunities); it carries the canonical commerce_products.id. It does NOT use
--     winning_product_intelligence.
--   * winning_product_intelligence is EMPTY for every member and no DB function writes it; the legacy
--     create_product_acquisition path that reads it is dormant. No frontend action creates acquisitions
--     today (useAcquisitionActions: select/discard/prepare/approve/download — no create), and
--     product_acquisitions is EMPTY in prod.
--   * commerce_products candidate identity is 'candidate:'||fn_commerce_product_identity(url,pid,title,
--     source). Reconstructing it from a legacy winning_product_intelligence candidate (which carries only
--     product_url/product_title) is unreliable, so identity is NEVER re-derived from title/URL/position/fuzzy.
--   * media_assets and product_image_assets have RLS ENABLED with NO policies (read only via SECURITY
--     DEFINER functions). Market is therefore resolved + stored at creation (inside this SECURITY DEFINER
--     function), and the SECURITY INVOKER read simply returns the stored value.
--
-- Upstream identity propagation (the fix): make the acquisition workflow CANONICAL-ID-FIRST. When the
-- acquisition reference is a commerce_products.id the caller already holds (the SAME id the Explorer,
-- Recommendations and opportunity decisions use), validate it is owned by auth.uid() and store it directly
-- as product_id, with its primary evidenced market. No inference, no dependency on the dormant
-- winning_product_intelligence producer. The legacy winning_product_intelligence path is preserved
-- unchanged except that it, too, stores ONLY an explicit, validated, owned candidate.product_id.
--
-- Safety / invariants:
--   * Additive + nullable columns; empty table; all resolution + reads are auth.uid()/tenant-scoped —
--     existing records and n8n/edge workflows unaffected (req 7); tenant isolation/RLS preserved (req 10).
--   * No current caller passes a uuid ref, so the canonical-id-first branch changes no live behaviour.
--   * create_product_acquisition keeps its existing posture (SECURITY DEFINER, VOLATILE, search_path='',
--     owner postgres); get_own_product_acquisitions keeps its posture (SECURITY INVOKER, STABLE,
--     search_path=''). No privilege elevation. Grants unchanged (authenticated/service_role EXECUTE).
--   * Unresolvable identity -> product_id NULL -> UI shows unresolved and never opens another product (req 8).
--   * Market = the product's primary EVIDENCED market (images, else top video country), else the best
--     opportunity-decision country; honest NULL when none — never fabricated (req 3, req 6).
--   * No new paid calls; Product Asset Lock, exact-SKU and country isolation untouched; no discovery or
--     recommendation logic modified.
--
-- Idempotency: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE FUNCTION + COMMENT are all safely re-runnable.
--
-- Rollback:
--   ALTER TABLE public.product_acquisitions DROP COLUMN IF EXISTS product_id;
--   ALTER TABLE public.product_acquisitions DROP COLUMN IF EXISTS market;
--   -- then restore the prior bodies of create_product_acquisition(text) and
--   -- get_own_product_acquisitions() (captured verbatim pre-migration in the deployment package).

-- 1) Additive canonical link + market context. Nullable; FK to canonical products; survive deletion.
ALTER TABLE public.product_acquisitions
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.commerce_products(id) ON DELETE SET NULL;
ALTER TABLE public.product_acquisitions
  ADD COLUMN IF NOT EXISTS market text;

COMMENT ON COLUMN public.product_acquisitions.product_id IS
  'Verified canonical commerce_products.id (owned). NULL when identity is not verified -> UI shows unresolved and never opens another product.';
COMMENT ON COLUMN public.product_acquisitions.market IS
  'Primary evidenced market/country for the linked product at acquisition time; NULL when none. Display context only; the drawer re-fetches live, market-isolated media/economics.';

-- 2) Canonical-id-first acquisition creation (reuse the canonical id + store its market; no inference).
CREATE OR REPLACE FUNCTION public.create_product_acquisition(p_product_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid      uuid := auth.uid();
    v_ref      text;
    v_run      uuid;
    v_commerce jsonb;
    v_wpi      jsonb;
    v_cand     jsonb;
    v_srco     jsonb;
    v_spec     jsonb;
    v_state    text;
    v_existing uuid;
    v_id       uuid;
    v_cand_pid text;   -- explicit canonical id carried by a legacy candidate (if any)
    v_pid      uuid;   -- verified, owned canonical commerce_products.id
    v_market   text;   -- primary evidenced market for the linked product
    v_cp       record;
    v_canon    boolean := false;  -- true only when the canonical-id lookup matched an owned product
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    v_ref := nullif(btrim(coalesce(p_product_ref,'')),'');
    IF v_ref IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    SELECT source_run_id, dna_extended->'commerce' INTO v_run, v_commerce
    FROM public.member_business_dna WHERE user_id = v_uid;
    IF v_run IS NULL OR v_commerce IS NULL
       OR (v_commerce->>'is_ecommerce') IS DISTINCT FROM 'true' THEN
        RETURN jsonb_build_object('status','not_ecommerce'); END IF;

    -- ---- Canonical-id-first path: the ref IS a commerce_products.id owned by the caller. ----
    -- The verified canonical identity the Explorer / Recommendations already use; carry it straight
    -- through. No winning_product_intelligence, no title/URL/position/fuzzy inference.
    -- Only attempt the lookup when the ref is uuid-shaped (avoids any cast error); FOUND gates the branch.
    IF v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      SELECT cp.id, cp.title, cp.product_url, cp.source_store, cp.source_run_id
        INTO v_cp
        FROM public.commerce_products cp
        WHERE cp.id = v_ref::uuid AND cp.user_id = v_uid
        LIMIT 1;
      v_canon := FOUND;  -- set immediately after this lookup; never inherited from an earlier SELECT
    END IF;

    IF v_canon THEN
      v_pid    := v_cp.id;
      v_market := public.fn_acquisition_primary_market(v_uid, v_pid);
      v_cand   := jsonb_strip_nulls(jsonb_build_object(
                    'product_id', v_cp.id::text,
                    'product_title', v_cp.title,
                    'product_url', v_cp.product_url,
                    'source', v_cp.source_store));
      v_spec   := jsonb_build_object('supplier_options', '[]'::jsonb);
      v_state  := 'DISCOVERED';  -- supplier sourcing happens later via the existing actions

      -- Idempotency by canonical product for this member.
      SELECT id INTO v_existing FROM public.product_acquisitions
       WHERE user_id = v_uid AND state <> 'DISCARDED' AND product_id = v_pid
       LIMIT 1;
      IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object('status','exists','acquisition_id', v_existing); END IF;

      INSERT INTO public.product_acquisitions
          (user_id, source_run_id, state, winning_product_snapshot, sourcing_spec_snapshot, product_id, market)
      VALUES (v_uid, coalesce(v_cp.source_run_id, v_run), v_state, v_cand, v_spec, v_pid, v_market)
      RETURNING id INTO v_id;
      RETURN jsonb_build_object('status','created','acquisition_id', v_id, 'state', v_state);
    END IF;

    -- ---- Legacy reference path (winning_product_intelligence), preserved unchanged. ----
    v_wpi := v_commerce->'winning_product_intelligence';
    IF v_wpi IS NULL OR (v_wpi->>'status') IS DISTINCT FROM 'available' THEN
        RETURN jsonb_build_object('status','no_winning_intelligence'); END IF;

    SELECT c INTO v_cand
    FROM jsonb_array_elements(coalesce(v_wpi->'candidates','[]'::jsonb)) c
    WHERE c->>'product_url' = v_ref OR c->>'product_title' = v_ref
    LIMIT 1;
    IF v_cand IS NULL THEN RETURN jsonb_build_object('status','candidate_not_found'); END IF;

    SELECT o INTO v_srco
    FROM jsonb_array_elements(
        coalesce(v_commerce->'supplier_sourcing_intelligence'->'sourcing_opportunities','[]'::jsonb)) o
    WHERE o->>'source_winning_product' = (v_cand->>'product_title')
    LIMIT 1;
    v_spec  := coalesce(v_srco, jsonb_build_object('supplier_options', '[]'::jsonb));
    v_state := CASE WHEN jsonb_array_length(coalesce(v_srco->'supplier_options','[]'::jsonb)) > 0
                    THEN 'SOURCED' ELSE 'DISCOVERED' END;

    -- Verified canonical identity: trust ONLY an explicit candidate product_id that is a real
    -- commerce_products row owned by this caller. No title/URL/position/fuzzy inference.
    v_cand_pid := nullif(btrim(coalesce(v_cand->>'product_id','')),'');
    v_pid := NULL;
    IF v_cand_pid IS NOT NULL THEN
      BEGIN
        SELECT id INTO v_pid FROM public.commerce_products
         WHERE id = v_cand_pid::uuid AND user_id = v_uid
         LIMIT 1;
      EXCEPTION WHEN invalid_text_representation THEN
        v_pid := NULL;
      END;
    END IF;
    v_market := CASE WHEN v_pid IS NULL THEN NULL ELSE public.fn_acquisition_primary_market(v_uid, v_pid) END;

    SELECT id INTO v_existing FROM public.product_acquisitions
    WHERE user_id = v_uid AND source_run_id = v_run AND state <> 'DISCARDED'
      AND coalesce(winning_product_snapshot->>'product_url', winning_product_snapshot->>'product_title')
        = coalesce(v_cand->>'product_url', v_cand->>'product_title')
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object('status','exists','acquisition_id', v_existing); END IF;

    INSERT INTO public.product_acquisitions
        (user_id, source_run_id, state, winning_product_snapshot, sourcing_spec_snapshot, product_id, market)
    VALUES (v_uid, v_run, v_state, v_cand, v_spec, v_pid, v_market)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('status','created','acquisition_id', v_id, 'state', v_state);
END; $function$;

-- Helper: the product's primary EVIDENCED market for a given owner (SECURITY DEFINER, tenant-scoped).
-- Images first (what the drawer shows), else top video country, else best opportunity-decision country.
CREATE OR REPLACE FUNCTION public.fn_acquisition_primary_market(p_uid uuid, p_product uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT coalesce(
    (SELECT market FROM public.product_image_assets
       WHERE product_id = p_product AND tenant_id = p_uid AND market IS NOT NULL
       GROUP BY market ORDER BY count(*) DESC, max(observed_at) DESC NULLS LAST LIMIT 1),
    (SELECT upper(country_code) FROM public.media_assets
       WHERE product_id = p_product AND tenant_id = p_uid
         AND upper(coalesce(media_type,'')) = 'VIDEO' AND country_code IS NOT NULL
       GROUP BY upper(country_code) ORDER BY count(*) DESC LIMIT 1),
    (SELECT upper(country_code) FROM public.product_opportunity_decisions
       WHERE product_id = p_product AND tenant_id = p_uid AND country_code IS NOT NULL
       ORDER BY product_opportunity_score DESC NULLS LAST LIMIT 1)
  );
$function$;
REVOKE ALL ON FUNCTION public.fn_acquisition_primary_market(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_acquisition_primary_market(uuid, uuid) TO service_role;

-- 3) Surface the stored canonical product_id + market on read (additive fields; posture unchanged).
CREATE OR REPLACE FUNCTION public.get_own_product_acquisitions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_items jsonb;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'acquisition_id', a.id, 'state', a.state, 'state_reason', a.state_reason,
        'source_run_id', a.source_run_id,
        'winning_product', a.winning_product_snapshot,
        'selected_supplier', a.selected_supplier_snapshot,
        'sourcing_spec', a.sourcing_spec_snapshot,
        'prepared_package', a.prepared_package,
        'generated_content_id', a.generated_content_id,
        'missing_information', a.missing_information,
        -- Verified canonical identity (NULL -> UI shows unresolved; never opens another product).
        'product_id', a.product_id,
        'market', a.market,
        'approved_at', a.approved_at,
        'created_at', a.created_at, 'updated_at', a.updated_at
    ) ORDER BY a.created_at DESC), '[]'::jsonb) INTO v_items
    FROM public.product_acquisitions a
    WHERE a.user_id = v_uid;
    RETURN jsonb_build_object('status','ok','acquisitions', v_items);
END; $function$;
