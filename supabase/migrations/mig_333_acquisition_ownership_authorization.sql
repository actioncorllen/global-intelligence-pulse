-- mig_333_acquisition_ownership_authorization.sql
-- P0 "Add to My Products" enabler: let the CANONICAL-ID-FIRST acquisition path authorize on product
-- OWNERSHIP alone (commerce_products.user_id = auth.uid()), independent of the legacy
-- member_business_dna / is_ecommerce gate. Founder-approved approach ("authorize on ownership").
--
-- STATUS: PREPARED FOR FOUNDER REVIEW — *** NOT YET APPLIED TO PROD nxaunmyihhjixxxljcqt ***.
--
-- Why: mig_332 made create_product_acquisition canonical-id-first, but kept the pre-existing
-- member_business_dna + dna_extended.commerce.is_ecommerce='true' gate BEFORE the canonical branch.
-- Verified in prod: no current product owner (the founder included) has such a DNA row, so the function
-- returns 'not_ecommerce' for every real owner and no acquisition can be created — blocking the whole
-- "Add to My Products" journey. Owning a commerce_products row is itself proof the caller is an
-- ecommerce member who discovered that product, so ownership (user_id = auth.uid()) is the correct and
-- sufficient authorization for acquiring one's OWN product.
--
-- Change (smallest safe): move the canonical-id-first branch BEFORE the member_business_dna lookup, so it
-- authorizes on ownership only. The member_business_dna + is_ecommerce gate is preserved UNCHANGED on the
-- LEGACY winning_product_intelligence path (which genuinely needs the member DNA). No new identity
-- generation; no title/URL/position/fuzzy inference; tenant isolation intact (ownership check); market still
-- resolved + stored at creation; Product Asset Lock / exact-SKU untouched. get_own_product_acquisitions and
-- fn_acquisition_primary_market are unchanged by this migration.
--
-- Idempotency: single CREATE OR REPLACE FUNCTION. Rollback: restore the mig_332 body of
-- create_product_acquisition(text) (captured in the P0 package).

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
    v_cand_pid text;
    v_pid      uuid;
    v_market   text;
    v_cp       record;
    v_canon    boolean := false;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    v_ref := nullif(btrim(coalesce(p_product_ref,'')),'');
    IF v_ref IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    -- ---- Canonical-id-first path: authorize on OWNERSHIP alone (no member_business_dna dependency). ----
    -- The verified canonical identity the Explorer / Recommendations already use; ownership is the
    -- authorization for acquiring one's own product. No title/URL/position/fuzzy inference.
    IF v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      SELECT cp.id, cp.title, cp.product_url, cp.source_store, cp.source_run_id
        INTO v_cp
        FROM public.commerce_products cp
        WHERE cp.id = v_ref::uuid AND cp.user_id = v_uid
        LIMIT 1;
      v_canon := FOUND;
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
      v_state  := 'DISCOVERED';

      SELECT id INTO v_existing FROM public.product_acquisitions
       WHERE user_id = v_uid AND state <> 'DISCARDED' AND product_id = v_pid
       LIMIT 1;
      IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object('status','exists','acquisition_id', v_existing); END IF;

      INSERT INTO public.product_acquisitions
          (user_id, source_run_id, state, winning_product_snapshot, sourcing_spec_snapshot, product_id, market)
      VALUES (v_uid, v_cp.source_run_id, v_state, v_cand, v_spec, v_pid, v_market)
      RETURNING id INTO v_id;
      RETURN jsonb_build_object('status','created','acquisition_id', v_id, 'state', v_state);
    END IF;

    -- ---- Legacy reference path (winning_product_intelligence); requires member DNA + ecommerce. ----
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
