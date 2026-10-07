-- mig_367 — Stage 2 bridge: OPPORTUNITY CONCEPT -> CONCRETE PRODUCT -> EXACT CJ SKU
--
-- ROOT CAUSE: the pipeline had no concrete-product-resolution step between a generic
-- opportunity concept (a DataForSEO keyword, e.g. "cool mist humidifier") and a CJ
-- supplier SKU. fn_resolve_supplier_identity correctly refuses to call a generic concept
-- EXACT_PRODUCT (needs a shared identifier), so nothing could ever bind — and that is right:
-- a keyword is not a product.
--
-- FIX (smallest production-safe bridge, reusing existing Product Identity Resolution):
--   opportunity concept
--     -> fn_derive_concrete_product_identity  (concrete product from OBSERVED market evidence)
--     -> fn_resolve_concrete_supplier_identity (attribute comparison via fn_market_supplier_match;
--                                               bind one clear CJ SKU, else fail closed)
--     -> fn_validate_bound_supplier_identity   (after binding, the CJ id IS a shared identifier,
--                                               so EXACT_PRODUCT is reachable WITHOUT weakening anything)
--
-- Identity lifecycle (founder model): a CJ product becomes authoritative supplier identity only
-- when (A) the opportunity is first resolved to a concrete product, (B) the CJ listing matches that
-- concrete product across distinguishing attributes, (C) no contradictory evidence, (D) Strateloq
-- explicitly BINDS the CJ id/SKU. The binding creates the durable shared identifier; EXACT is never
-- produced by reclassifying a CLOSE_COMPARABLE keyword match.
--
-- Provenance keeps the two claims separate: "opportunity resolved to concrete product X" and
-- "concrete product X supplied by CJ product Y" — never "DataForSEO concept = CJ SKU".

-- ---------------------------------------------------------------------------
-- 1. Durable resolution + binding record
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commerce_concrete_supplier_resolution (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  opportunity_product_id uuid NOT NULL,          -- #1 opportunity concept
  market text NOT NULL,
  concrete_identity jsonb NOT NULL,              -- #2 concrete product identity (from evidence)
  concrete_state text NOT NULL,                  -- CONCRETE_RESOLVED | CONCRETE_PRODUCT_AMBIGUOUS | NO_CONCRETE_EVIDENCE
  match_spec jsonb NOT NULL,                     -- spec fed to fn_market_supplier_match
  candidates_considered jsonb NOT NULL DEFAULT '[]'::jsonb,
  selected_supplier text,                        -- #3 supplier product
  selected_supplier_product_id text,
  selected_sku text,
  selected_variant jsonb,
  supplier_match_evidence jsonb,
  contradictory_evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
  identity_result text NOT NULL,                 -- EXACT_SUPPLIER_IDENTITY_RESOLVED | CONCRETE_PRODUCT_AMBIGUOUS | NO_VALID_CJ_MATCH
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb, -- the two-step chain
  bound boolean NOT NULL DEFAULT false,
  bound_at timestamptz,
  is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, opportunity_product_id, market)
);

ALTER TABLE public.commerce_concrete_supplier_resolution ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ccsr_tenant_read ON public.commerce_concrete_supplier_resolution;
CREATE POLICY ccsr_tenant_read ON public.commerce_concrete_supplier_resolution
  FOR SELECT TO authenticated USING (tenant_id = auth.uid());
