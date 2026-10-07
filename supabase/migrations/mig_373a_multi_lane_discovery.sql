-- mig_373a — Multi-lane, product-native-aware discovery (WinningHunter-inspired, Strateloq-native)
--
-- Evolves market-only discovery from a single broad keyword scope toward bounded
-- multi-lane candidate discovery that reuses the proven search lane + auto-research
-- bridge. No parallel system; no new paid providers; WinningHunter NOT connected.
--
-- Capability audit result (authoritative, from provider_capability_registry):
--   PRODUCT_NATIVE_DISCOVERY_PROVIDER_GAP = YES. No connected provider returns
--   market product entities without a seed — DataForSEO is keyword-derived; eBay
--   Browse is implemented RESEARCH_ONLY; Meta/TikTok ad libraries are query-seeded
--   ad records; TikTok organic Research API is EXTERNAL_APPROVAL_REQUIRED; CJ is
--   supplier-only. WinningHunter = POTENTIAL_EXTERNAL_DISCOVERY_PROVIDER (evaluation
--   only). The only live autonomous discovery lane is SEARCH (DataForSEO).

-- 1. Lane registry — honest capability classification per lane.
CREATE TABLE IF NOT EXISTS public.discovery_lane_registry (
  lane_key        text PRIMARY KEY,
  label           text NOT NULL,
  provider        text NOT NULL,
  capability_class text NOT NULL,   -- DISCOVERY_CAPABLE | RESEARCH_ONLY | SUPPLIER_ONLY | REFERENCE_ONLY | UNAVAILABLE
  discovery_mode  text NOT NULL,    -- AUTONOMOUS | SEEDED | NONE
  availability    text NOT NULL,    -- AVAILABLE | SEEDED_AVAILABLE | RESEARCH_ONLY | BLOCKED_EXTERNAL_APPROVAL | PRODUCT_NATIVE_GAP | UNAVAILABLE
  is_active       boolean NOT NULL DEFAULT true,
  note            text,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.discovery_lane_registry TO authenticated, service_role;

INSERT INTO public.discovery_lane_registry (lane_key,label,provider,capability_class,discovery_mode,availability,note) VALUES
 ('SEARCH','Search-Demand Discovery','DATAFORSEO','DISCOVERY_CAPABLE','AUTONOMOUS','AVAILABLE',
   'Keyword-derived candidate discovery via autonomous scope planner; live. Keyword volume is a signal, never a winner definition.'),
 ('COMMERCE','Commerce Product Discovery','(none-connected)','UNAVAILABLE','NONE','PRODUCT_NATIVE_GAP',
   'No connected provider returns market product entities without a seed. eBay Browse is implemented RESEARCH_ONLY (queried by product name); category-browse discovery not implemented. WinningHunter = potential external, NOT connected.'),
 ('SOCIAL','Social Product Momentum','TIKTOK','RESEARCH_ONLY','NONE','BLOCKED_EXTERNAL_APPROVAL',
   'TikTok organic Research API (video/creator/product graph) is EXTERNAL_APPROVAL_REQUIRED, not connected. TikTok Commercial Ad Library is connected but ad-record-level + query-seeded (validation), not autonomous product discovery.'),
 ('ADVERTISING','Advertising Emergence','META_AD_LIBRARY','RESEARCH_ONLY','SEEDED','RESEARCH_ONLY',
   'Meta/TikTok ad libraries are queried by term and return ads, not product entities; usable to validate advertising emergence of a named/seeded candidate, not to autonomously enumerate market products.'),
 ('PROBLEM','Problem / Need Discovery','DATAFORSEO+REDDIT','DISCOVERY_CAPABLE','SEEDED','SEEDED_AVAILABLE',
   'Problem-discovery subsystem exists (fn_request_problem_discovery, DataForSEO+Reddit) but requires market+category/problem seed; can be auto-seeded from the scope planner in a later unit.')
ON CONFLICT (lane_key) DO UPDATE SET
  provider=excluded.provider, capability_class=excluded.capability_class, discovery_mode=excluded.discovery_mode,
  availability=excluded.availability, note=excluded.note, updated_at=now();

-- 2. Scope-quality refinement: narrower product-type seeds (higher weight) so rotation
--    prefers them among never-explored scopes. Broad seeds retained. Idempotent.
INSERT INTO public.ecommerce_discovery_scope (scope_key,label,seed,weight) VALUES
 ('shoe_storage','Shoe Storage Organizer','shoe storage organizer',200),
 ('resistance_bands','Resistance Band Set','resistance band set',200),
 ('neck_massager','Neck Massager','neck massager',200),
 ('car_phone_mount','Car Phone Mount','car phone mount',200),
 ('led_strip_lights','LED Strip Lights','led strip lights',195),
 ('pet_hair_remover','Pet Hair Remover','pet hair remover',200),
 ('standing_desk_converter','Standing Desk Converter','standing desk converter',195),
 ('blackhead_remover','Blackhead Remover','blackhead remover vacuum',195),
 ('reusable_food_wrap','Reusable Food Wrap','reusable food wrap',190),
 ('cable_management_box','Cable Management Box','cable management box',190)
ON CONFLICT (scope_key) DO NOTHING;

-- 3. Normalized discovery-signal contract. UNKNOWN fields stay NULL (never 0);
--    metrics market-scoped; cross_market_reference is never local validation.
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.fn_discovery_signal_normalize(
    p_lane text, p_source text, p_market text, p_raw jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE r jsonb := coalesce(p_raw,'{}'::jsonb);
BEGIN
  RETURN jsonb_build_object(
    'lane', upper(btrim(coalesce(p_lane,''))), 'source', p_source, 'market', upper(btrim(coalesce(p_market,''))),
    'product_identity', nullif(btrim(coalesce(r->>'product_identity', r->>'title','')),''),
    'first_seen', nullif(btrim(coalesce(r->>'first_seen','')),''),
    'maturity_state', nullif(btrim(coalesce(r->>'maturity_state','')),''),
    'cross_market_reference', coalesce((r->>'cross_market_reference')::boolean, false),
    'sales_units', CASE WHEN (r->>'sales_units') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'sales_units')::numeric END,
    'sales_velocity', CASE WHEN (r->>'sales_velocity') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'sales_velocity')::numeric END,
    'sales_growth_rate', CASE WHEN (r->>'sales_growth_rate') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'sales_growth_rate')::numeric END,
    'revenue', CASE WHEN (r->>'revenue') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'revenue')::numeric END,
    'revenue_growth_rate', CASE WHEN (r->>'revenue_growth_rate') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'revenue_growth_rate')::numeric END,
    'price', CASE WHEN (r->>'price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'price')::numeric END,
    'creator_count', CASE WHEN (r->>'creator_count') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'creator_count')::numeric END,
    'creator_growth', CASE WHEN (r->>'creator_growth') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'creator_growth')::numeric END,
    'creator_conversion_ratio', CASE WHEN (r->>'creator_conversion_ratio') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'creator_conversion_ratio')::numeric END,
    'video_count', CASE WHEN (r->>'video_count') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'video_count')::numeric END,
    'view_growth', CASE WHEN (r->>'view_growth') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'view_growth')::numeric END,
    'share_growth', CASE WHEN (r->>'share_growth') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'share_growth')::numeric END,
    'buyer_intent', nullif(btrim(coalesce(r->>'buyer_intent','')),''),
    'shop_count', CASE WHEN (r->>'shop_count') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'shop_count')::numeric END,
    'seller_count', CASE WHEN (r->>'seller_count') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'seller_count')::numeric END,
    'advertiser_count', CASE WHEN (r->>'advertiser_count') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'advertiser_count')::numeric END,
    'ad_growth', CASE WHEN (r->>'ad_growth') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'ad_growth')::numeric END,
    'search_demand', CASE WHEN (r->>'search_demand') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'search_demand')::numeric END,
    'search_growth', CASE WHEN (r->>'search_growth') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'search_growth')::numeric END,
    'problem_signal', nullif(btrim(coalesce(r->>'problem_signal','')),''),
    'contract','pulse_discovery_signal_v1',
    'provenance', jsonb_build_object('lane',upper(btrim(coalesce(p_lane,''))),'source',p_source,
      'note','UNKNOWN fields are null, never 0; metrics are market-scoped; cross_market_reference is never local validation'));
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_discovery_signal_normalize(text,text,text,jsonb) TO authenticated, service_role;

