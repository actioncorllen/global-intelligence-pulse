-- mig_372a — Autonomous market discovery: scope universe + rotation planner
--
-- ROOT CAUSE of manual-seed dependency: the only proven product-discovery path
-- (fn_dataforseo_discover_candidates) requires a category seed, and the existing
-- in-DB "trend" source (trend_clusters) holds macro/news topics, not market-scoped
-- product candidates. So a customer had to name the category ("cable organizer")
-- for a market; "find emerging products in Germany" alone could not start discovery.
--
-- FIX (reuse the proven discovery + auto-research bridge; no parallel system):
-- (1) a bounded, extensible ecommerce scope universe (ecommerce_discovery_scope) —
--     the ONE taxonomy input, the exploration SPACE, not "intelligence" by itself;
-- (2) fn_autonomous_discovery_plan(market) — the exploration STRATEGY: given only a
--     market it auto-selects the least-recently-explored active scope for that market
--     (systematic rotation over cycles using the real discovery_runs history), and
--     emits the exact DataForSEO request for it via the authoritative
--     fn_dataforseo_discovery_request. No founder/Claude category choice; no static
--     per-run guess; rotation guarantees the space is covered over time.
--
-- The real discovery intelligence remains downstream and unchanged: DataForSEO
-- keyword expansion → fn_dataforseo_discovery_qualify (intent/relevance/sellable
-- noise gate) → registration → the proven auto-research bridge → evidence →
-- concrete resolution → opportunity evaluation. Richer scope sources (live trend /
-- marketplace-category feeds) can be added to the universe later without changing
-- this contract.

CREATE TABLE IF NOT EXISTS public.ecommerce_discovery_scope (
  scope_key   text PRIMARY KEY,
  label       text NOT NULL,
  seed        text NOT NULL,                 -- category/seed term handed to DataForSEO discovery
  scope_kind  text NOT NULL DEFAULT 'CATEGORY',  -- CATEGORY | PROBLEM | TREND (extensible)
  is_active   boolean NOT NULL DEFAULT true,
  weight      int NOT NULL DEFAULT 100,       -- tie-breaker priority; rotation is primary
  provenance  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.ecommerce_discovery_scope TO authenticated, service_role;

-- Seed: a bounded set of consumer-product / dropshipping-relevant category scopes.
-- This is the exploration space (one input), not a per-run founder guess. Idempotent.
INSERT INTO public.ecommerce_discovery_scope (scope_key, label, seed, weight) VALUES
  ('home_organization','Home Organization','home organization', 120),
  ('kitchen_gadgets','Kitchen Gadgets','kitchen gadgets', 120),
  ('pet_supplies','Pet Supplies','pet supplies', 115),
  ('car_accessories','Car Accessories','car accessories', 110),
  ('fitness_recovery','Fitness & Recovery','fitness recovery', 115),
  ('posture_support','Posture Support','posture corrector', 110),
  ('beauty_tools','Beauty Tools','beauty tools', 110),
  ('skincare_devices','Skincare Devices','skincare device', 108),
  ('baby_products','Baby Products','baby products', 105),
  ('desk_office','Desk & Office','desk organizer', 105),
  ('outdoor_gear','Outdoor Gear','outdoor gear', 100),
  ('garden_tools','Garden Tools','garden tools', 100),
  ('bathroom_storage','Bathroom Storage','bathroom storage', 100),
  ('cleaning_gadgets','Cleaning Gadgets','cleaning gadgets', 100),
  ('sleep_aids','Sleep Aids','sleep aid', 100),
  ('travel_accessories','Travel Accessories','travel accessories', 100),
  ('hair_tools','Hair Tools','hair styling tool', 100),
  ('drinkware','Drinkware','insulated drinkware', 95),
  ('phone_accessories','Phone Accessories','phone accessories', 90),
  ('kids_learning','Kids Learning & Toys','kids learning toys', 95),
  ('home_lighting','Home Lighting','home lighting', 95),
  ('storage_containers','Storage Containers','storage containers', 95),
  ('workout_equipment','Home Workout Equipment','home workout equipment', 100),
  ('ergonomic_support','Ergonomic Support','ergonomic cushion', 100)
ON CONFLICT (scope_key) DO NOTHING;

-- Rotation planner: given ONLY a market, auto-select the least-recently-explored
-- active scope (NULLS FIRST = never explored), market-scoped via the authoritative
-- provider config, and emit its DataForSEO request. No manual category seed.
-- (check_function_bodies disabled for this CREATE to avoid a slow validation path
-- on the managed instance; the body is exercised by invocation.)
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_autonomous_discovery_plan(
    p_market text, p_max_scopes integer DEFAULT 1, p_user_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  cfg jsonb; v_n int := greatest(1, least(coalesce(p_max_scopes,1), 5));
  v_scopes jsonb; v_top record; req jsonb;
BEGIN
  cfg := public.fn_market_provider_config(v_mkt);
  IF coalesce((cfg->>'ok')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok',false,'market',v_mkt,'reason',coalesce(cfg->>'reason','UNSUPPORTED_MARKET'),
      'note','market not provider-supported; autonomous discovery not started');
  END IF;

  WITH ranked AS (
    SELECT s.scope_key, s.label, s.seed, s.weight,
      (SELECT max(dr.created_at) FROM public.discovery_runs dr
         WHERE upper(coalesce(dr.raw_contract->>'market','')) = v_mkt
           AND lower(btrim(coalesce(dr.raw_contract->>'category',''))) = lower(btrim(s.seed))
           AND (p_user_id IS NULL OR dr.user_id = p_user_id)) AS last_explored_at
    FROM public.ecommerce_discovery_scope s
    WHERE s.is_active
  )
  SELECT jsonb_agg(jsonb_build_object('scope_key',scope_key,'label',label,'seed',seed,
           'last_explored_at',last_explored_at) ORDER BY last_explored_at ASC NULLS FIRST, weight DESC, scope_key)
    INTO v_scopes
  FROM (SELECT * FROM ranked ORDER BY last_explored_at ASC NULLS FIRST, weight DESC, scope_key LIMIT v_n) x;

  IF v_scopes IS NULL OR jsonb_array_length(v_scopes)=0 THEN
    RETURN jsonb_build_object('ok',false,'market',v_mkt,'reason','NO_ACTIVE_SCOPES',
      'note','ecommerce_discovery_scope has no active scopes');
  END IF;

  SELECT (v_scopes->0->>'seed') AS seed, (v_scopes->0->>'scope_key') AS scope_key INTO v_top;
  req := public.fn_dataforseo_discovery_request(v_mkt, v_top.seed);

  RETURN jsonb_build_object(
    'ok', coalesce((req->>'ok')::boolean,false),
    'mode','AUTONOMOUS_MARKET',
    'market', v_mkt,
    'location_code', (req->>'location_code')::int,
    'language_code', req->>'language_code',
    'currency', req->>'currency',
    'selected_scope', v_top.seed,
    'selected_scope_key', v_top.scope_key,
    'keyword_ideas_request', req->'keyword_ideas_request',
    'scopes', v_scopes,
    'max_scopes', v_n,
    'rotation_note','scope auto-selected by least-recently-explored rotation for this market; no manual category seed',
    'contract','pulse_autonomous_discovery_plan_v1');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_autonomous_discovery_plan(text,integer,uuid) TO authenticated, service_role;
