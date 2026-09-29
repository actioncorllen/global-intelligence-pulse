-- ============================================================================
-- mig_329_product_identity_resolution.sql
-- Minimum launch-safe Product Identity Resolution (paid-beta safe fallback).
-- A demand concept (e.g. a DataForSEO keyword such as "cool mist humidifier")
-- must never silently become a concrete product, and a loose supplier match
-- must never auto-link.
--
-- States: IDENTITY_RESOLVED / IDENTITY_AMBIGUOUS / CONCEPT_ONLY.
-- Reuses fn_product_supplier_identity + the existing fn_link_candidate_supplier.
-- Does NOT touch country isolation, Commercial Asset Rights, or Product Asset
-- Lock. Title similarity alone never resolves identity.
--
--  * fn_product_identity_resolution(product) — defensible identity from existing
--    evidence only (supplier link OR >=2 strong concrete identifiers; bounded
--    <=3 candidate set from stored evidence for the AMBIGUOUS case).
--  * fn_product_identity_badge(product) — concise {state,label,link_allowed,candidates}.
--  * fn_link_candidate_supplier — gated: a CONCEPT_ONLY product cannot be linked
--    unless the sanctioned user-select path sets the txn-local GUC.
--  * fn_product_identity_candidate_select(product,provider,source_product_id) —
--    tenant-guarded Path-B resolution: user picks a concrete candidate; records
--    it as the resolved identity. Does NOT grant commercial image rights.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_product_identity_resolution(p_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE cp record; sup jsonb; ext jsonb; v_has_link boolean; v_strong int := 0;
  v_state text; v_label text; v_candidates jsonb; v_fp jsonb; v_conf numeric;
BEGIN
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  ext := coalesce(cp.extended,'{}'::jsonb);
  sup := public.fn_product_supplier_identity(p_product_id);
  v_has_link := coalesce((sup->>'has_supplier')::boolean,false);
  v_conf := nullif(ext->>'extraction_confidence','')::numeric;

  v_strong :=
      (CASE WHEN nullif(ext->>'sku','')       IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN nullif(ext->>'model','')     IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN nullif(ext->>'brand','')     IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN coalesce(nullif(ext->>'gtin',''),nullif(ext->>'upc',''),nullif(ext->>'ean',''),nullif(ext->>'mpn','')) IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN nullif(ext->>'capacity','')  IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN coalesce(ext->'dimensions', ext->'specs'->'dimensions') IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN nullif(ext->>'weight','')    IS NOT NULL THEN 1 ELSE 0 END);

  v_candidates := coalesce((
    SELECT jsonb_agg(c) FROM (
      SELECT c FROM jsonb_array_elements(coalesce(ext->'identity_candidates','[]'::jsonb)) c LIMIT 3
    ) z), '[]'::jsonb);

  v_fp := jsonb_strip_nulls(jsonb_build_object(
    'product_name', cp.title, 'category', cp.category,
    'brand', ext->>'brand', 'model', ext->>'model', 'sku', ext->>'sku',
    'gtin', coalesce(ext->>'gtin',ext->>'upc',ext->>'ean',ext->>'mpn'),
    'capacity', ext->>'capacity', 'dimensions', coalesce(ext->'dimensions', ext->'specs'->'dimensions'),
    'weight', ext->>'weight',
    'supplier_provider', sup->>'provider', 'supplier_product_id', sup->>'supplier_product_id',
    'source_store', cp.source_store, 'extraction_confidence', v_conf,
    'product_family_key', ext->>'product_family_key'));

  IF v_has_link OR v_strong >= 2 THEN
    v_state := 'IDENTITY_RESOLVED'; v_label := 'Product identity verified';
  ELSIF jsonb_array_length(v_candidates) >= 2 THEN
    v_state := 'IDENTITY_AMBIGUOUS'; v_label := 'Choose the product you want to test';
  ELSE
    v_state := 'CONCEPT_ONLY'; v_label := 'Product concept — specific product required';
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id,
    'identity_state', v_state, 'label', v_label,
    'supplier_link_allowed', (v_state = 'IDENTITY_RESOLVED'),
    'has_supplier_link', v_has_link, 'strong_identifier_count', v_strong,
    'fingerprint', v_fp,
    'candidates', CASE WHEN v_state='IDENTITY_AMBIGUOUS' THEN v_candidates ELSE '[]'::jsonb END,
    'basis', CASE
      WHEN v_has_link THEN 'A concrete supplier product is linked (supplier identity present).'
      WHEN v_strong >= 2 THEN 'Multiple strong concrete identifiers are present.'
      WHEN v_state='IDENTITY_AMBIGUOUS' THEN 'Several materially distinct concrete products match this concept; user selection required.'
      ELSE 'Originated as a demand concept without a defensible concrete product identity (title similarity alone is insufficient).' END,
    'note','Identity evidence is not publication rights; marketplace/reference imagery remains RESEARCH_REFERENCE_ONLY.',
    'checked_at', now());
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_product_identity_badge(p_product_id uuid)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'identity_state', r->>'identity_state', 'label', r->>'label',
    'supplier_link_allowed', (r->>'supplier_link_allowed')::boolean,
    'candidates', coalesce(r->'candidates','[]'::jsonb))
  FROM (SELECT public.fn_product_identity_resolution(p_product_id) AS r) x;
