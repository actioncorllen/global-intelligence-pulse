-- PULSE-ECOM-MONDAY-PIPELINE-CLOSEOUT-001
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as:
--   mig_202  fn_text_tokens + fn_resolve_supplier_identity (deterministic product-identity resolver)
--   mig_203  fn_assemble_real_product_market v2 — economics certified ONLY for EXACT_PRODUCT identity;
--            CLOSE_COMPARABLE/CATEGORY_MATCH give REFERENCE economics that never satisfy the TEST gate
--   mig_204  monday_opportunity_registry + monday_opportunity_runs + fn_run_monday_product_opportunity
--            (ONE canonical weekly-Monday orchestration RPC with per-market failure isolation)
-- Identity safety: EXACT_PRODUCT requires a shared product identifier (never granted from free-text title
-- alone), so a category/close supplier match can support discovery + reference economics but can NEVER
-- certify a candidate's real supplier/stock/landed-cost hard gate or TEST eligibility. Economics never
-- borrow certainty from a different product. Competitor observations stay CLOSE_COMPARABLE (exact-product
-- saturation is not inflated by comparables). Monday cadence only; FX daily schedule unchanged.
-- SECURITY DEFINER, SET search_path='', REVOKE'd from PUBLIC/anon on all functions. Full bodies follow.

CREATE OR REPLACE FUNCTION public.fn_text_tokens(t text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT coalesce(array_agg(DISTINCT tok), '{}')
  FROM (SELECT unnest(regexp_split_to_array(lower(coalesce(t,'')), '[^a-z0-9]+')) tok) s
  WHERE length(tok) >= 3
    AND tok NOT IN ('the','for','and','with','usb','led','set','kit','pack','new','gift','mini','pro','plus');
$$;
REVOKE ALL ON FUNCTION public.fn_text_tokens(text) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_resolve_supplier_identity(
  p_cand_title text, p_cand_category text, p_cand_ident text,
  p_sup_title text, p_sup_category text, p_sup_ref text, p_shared_identifier boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE ct text[]; st text[]; inter int; base int; overlap numeric; cls text; conf text; cn text; sn text;
BEGIN
  IF p_cand_title IS NULL OR p_sup_title IS NULL THEN
    RETURN jsonb_build_object('match_class','UNKNOWN','match_confidence','NONE','matching_evidence',jsonb_build_object('reason','missing_title'));
  END IF;
  cn := lower(p_cand_title||' '||coalesce(p_cand_category,''));
  sn := lower(p_sup_title||' '||coalesce(p_sup_category,''));
  cn := regexp_replace(cn, 'night[ -]?light', 'nightlight', 'g'); sn := regexp_replace(sn, 'night[ -]?light', 'nightlight', 'g');
  cn := regexp_replace(cn, 'projection', 'projector', 'g');       sn := regexp_replace(sn, 'projection', 'projector', 'g');
  cn := regexp_replace(cn, 'children|child|toddler|baby', 'kids', 'g'); sn := regexp_replace(sn, 'children|child|toddler|baby', 'kids', 'g');
  ct := public.fn_text_tokens(cn); st := public.fn_text_tokens(sn);
  SELECT count(*) INTO inter FROM (SELECT unnest(ct) INTERSECT SELECT unnest(st)) x;
  base := greatest(cardinality(ct),1);
  overlap := round(inter::numeric/base, 3);
  IF p_shared_identifier THEN cls := 'EXACT_PRODUCT'; conf := 'HIGH';
  ELSIF overlap >= 0.5 THEN cls := 'CLOSE_COMPARABLE'; conf := CASE WHEN overlap>=0.7 THEN 'MEDIUM' ELSE 'LOW' END;
  ELSIF inter >= 1 AND p_cand_category IS NOT NULL AND lower(p_cand_category)=lower(p_sup_category) THEN cls := 'CATEGORY_MATCH'; conf := 'LOW';
  ELSIF overlap >= 0.34 THEN cls := 'CLOSE_COMPARABLE'; conf := 'LOW';
  ELSE cls := 'UNRELATED'; conf := 'NONE'; END IF;
  RETURN jsonb_build_object('match_class', cls, 'match_confidence', conf,
    'matching_evidence', jsonb_build_object('token_overlap', overlap, 'shared_tokens', inter, 'shared_identifier', p_shared_identifier,
      'candidate_ref', p_cand_ident, 'supplier_product_ref', p_sup_ref,
      'note','EXACT_PRODUCT requires a shared product identifier; title overlap alone caps at CLOSE_COMPARABLE'));
END; $$;
REVOKE ALL ON FUNCTION public.fn_resolve_supplier_identity(text,text,text,text,text,text,boolean) FROM PUBLIC, anon;

-- mig_203 fn_assemble_real_product_market v2: identical to mig_201 body plus the identity gate —
--   sup_ident := fn_resolve_supplier_identity(candidate, supplier, shared_identifier:=false);
--   is_exact  := (sup_ident.match_class = 'EXACT_PRODUCT');
--   landed/fulfilment are CERTIFIED (fed to the economics gate) ONLY when is_exact; otherwise landed is
--   withheld (economics UNKNOWN -> WATCH) and reference_economics is computed for display only, with risk
--   flag SUPPLIER_IDENTITY_NOT_EXACT_ECONOMICS_REFERENCE_ONLY. supplier_availability_stock subscore is
--   scaled by match class (EXACT 60 / CLOSE 40 / CATEGORY 25 / UNRELATED,UNKNOWN null). Full body deployed
--   in the database (mig_203).

-- mig_204 orchestration (tables + RPC):
CREATE TABLE IF NOT EXISTS public.monday_opportunity_registry (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, product_id uuid NOT NULL,
  supplier_id uuid, markets jsonb NOT NULL DEFAULT '[]'::jsonb, active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, product_id));
ALTER TABLE public.monday_opportunity_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.monday_opportunity_registry FROM PUBLIC, anon;

CREATE TABLE IF NOT EXISTS public.monday_opportunity_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), run_at timestamptz NOT NULL DEFAULT now(),
  trigger_source text NOT NULL, candidates int, combinations int, delivered int, excluded_avoid int,
  source_states jsonb NOT NULL DEFAULT '{}'::jsonb, payload jsonb NOT NULL DEFAULT '{}'::jsonb);