-- 4. Multi-lane orchestrator: market-only -> per-lane status + the runnable SEARCH
--    lane's autonomous scope plan. One lane's zero/unavailable never stops the cycle.
CREATE OR REPLACE FUNCTION public.fn_multi_lane_discovery_plan(
    p_market text, p_max_lanes integer DEFAULT 5, p_user_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  cfg jsonb; v_lanes jsonb := '[]'::jsonb; L record; v_plan jsonb; v_status text; v_runnable boolean;
  v_runnable_lanes text[] := ARRAY[]::text[]; v_n int := greatest(1, least(coalesce(p_max_lanes,5), 10));
BEGIN
  cfg := public.fn_market_provider_config(v_mkt);
  IF coalesce((cfg->>'ok')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok',false,'market',v_mkt,'reason',coalesce(cfg->>'reason','UNSUPPORTED_MARKET'));
  END IF;
  FOR L IN SELECT * FROM public.discovery_lane_registry WHERE is_active ORDER BY
    CASE availability WHEN 'AVAILABLE' THEN 0 WHEN 'SEEDED_AVAILABLE' THEN 1 ELSE 2 END, lane_key LIMIT v_n
  LOOP
    v_plan := NULL; v_runnable := false;
    IF L.lane_key='SEARCH' AND L.discovery_mode='AUTONOMOUS' AND L.availability='AVAILABLE' THEN
      v_plan := public.fn_autonomous_discovery_plan(v_mkt, 1, p_user_id);
      IF coalesce((v_plan->>'ok')::boolean,false) THEN v_status := 'READY'; v_runnable := true;
        v_runnable_lanes := array_append(v_runnable_lanes, 'SEARCH');
      ELSE v_status := 'SEARCH_PLAN_'||coalesce(v_plan->>'reason','ERROR'); END IF;
    ELSIF L.availability='PRODUCT_NATIVE_GAP' THEN v_status := 'GAP_NO_PRODUCT_NATIVE_PROVIDER';
    ELSIF L.availability='BLOCKED_EXTERNAL_APPROVAL' THEN v_status := 'BLOCKED_EXTERNAL_APPROVAL';
    ELSIF L.availability='RESEARCH_ONLY' THEN v_status := 'RESEARCH_ONLY_NOT_AUTONOMOUS_DISCOVERY';
    ELSIF L.availability='SEEDED_AVAILABLE' THEN v_status := 'SEEDED_REQUIRES_SCOPE';
    ELSE v_status := 'UNAVAILABLE'; END IF;
    v_lanes := v_lanes || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'lane', L.lane_key, 'label', L.label, 'provider', L.provider,
      'capability_class', L.capability_class, 'discovery_mode', L.discovery_mode,
      'availability', L.availability, 'status', v_status, 'runnable', v_runnable,
      'selected_scope', v_plan->>'selected_scope', 'keyword_ideas_request', v_plan->'keyword_ideas_request',
      'location_code', v_plan->>'location_code', 'language_code', v_plan->>'language_code', 'lane_note', L.note)));
  END LOOP;
  RETURN jsonb_build_object('ok',true,'market',v_mkt,'mode','MULTI_LANE_MARKET',
    'runnable_autonomous_lanes', to_jsonb(v_runnable_lanes), 'lane_count', jsonb_array_length(v_lanes),
    'product_native_gap', EXISTS(SELECT 1 FROM public.discovery_lane_registry WHERE lane_key='COMMERCE' AND availability='PRODUCT_NATIVE_GAP'),
    'zero_yield_rule','one lane returning zero/unavailable does not stop the cycle; other lanes still run and report explicit status',
    'lanes', v_lanes, 'contract','pulse_multi_lane_discovery_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_multi_lane_discovery_plan(text,integer,uuid) TO authenticated, service_role;