$function$;

CREATE OR REPLACE FUNCTION public.fn_link_candidate_supplier(p_product_id uuid, p_provider text, p_source_product_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_prov text := public.fn_supplier_provider_canon(p_provider);
  v_spid text := btrim(coalesce(p_source_product_id,''));
  v_sup public.commerce_supplier_products%rowtype;
  v_ref jsonb; v_refs jsonb; v_ext jsonb; v_updated int;
  v_identity text; v_user_select text;
BEGIN
  IF v_prov='' OR v_spid='' THEN
    RETURN jsonb_build_object('status','missing_provider_or_source_product_id');
  END IF;

  -- Identity gate: never auto-link a demand concept to a supplier SKU.
  v_identity := public.fn_product_identity_resolution(p_product_id)->>'identity_state';
  v_user_select := current_setting('pulse.identity_user_select', true);
  IF v_identity = 'CONCEPT_ONLY' AND v_user_select IS DISTINCT FROM p_product_id::text THEN
    RETURN jsonb_build_object('status','identity_unresolved_concept_only','identity_state', v_identity,
      'note','This product is a demand concept without a defensible concrete identity. A loose supplier match must not become the product. Resolve identity (user candidate selection) before linking.');
  END IF;

  SELECT * INTO v_sup FROM public.commerce_supplier_products
    WHERE source_product_id=v_spid AND public.fn_supplier_provider_canon(source)=v_prov LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','supplier_row_not_found','provider',v_prov,'source_product_id',v_spid,
      'note','normalize+persist the supplier product (commerce_supplier_products.source=<provider>) before linking');
  END IF;

  SELECT coalesce(extended,'{}'::jsonb) INTO v_ext FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  v_ref := jsonb_build_object('provider',v_prov,'source_product_id',v_spid,'supplier_row_id',v_sup.id,'linked_at',now());
  SELECT coalesce(jsonb_agg(e),'[]'::jsonb) INTO v_refs
    FROM jsonb_array_elements(coalesce(v_ext->'supplier_refs','[]'::jsonb)) e
    WHERE upper(coalesce(e->>'provider','')) <> v_prov;
  v_refs := v_refs || jsonb_build_array(v_ref);

  UPDATE public.commerce_products
    SET extended = coalesce(extended,'{}'::jsonb)
        || jsonb_build_object('supplier_refs', v_refs)
        || jsonb_build_object('supplier_ref', v_ref)
        || CASE WHEN v_prov='CJ' THEN jsonb_build_object('cj_source_product_id', v_spid) ELSE '{}'::jsonb END
    WHERE id=p_product_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated=0 THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  RETURN jsonb_build_object('status','ok','provider',v_prov,'source_product_id',v_spid,
    'linked_product',p_product_id,'supplier_refs',v_refs);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_product_identity_candidate_select(p_product_id uuid, p_provider text, p_source_product_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_link jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  PERFORM set_config('pulse.identity_user_select', p_product_id::text, true);
  v_link := public.fn_link_candidate_supplier(p_product_id, p_provider, p_source_product_id);
  PERFORM set_config('pulse.identity_user_select', '', true);
  IF v_link->>'status' <> 'ok' THEN
    RETURN jsonb_build_object('ok',false,'error', v_link->>'status', 'detail', v_link);
  END IF;
  RETURN jsonb_build_object('ok',true,'status','IDENTITY_RESOLVED','product_id', p_product_id, 'link', v_link,
    'note','User-selected concrete supplier product recorded as the resolved identity. This does NOT grant commercial image rights.');
END; $function$;