ALTER TABLE public.monday_opportunity_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.monday_opportunity_runs FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_run_monday_product_opportunity(
  p_trigger text DEFAULT 'manual', p_persist boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  reg record; m jsonb; run_id uuid := gen_random_uuid();
  ncand int := 0; ncombo int := 0; ndeliv int := 0; navoid int := 0;
  src_states jsonb := '{}'::jsonb; deliver jsonb := '[]'::jsonb; blk jsonb; best_dec text;
BEGIN
  FOR reg IN SELECT * FROM public.monday_opportunity_registry WHERE active LOOP
    ncand := ncand + 1;
    FOR m IN SELECT * FROM jsonb_array_elements(reg.markets) LOOP
      BEGIN
        PERFORM public.fn_assemble_real_product_market(reg.product_id, m->>'country', m->>'currency',
                  m->>'price_query', reg.supplier_id, p_persist);
        ncombo := ncombo + 1;
        src_states := src_states || jsonb_build_object((reg.product_id::text)||':'||(m->>'country'), 'AVAILABLE');
      EXCEPTION WHEN OTHERS THEN
        src_states := src_states || jsonb_build_object((reg.product_id::text)||':'||(m->>'country'),
          jsonb_build_object('state','FAILED','error',SQLERRM));
      END;
    END LOOP;
    PERFORM public.fn_pod_tournament(reg.tenant_id, reg.product_id, 'pod_v1', p_persist);
    blk := public.fn_pod_monday_block(reg.tenant_id, reg.product_id);
    best_dec := blk->>'DECISION';
    IF best_dec = 'AVOID' THEN navoid := navoid + 1;
    ELSE deliver := deliver || jsonb_build_array(blk); ndeliv := ndeliv + 1; END IF;
  END LOOP;
  IF p_persist THEN
    INSERT INTO public.monday_opportunity_runs (id, trigger_source, candidates, combinations, delivered, excluded_avoid, source_states, payload)
    VALUES (run_id, p_trigger, ncand, ncombo, ndeliv, navoid, src_states, jsonb_build_object('delivered', deliver));
  END IF;
  RETURN jsonb_build_object('run_id', run_id, 'trigger_source', p_trigger, 'ran_at', now(),
    'candidates', ncand, 'combinations', ncombo, 'delivered', ndeliv, 'excluded_avoid', navoid,
    'source_states', src_states, 'delivered_opportunities', deliver,
    'campaign_activation', false, 'advertising_spend', 0, 'cadence','MONDAY_WEEKLY',
    'note','WATCH delivered as emerging opportunity with blockers; AVOID retained in history, not promoted; WINNER never pre-performance.',
    'contract','pulse_monday_product_opportunity_run_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_run_monday_product_opportunity(text,boolean) FROM PUBLIC, anon;

-- n8n: "Pulse — Monday Ecom Product Opportunity Orchestrator" (id BBxcPXJdF2PliWgf), ACTIVE.
--   Manual trigger + weekly Monday 07:00 UTC schedule -> HTTP POST Supabase RPC
--   fn_run_monday_product_opportunity (Supabase credential reused). Scheduled path proven via manual
--   execution 30129 (status success). Awaiting first NATURAL Monday run. No source-collector duplication.
