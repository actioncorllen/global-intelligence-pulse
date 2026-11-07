-- mig_332_my_products_canonical_product_link.sql
-- Product Detail Integration: connect "My Products" acquisitions to the existing enriched
-- product-detail drawer (ExplorerDrawer / ProductIntelligenceDrawer) by preserving the VERIFIED
-- CANONICAL commerce_products.id identity on each acquisition.
--
-- STATUS: PREPARED FOR FOUNDER REVIEW — *** NOT YET APPLIED TO PROD nxaunmyihhjixxxljcqt ***.
--
-- Problem
--   product_acquisitions stored only winning_product_snapshot (product_url/title); the frontend
--   acquisition contract (get_own_product_acquisitions / ProductAcquisition) exposed no canonical
--   product_id and no market, so My Products could not open the exact product's detail drawer.
--
-- Current-state facts verified before this change (read-only):
--   * product_acquisitions is EMPTY in prod (0 rows).
--   * Neither member has dna_extended->'commerce'->'winning_product_intelligence' populated, so
--     create_product_acquisition currently returns 'no_winning_intelligence' and no acquisition
--     can be created yet (the whole My Products acquisition path is dormant).
--   * The member's catalogue products are product_role='candidate' with identity
--     'candidate:name:<source>:<title>' — NOT the url/pid/name identity fn_commerce_product_identity
--     emits. Re-deriving identity from the acquisition snapshot's title/URL would therefore be
--     unreliable AND is forbidden (never infer identity from titles, URLs alone, positions or fuzzy
--     matching).
--
-- Fix (smallest, identity-safe, reuse-only)
--   Trust ONLY an explicit canonical product_id already carried by the winning-product candidate
--   (the id the discovery/opportunity pipeline assigned — the SAME canonical commerce_products.id
--   the Explorer and Recommendations use), and ONLY after validating it exists and is owned by the
--   caller. This never guesses and never mis-resolves:
--     v_pid := candidate->>'product_id', cast to uuid, kept only if it is a commerce_products row
--              owned by auth.uid(); otherwise NULL.
--   No title/URL/position/fuzzy inference. If the candidate carries no canonical id (or it does not
--   validate), product_id stays NULL and the UI shows an unresolved state — it never opens another
--   product (req 8).
--
-- Follow-up for req 6 (guaranteed future coverage), flagged separately, NOT in this migration:
--   the upstream producer that writes winning_product_intelligence candidates should stamp the
--   canonical commerce_products.id onto each candidate (it is known at projection time). Once it
--   does, every future acquisition resolves automatically through the code below. That producer is
--   outside this DB function (discovery projection), so it is proposed for separate review.
--
-- Safety / invariants
--   * Additive + nullable column; empty table; all resolution and reads are auth.uid()-scoped, so
--     existing records and n8n/edge workflows are unaffected (req 7); tenant isolation/RLS preserved
--     (req 10). No new paid calls, no commerce/creative/publishing path, Product Asset Lock untouched.
--   * Market/country is resolved read-side to the product's primary EVIDENCED market (where media
--     exists), honest NULL otherwise — never fabricated (req 3, req 6).
--
-- Rollback:
--   ALTER TABLE public.product_acquisitions DROP COLUMN IF EXISTS product_id;
--   -- then restore the prior bodies of create_product_acquisition(text) and
--   -- get_own_product_acquisitions() (captured verbatim pre-migration).

-- 1) Additive canonical link. Nullable; FK to canonical products; survive product deletion.
ALTER TABLE public.product_acquisitions
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.commerce_products(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.product_acquisitions.product_id IS
  'Verified canonical commerce_products.id (owned, explicit candidate id only). NULL when identity is not verified -> UI shows unresolved and never opens another product.';

-- 2) Store the verified canonical product_id at creation (explicit, validated, owned — no inference).
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
    v_cand_pid text;   -- explicit canonical id carried by the candidate (if any)
    v_pid      uuid;   -- verified, owned canonical commerce_products.id
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    v_ref := nullif(btrim(coalesce(p_product_ref,'')),'');
    IF v_ref IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    SELECT source_run_id, dna_extended->'commerce' INTO v_run, v_commerce
    FROM public.member_business_dna WHERE user_id = v_uid;
    IF v_run IS NULL OR v_commerce IS NULL
       OR (v_commerce->>'is_ecommerce') IS DISTINCT FROM 'true' THEN
        RETURN jsonb_build_object('status','not_ecommerce'); END IF;

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
        v_pid := NULL;  -- malformed id in the candidate: treat as unresolved, never guess
      END;
    END IF;

    -- Idempotency: return the existing active acquisition for this product+run.
    SELECT id INTO v_existing FROM public.product_acquisitions
    WHERE user_id = v_uid AND source_run_id = v_run AND state <> 'DISCARDED'
      AND coalesce(winning_product_snapshot->>'product_url', winning_product_snapshot->>'product_title')
        = coalesce(v_cand->>'product_url', v_cand->>'product_title')
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object('status','exists','acquisition_id', v_existing); END IF;

    INSERT INTO public.product_acquisitions
        (user_id, source_run_id, state, winning_product_snapshot, sourcing_spec_snapshot, product_id)
    VALUES (v_uid, v_run, v_state, v_cand, v_spec, v_pid)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('status','created','acquisition_id', v_id, 'state', v_state);
END; $function$;

-- 3) Surface the canonical product_id + primary evidenced market on read (additive fields only).
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
        -- Primary EVIDENCED market for this product (owner-scoped); NULL when none.
        'market', CASE WHEN a.product_id IS NULL THEN NULL ELSE coalesce(
            (SELECT market FROM public.product_image_assets
               WHERE product_id = a.product_id AND tenant_id = v_uid AND market IS NOT NULL
               GROUP BY market ORDER BY count(*) DESC, max(observed_at) DESC NULLS LAST LIMIT 1),
            (SELECT upper(country_code) FROM public.media_assets
               WHERE product_id = a.product_id AND tenant_id = v_uid
                 AND upper(coalesce(media_type,'')) = 'VIDEO' AND country_code IS NOT NULL
               GROUP BY upper(country_code) ORDER BY count(*) DESC LIMIT 1)
        ) END,
        'approved_at', a.approved_at,
        'created_at', a.created_at, 'updated_at', a.updated_at
    ) ORDER BY a.created_at DESC), '[]'::jsonb) INTO v_items
    FROM public.product_acquisitions a
    WHERE a.user_id = v_uid;
    RETURN jsonb_build_object('status','ok','acquisitions', v_items);
END; $function$;