GRANT SELECT ON public.commerce_concrete_supplier_resolution TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Concrete product identity from OBSERVED, country-isolated market evidence
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_derive_concrete_product_identity(
  p_tenant uuid, p_product_id uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(coalesce(p_market,''));
  cp record; v_total int; v_noun text[]; v_subs text[]; v_attrs text[]; v_excl text[];
  v_dom_form text; v_dom_support numeric; v_state text; v_fp text; v_samples jsonb;
BEGIN
  SELECT title, category, product_identity INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;

  -- product noun(s): opportunity title tokens that are not subtype/attr descriptors
  v_noun := ARRAY(SELECT tok FROM unnest(public.fn_text_tokens(lower(cp.title))) tok
                  WHERE tok NOT IN ('cool','mist','warm','ultrasonic','red','light','therapy','led',
                                    'digital','picture','photo','frame') AND length(tok)>2);
  IF cardinality(v_noun)=0 THEN v_noun := public.fn_text_tokens(lower(cp.title)); END IF;

  -- evidence-driven support over a discriminator lexicon (forms, alternate forms, attributes),
  -- computed from OBSERVED market-isolated eBay listing titles only (no invention, no cross-market).
  WITH t AS (
    SELECT regexp_replace(lower(coalesce(value->>'title','')),'night[ -]?light','nightlight','g') AS ttl
    FROM public.commerce_signals
    WHERE product_id=p_product_id AND signal_type='MARKETPLACE_ACTIVITY'
      AND upper(coalesce(value->>'market',''))=v_mkt AND coalesce(value->>'title','')<>''
  ),
  tot AS (SELECT count(*) AS n FROM t),
  lex(term,kind) AS (VALUES
      ('ultrasonic','form'),('cool mist','form'),('warm mist','altform'),('evaporative','altform'),
      ('rain cloud','altform'),('raindrop','altform'),('flame','altform'),('ufo','altform'),('volcano','altform'),
      ('red light','form'),('infrared','form'),('photon','attr'),('near infrared','attr'),('7 color','attr'),
      ('digital','form'),('wifi','attr'),('touchscreen','attr'),('calendar','attr'),('alarm clock','attr'),('wooden','altform'),
      ('nightlight','attr'),('quiet','attr'),('aromatherapy','attr'),('essential oil','attr'),
      ('bedroom','attr'),('baby','attr'),('portable','attr'),('handheld','altform'),('rechargeable','attr')),
  sup AS (
    SELECT l.term, l.kind,
      round((SELECT count(*) FROM t WHERE position(l.term in t.ttl)>0)::numeric
            / greatest((SELECT n FROM tot),1), 3) AS support
    FROM lex l)
  SELECT
    (SELECT n FROM tot),
    ARRAY(SELECT term FROM sup WHERE kind='form'    AND support>=0.30 ORDER BY support DESC),
    ARRAY(SELECT term FROM sup WHERE kind='attr'    AND support>=0.30 ORDER BY support DESC),
    ARRAY(SELECT term FROM sup WHERE kind='altform' AND support< 0.08 ORDER BY term),
    (SELECT term FROM sup WHERE kind='form' ORDER BY support DESC LIMIT 1),
    (SELECT coalesce(max(support),0) FROM sup WHERE kind='form'),
    (SELECT coalesce(jsonb_agg(x.ttl),'[]'::jsonb) FROM (SELECT ttl FROM t LIMIT 6) x)
  INTO v_total, v_subs, v_attrs, v_excl, v_dom_form, v_dom_support, v_samples;

  v_state := CASE
    WHEN v_total < 5 THEN 'NO_CONCRETE_EVIDENCE'
    WHEN coalesce(v_dom_support,0) >= 0.30 OR cardinality(v_subs) >= 1 THEN 'CONCRETE_RESOLVED'
    ELSE 'CONCRETE_PRODUCT_AMBIGUOUS' END;

  v_fp := md5(lower(array_to_string(v_noun,' ')||'|'||array_to_string(coalesce(v_subs,'{}'),',')
              ||'|'||array_to_string(coalesce(v_attrs,'{}'),',')));

  RETURN jsonb_build_object(
    'ok', true,
    'concrete_state', v_state,
    'concrete_identity', jsonb_build_object(
      'canonical_name', cp.title, 'category', cp.category,
      'subtype', coalesce(v_subs, ARRAY[]::text[]),
      'distinguishing_attributes', coalesce(v_attrs, ARRAY[]::text[]),
      'variant_attributes', ARRAY[]::text[],
      'evidence_sources', jsonb_build_object('marketplace_listing_titles', v_total,
         'source','EBAY_BROWSE','market',v_mkt,'sample_titles',v_samples),
      'identity_fingerprint', v_fp),
    'match_spec', jsonb_build_object(
      'product_noun', to_jsonb(v_noun),
      'required_subtype_any', to_jsonb(coalesce(v_subs, ARRAY[]::text[])),
      'required_attr_all', '[]'::jsonb,
      'excluded_subtype', to_jsonb(coalesce(v_excl, ARRAY[]::text[])),
      'category', cp.category));
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_derive_concrete_product_identity(uuid,uuid,text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Resolver: compare CJ candidates by ATTRIBUTES, bind one clear SKU or fail closed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_concrete_supplier_identity(
  p_tenant uuid, p_product_id uuid, p_market text,
  p_candidates jsonb DEFAULT NULL, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_state text; cp record;
  c jsonb; m jsonb; cls text; attrs_ok boolean; excl_hit boolean;
  v_considered jsonb := '[]'::jsonb; v_contra jsonb := '[]'::jsonb; v_qualify jsonb := '[]'::jsonb;
  v_result text; v_sel jsonb; v_prov jsonb; v_qn int;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT title, category INTO cp FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false')<>'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_state := v_der->>'concrete_state';

  IF v_state = 'NO_CONCRETE_EVIDENCE' THEN
    v_result := 'NO_VALID_CJ_MATCH';
  ELSE
    -- candidate pool: provided (e.g. live CJ search) else the connected CJ cache filtered to the noun
    IF p_candidates IS NULL THEN
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'supplier','CJDROPSHIPPING','supplier_product_id',sp.source_product_id,'sku',sp.sku,
               'title',sp.title,'category',sp.category,'variant',null)),'[]'::jsonb)
        INTO p_candidates
      FROM public.commerce_supplier_products sp
      WHERE sp.source ILIKE 'cj%'
        AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_spec->'product_noun') n
                    WHERE position(lower(n.value) in lower(sp.title))>0)
      LIMIT 40;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) LOOP
      m := public.fn_market_supplier_match(v_spec, c->>'title', c->>'category', c->>'supplier_product_id', false);
      cls := m->>'market_supplier_match';
      attrs_ok := coalesce((m->'evidence'->>'attrs_ok')::boolean, false);
      excl_hit := coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean, false);
      v_considered := v_considered || jsonb_build_array(jsonb_build_object(
        'supplier_product_id', c->>'supplier_product_id','title',c->>'title',
        'match_class', cls, 'attrs_ok', attrs_ok, 'excluded_subtype_hit', excl_hit,
        'evidence', m->'evidence'));
      IF excl_hit THEN
        v_contra := v_contra || jsonb_build_array(jsonb_build_object(
          'supplier_product_id', c->>'supplier_product_id','title',c->>'title','reason','EXCLUDED_SUBTYPE_PRESENT'));
      ELSIF cls IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED') AND attrs_ok THEN
        v_qualify := v_qualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
      END IF;
    END LOOP;

    v_qn := jsonb_array_length(v_qualify);
    IF v_qn = 0 THEN
      v_result := 'NO_VALID_CJ_MATCH';
    ELSIF v_qn = 1 THEN
      v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED';
      v_sel := v_qualify->0;
    ELSE
      -- multiple materially-different concrete products satisfy the concept -> fail closed
      v_result := 'CONCRETE_PRODUCT_AMBIGUOUS';
    END IF;
  END IF;

  v_prov := jsonb_build_object(
    'step1_opportunity_to_concrete', jsonb_build_object(
      'opportunity_concept', cp.title, 'market', upper(p_market),
      'concrete_state', v_state, 'concrete_identity', v_der->'concrete_identity',
      'claim','Market opportunity resolved to a concrete product from observed marketplace evidence.'),
    'step2_concrete_to_supplier', CASE WHEN v_sel IS NOT NULL THEN jsonb_build_object(
      'supplier','CJDROPSHIPPING','cj_product_id', v_sel->>'supplier_product_id',
      'match_class', v_sel->>'match_class',
      'claim','Concrete product is supplied by this CJ product (attribute match, explicitly bound).') ELSE NULL END,
    'identity_separation_note','This is NOT a claim that the DataForSEO concept equals a CJ SKU; the concept was first resolved to a concrete product, then a CJ product was bound to supply that concrete product.');

  IF p_persist THEN
    INSERT INTO public.commerce_concrete_supplier_resolution AS t (
      tenant_id, opportunity_product_id, market, concrete_identity, concrete_state, match_spec,
      candidates_considered, selected_supplier, selected_supplier_product_id, selected_sku, selected_variant,
      supplier_match_evidence, contradictory_evidence, identity_result, provenance, bound, bound_at)
    VALUES (p_tenant, p_product_id, upper(p_market), v_der->'concrete_identity', v_state, v_spec,
      v_considered, CASE WHEN v_sel IS NOT NULL THEN 'CJDROPSHIPPING' END,
      v_sel->>'supplier_product_id', v_sel->>'sku', v_sel->'variant',
      v_sel->'match_evidence', v_contra, v_result, v_prov,
      (v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),
      CASE WHEN v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED' THEN now() END)
    ON CONFLICT (tenant_id, opportunity_product_id, market) DO UPDATE SET
      concrete_identity=excluded.concrete_identity, concrete_state=excluded.concrete_state,
      match_spec=excluded.match_spec, candidates_considered=excluded.candidates_considered,
      selected_supplier=excluded.selected_supplier, selected_supplier_product_id=excluded.selected_supplier_product_id,
      selected_sku=excluded.selected_sku, selected_variant=excluded.selected_variant,
      supplier_match_evidence=excluded.supplier_match_evidence, contradictory_evidence=excluded.contradictory_evidence,
      identity_result=excluded.identity_result, provenance=excluded.provenance,
      bound=excluded.bound, bound_at=excluded.bound_at, created_at=now();
  END IF;

  RETURN jsonb_build_object('ok',true,'opportunity_product_id',p_product_id,'market',upper(p_market),
    'concrete_state',v_state,'concrete_identity',v_der->'concrete_identity','match_spec',v_spec,
    'candidates_considered',v_considered,'contradictory_evidence',v_contra,
    'qualifying_count',coalesce(v_qn,0),'identity_result',v_result,
    'selected_supplier_product_id', v_sel->>'supplier_product_id','selected_sku', v_sel->>'sku',
    'bound',(v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),'provenance',v_prov);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_resolve_concrete_supplier_identity(uuid,uuid,text,jsonb,boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. After binding, the CJ id IS a shared identifier -> EXACT_PRODUCT validates
--    (this is how exactness is reached legitimately; the matcher is NOT weakened)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validate_bound_supplier_identity(
  p_tenant uuid, p_product_id uuid, p_market text, p_supplier_product_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r record; v_shared boolean; v_id jsonb;
BEGIN
  SELECT * INTO r FROM public.commerce_concrete_supplier_resolution
    WHERE tenant_id=p_tenant AND opportunity_product_id=p_product_id AND market=upper(p_market);
  IF NOT FOUND OR NOT r.bound THEN
    RETURN jsonb_build_object('validated',false,'reason','NO_BOUND_IDENTITY');
  END IF;
  v_shared := (r.selected_supplier_product_id IS NOT NULL
               AND r.selected_supplier_product_id = p_supplier_product_id);
  -- shared identifier now exists because Strateloq bound it; EXACT is reachable without loosening tokens
  v_id := public.fn_resolve_supplier_identity(
            (r.concrete_identity->>'canonical_name'), (r.concrete_identity->>'category'), NULL,
            r.selected_supplier_product_id, (r.concrete_identity->>'category'),
            r.selected_supplier_product_id, v_shared);
  RETURN jsonb_build_object('validated', v_shared,
    'match_class', v_id->>'match_class',
    'bound_supplier_product_id', r.selected_supplier_product_id,
    'reason', CASE WHEN v_shared THEN 'SHARED_IDENTIFIER_FROM_BINDING' ELSE 'SUPPLIER_PRODUCT_ID_MISMATCH' END);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_validate_bound_supplier_identity(uuid,uuid,text,text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Reader for Product Asset Lock to reference the bound supplier identity
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_bound_supplier_identity(
  p_tenant uuid, p_product_id uuid, p_market text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE WHEN r.bound THEN jsonb_build_object(
      'has_bound_supplier', true, 'supplier', r.selected_supplier,
      'supplier_product_id', r.selected_supplier_product_id, 'sku', r.selected_sku,
      'variant', r.selected_variant, 'bound_at', r.bound_at,
      'concrete_identity_fingerprint', r.concrete_identity->>'identity_fingerprint')
    ELSE jsonb_build_object('has_bound_supplier', false, 'identity_result', r.identity_result) END
  FROM public.commerce_concrete_supplier_resolution r
  WHERE r.tenant_id=p_tenant AND r.opportunity_product_id=p_product_id AND r.market=upper(p_market);
$function$;

GRANT EXECUTE ON FUNCTION public.fn_product_bound_supplier_identity(uuid,uuid,text) TO authenticated, service_role;
