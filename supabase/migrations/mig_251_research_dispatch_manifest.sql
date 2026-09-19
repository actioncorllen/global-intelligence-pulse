-- ============================================================================
-- mig_251_research_dispatch_manifest.sql
-- STRATELOQ-ECOM-DEEP-RESEARCH-AUTO-DISPATCH-013N (server-side dispatch plane)
--
-- The request contract (fn_own_request_product_market_research) created a run +
-- truthful NOT_SEARCHED attempts, but nothing fired the providers — the executors
-- were triggered/repointed by hand. This adds the server-side pieces to
-- auto-dispatch a run to the canonical provider execution boundary (n8n webhook)
-- with ZERO manual intervention. The browser still only sends product_id + market.
--
-- This migration adds:
--  (1) server_integration_config  — RLS deny-all secret store for the executor
--      webhook URL + dispatch secret (server-side only; never browser-reachable).
--  (2) ecommerce_market_universe.dataforseo_location_code — authoritative per-market
--      DataForSEO location code (SEARCH_DEMAND unavailable where NULL).
--  (3) fn_research_run_manifest(run_id) — service_role: everything the executor needs
--      to run applicable providers (product query, market, marketplace id, DFS location,
--      server-derived search seeds, per-source dispatch flags). No credentials.
--
-- The pg_net dispatch function and the fn_own_request auto-call are added in
-- mig_252 once the executor webhook URL exists.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.server_integration_config (
  key text PRIMARY KEY,
  url text,
  secret text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.server_integration_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.server_integration_config FROM anon, authenticated;
-- deny-all to clients: no policy + no grants. Only SECURITY DEFINER functions read it.

ALTER TABLE public.ecommerce_market_universe ADD COLUMN IF NOT EXISTS dataforseo_location_code integer;
-- authoritative DataForSEO country location codes for the main supported markets
UPDATE public.ecommerce_market_universe SET dataforseo_location_code = v.code
FROM (VALUES
  ('GB',2826),('DE',2276),('US',2840),('FR',2250),('IE',2372),('IT',2380),('ES',2724),
  ('NL',2528),('AT',2040),('BE',2056),('CH',2756),('PL',2616),('SE',2752),('AU',2036),
  ('CA',2124),('DK',2208),('FI',2246),('NO',2578),('PT',2620)
) AS v(cc,code)
WHERE public.ecommerce_market_universe.country_code = v.cc
  AND public.ecommerce_market_universe.dataforseo_location_code IS DISTINCT FROM v.code;

CREATE OR REPLACE FUNCTION public.fn_research_run_manifest(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_title text; v_query text; v_loc int; v_seeds text[]; qtok text[]; ttok text[];
  v_dispatch jsonb := '{}'::jsonb; r record;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  SELECT title INTO v_title FROM public.commerce_products WHERE id=v_run.product_id;
  v_query := coalesce(v_run.provenance->>'price_query', v_title);
  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe WHERE country_code=v_run.market;

  -- server-derived search seeds (authoritative; not chosen by the browser): the
  -- query + title + their trailing category-noun suffixes. The 013L classifier grades them.
  qtok := string_to_array(btrim(lower(v_query)),' ');
  ttok := string_to_array(btrim(lower(v_title)),' ');
  v_seeds := ARRAY[btrim(lower(v_query)), btrim(lower(v_title))];
  IF array_length(qtok,1) >= 3 THEN
    v_seeds := v_seeds || array_to_string(qtok[array_length(qtok,1)-2:array_length(qtok,1)],' ');
    v_seeds := v_seeds || array_to_string(qtok[array_length(qtok,1)-1:array_length(qtok,1)],' ');
  END IF;
  IF array_length(ttok,1) >= 2 THEN
    v_seeds := v_seeds || array_to_string(ttok[array_length(ttok,1)-1:array_length(ttok,1)],' ');
  END IF;
  -- dedup + drop empties
  SELECT array_agg(DISTINCT s) INTO v_seeds FROM unnest(v_seeds) s WHERE nullif(btrim(s),'') IS NOT NULL;

  -- per-source dispatch flags from the run's attempt ledger (NOT_SEARCHED = dispatchable now).
  -- REDDIT is community/cross-market -> reuse (not fetched). TikTok stays blocked.
  FOR r IN SELECT evidence_category, source, state FROM public.commerce_research_source_attempt WHERE run_id=p_run_id LOOP
    v_dispatch := v_dispatch || jsonb_build_object(r.source, jsonb_build_object(
      'evidence_category', r.evidence_category, 'state', r.state,
      'action', CASE
        WHEN r.state='NOT_SEARCHED' AND r.evidence_category='COMMUNITY' THEN 'REUSE'
        WHEN r.state='NOT_SEARCHED' AND (r.evidence_category='SEARCH_DEMAND' AND v_loc IS NULL) THEN 'SKIP_NO_LOCATION'
        WHEN r.state='NOT_SEARCHED' THEN 'DISPATCH'
        ELSE 'TERMINAL' END));
  END LOOP;

  RETURN jsonb_build_object('status','ok','run_id',p_run_id,'tenant_id',v_run.tenant_id,
    'product_id',v_run.product_id,'product_title',v_title,'product_query',v_query,
    'market',v_run.market,'market_currency',v_run.provenance->>'market_currency',
    'ebay_marketplace','EBAY_'||v_run.market,'dataforseo_location_code',v_loc,
    'search_seeds',to_jsonb(v_seeds),'dispatch',v_dispatch,
    'contract','pulse_research_manifest_v1_013n');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_run_manifest(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_run_manifest(uuid) TO service_role;
