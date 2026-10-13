-- mig_295_stage2g_qualification_boundary_integrity.sql
-- STRATELOQ — Stage 2G: Stage-1 -> Stage-2 qualification boundary integrity (bounded fix).
--
-- Two production inconsistencies were surfaced during the read-only Stage-2F selection:
--
--   (1) FRESHNESS FOOTGUN (root cause of the apparent "early-state QUALIFIED while hard
--       gate FALSE / qualifying_family_count=1" contradiction).
--       fn_stage1_supplier_resolution_qualified and fn_stage1_commerce_evidence both
--       DEFAULT p_freshness_hours := 336. When a caller passes NULL explicitly, the
--       commerce-evidence filter `observed_at > now() - make_interval(hours => NULL)`
--       evaluates to NULL for every row, silently excluding ALL commerce signals and
--       dropping the COMMERCE_MOMENTUM family -> one fewer qualifying family -> a false
--       "not qualified" reading. The early-opportunity-state and lifecycle projections
--       use the 336h default and are internally consistent with the gate; the Stage-2F
--       probe used NULL, producing the mismatch. There is NO structural early/hard
--       divergence: fn_stage1_early_opportunity_state already reuses the authoritative
--       gate and emits QUALIFIED_FOR_SUPPLIER_RESOLUTION only when the gate is true at
--       the SAME freshness. Permanent invariant implemented here: the gate can never run
--       with a NULL/<=0 freshness window; it coalesces to the canonical 336h default, so
--       it can never silently exclude all commerce evidence.
--
--   (2) BRANDED/IP MISS. fn_is_branded_or_ip_sensitive was a hardcoded brand allowlist
--       scanned against the title string. "Ankerkraut" (a registered German CPG spice
--       trademark) is not in the list, so a branded seasonal gift set (Ankerkraut Premium
--       Adventskalender) passed the GENERIC dropshipping supplier-resolution gate with
--       branded_or_ip=false, even though its authoritative concrete identity carries the
--       trademark token "ankerkraut" as a required attribute. Fix: promote brand screening
--       to a server-owned, data-driven, extensible registry (public.commerce_product_brand_registry)
--       seeded verbatim from the legacy list PLUS the real misses, with structured output
--       (brand_state/brand_name/brand_evidence/brand_confidence). This generalizes to future
--       products and is NOT a hardcoded "Ankerkraut" code special case. Generic product
--       attributes (adventskalender, premium, cable, projector, ...) are NOT treated as
--       brands. The hard gate already consumes the 'flagged' key, so a branded product now
--       fails the gate automatically.
--
-- Also: Stage-2E pre-dispatch guard. The Stage-2 supplier-search path (claim -> CJ) had no
-- qualification guard anywhere (the resolver does not reference the gate). A stale UI or old
-- row could dispatch a search on a product whose CURRENT authoritative qualification is false.
-- fn_stage2_cj_search_claim now fails closed (STAGE2_NOT_SUPPLIER_QUALIFIED) BEFORE creating a
-- claim row and BEFORE any CJ call, by independently re-checking the authoritative gate at the
-- canonical freshness. CJ matching semantics and the resolver are untouched.
--
-- DOES NOT change: evidence-family qualification thresholds, family rules, supplier matching
-- semantics, CJ candidate ranking, Product Asset Lock, Stage 3/4, store generation, ads,
-- orders, publishing. No provider calls. No evidence rows altered. Krippen's historical
-- NO_VALID_CJ_MATCH evidence is preserved untouched.
--
-- The selftest asserts durable INVARIANTS over real production data (drift-proof: a
-- one-family product can never be supplier-qualified; a branded product can never be
-- supplier-qualified; early-state QUALIFIED iff hard gate true; NULL freshness == default)
-- plus pure brand-function checks. No synthetic commerce_products fixtures are created
-- (commerce_products.user_id is FK-constrained to auth.users, and we never pollute the real
-- tenant workspace with fake products).

BEGIN;

-- ============================================================================
-- 1. SERVER-OWNED BRAND / IP REGISTRY (authoritative, data-driven, extensible)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.commerce_product_brand_registry (
  brand_token    text PRIMARY KEY,              -- lowercased match token
  brand_name     text NOT NULL,                 -- canonical display name
  brand_category text NOT NULL DEFAULT 'BRAND', -- BRAND | CHARACTER_IP | CPG | ELECTRONICS | FASHION | FOOD | TOY_IP ...
  confidence     text NOT NULL DEFAULT 'HIGH',  -- HIGH | MEDIUM
  active         boolean NOT NULL DEFAULT true,
  source         text NOT NULL DEFAULT 'seed',
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.commerce_product_brand_registry IS
  'Authoritative, server-owned brand/trademark token registry consumed by fn_is_branded_or_ip_sensitive. Global reference data (not tenant-scoped). Extend by INSERT; no code change needed. Generic product attributes must never be added here.';

-- Global reference table: deny direct client access; SECURITY DEFINER functions read it.
ALTER TABLE public.commerce_product_brand_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commerce_product_brand_registry FROM anon, authenticated;

-- Seed: legacy hardcoded list (verbatim, no regression) + the real misses (Ankerkraut, ESN).
INSERT INTO public.commerce_product_brand_registry (brand_token, brand_name, brand_category, confidence, source) VALUES
  ('pokemon','Pokemon','CHARACTER_IP','HIGH','seed_legacy'),
  ('pokémon','Pokémon','CHARACTER_IP','HIGH','seed_legacy'),
  ('pikachu','Pikachu','CHARACTER_IP','HIGH','seed_legacy'),
  ('disney','Disney','CHARACTER_IP','HIGH','seed_legacy'),
  ('marvel','Marvel','CHARACTER_IP','HIGH','seed_legacy'),
  ('nintendo','Nintendo','ELECTRONICS','HIGH','seed_legacy'),
  ('lego','LEGO','TOY_IP','HIGH','seed_legacy'),
  ('sanrio','Sanrio','CHARACTER_IP','HIGH','seed_legacy'),
  ('hello kitty','Hello Kitty','CHARACTER_IP','HIGH','seed_legacy'),
  ('harry potter','Harry Potter','CHARACTER_IP','HIGH','seed_legacy'),
  ('star wars','Star Wars','CHARACTER_IP','HIGH','seed_legacy'),
  ('barbie','Barbie','TOY_IP','HIGH','seed_legacy'),
  ('hasbro','Hasbro','TOY_IP','HIGH','seed_legacy'),
  ('funko','Funko','TOY_IP','HIGH','seed_legacy'),
  ('jellycat','Jellycat','TOY_IP','HIGH','seed_legacy'),
  ('labubu','Labubu','TOY_IP','HIGH','seed_legacy'),
  ('bluey','Bluey','CHARACTER_IP','HIGH','seed_legacy'),
  ('nike','Nike','FASHION','HIGH','seed_legacy'),
  ('adidas','Adidas','FASHION','HIGH','seed_legacy'),
  ('puma','Puma','FASHION','HIGH','seed_legacy'),
  ('new balance','New Balance','FASHION','HIGH','seed_legacy'),
  ('jordan','Jordan','FASHION','HIGH','seed_legacy'),
  ('apple','Apple','ELECTRONICS','HIGH','seed_legacy'),
  ('iphone','iPhone','ELECTRONICS','HIGH','seed_legacy'),
  ('ipad','iPad','ELECTRONICS','HIGH','seed_legacy'),
  ('airpods','AirPods','ELECTRONICS','HIGH','seed_legacy'),
  ('samsung','Samsung','ELECTRONICS','HIGH','seed_legacy'),
  ('galaxy','Samsung Galaxy','ELECTRONICS','HIGH','seed_legacy'),
  ('sony','Sony','ELECTRONICS','HIGH','seed_legacy'),
  ('playstation','PlayStation','ELECTRONICS','HIGH','seed_legacy'),
  ('xbox','Xbox','ELECTRONICS','HIGH','seed_legacy'),
  ('dyson','Dyson','ELECTRONICS','HIGH','seed_legacy'),
  ('stanley','Stanley','BRAND','HIGH','seed_legacy'),
  ('reisenthel','Reisenthel','BRAND','HIGH','seed_legacy'),
  ('makita','Makita','ELECTRONICS','HIGH','seed_legacy'),
  ('dewalt','DeWalt','ELECTRONICS','HIGH','seed_legacy'),
  ('bosch','Bosch','ELECTRONICS','HIGH','seed_legacy'),
  ('dji','DJI','ELECTRONICS','HIGH','seed_legacy'),
  ('gopro','GoPro','ELECTRONICS','HIGH','seed_legacy'),
  ('gucci','Gucci','FASHION','HIGH','seed_legacy'),
  ('prada','Prada','FASHION','HIGH','seed_legacy'),
  ('chanel','Chanel','FASHION','HIGH','seed_legacy'),
  ('dior','Dior','FASHION','HIGH','seed_legacy'),
  ('louis vuitton','Louis Vuitton','FASHION','HIGH','seed_legacy'),
  ('rolex','Rolex','FASHION','HIGH','seed_legacy'),
  ('lululemon','Lululemon','FASHION','HIGH','seed_legacy'),
  ('ugg','UGG','FASHION','HIGH','seed_legacy'),
  ('crocs','Crocs','FASHION','HIGH','seed_legacy'),
  ('birkenstock','Birkenstock','FASHION','HIGH','seed_legacy'),
  ('starbucks','Starbucks','FOOD','HIGH','seed_legacy'),
  ('coca cola','Coca-Cola','FOOD','HIGH','seed_legacy'),
  ('red bull','Red Bull','FOOD','HIGH','seed_legacy'),
  ('nutella','Nutella','FOOD','HIGH','seed_legacy'),
  ('lindt','Lindt','FOOD','HIGH','seed_legacy'),
  ('haribo','Haribo','FOOD','HIGH','seed_legacy'),
  -- Real misses observed in production DE data (branded CPG; not in the legacy list):
  ('ankerkraut','Ankerkraut','CPG','HIGH','stage2g'),
  ('esn','ESN','CPG','HIGH','stage2g')
ON CONFLICT (brand_token) DO NOTHING;

-- ============================================================================
-- 2. REGISTRY-DRIVEN BRAND / IP SCREENER (backward-compatible + structured output)
-- ============================================================================
-- Was IMMUTABLE with an inline array; now STABLE SECURITY DEFINER reading the registry.
-- Matching: multi-word tokens and tokens >= 4 chars use substring (preserves legacy
-- behavior for every legacy token); short tokens (< 4 chars, e.g. dji/ugg/esn) use
-- word-boundary matching to avoid false positives (e.g. "nugget" must not match "ugg").
CREATE OR REPLACE FUNCTION public.fn_is_branded_or_ip_sensitive(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v text := lower(coalesce(p_name,''));
  r record;
  matched text[] := ARRAY[]::text[];
  v_brand_name text := NULL;
  v_conf text := NULL;
  hit boolean;
BEGIN
  IF v ~ '[®™©]' THEN
    matched := array_append(matched,'trademark_symbol');
    v_conf := 'HIGH';
  END IF;

  FOR r IN
    SELECT brand_token, brand_name, confidence
      FROM public.commerce_product_brand_registry
     WHERE active = true
     ORDER BY char_length(brand_token) DESC
  LOOP
    IF position(' ' in r.brand_token) > 0 OR char_length(r.brand_token) >= 4 THEN
      hit := position(r.brand_token in v) > 0;
    ELSE
      hit := v ~ ('\m' || r.brand_token || '\M');
    END IF;
    IF hit THEN
      matched := array_append(matched, r.brand_token);
      IF v_brand_name IS NULL THEN
        v_brand_name := r.brand_name;
        v_conf := coalesce(v_conf, r.confidence);
      END IF;
    END IF;
  END LOOP;

  IF array_length(matched,1) > 0 THEN
    RETURN jsonb_build_object(
      'flagged', true,
      'screening_state','BRANDED_OR_IP_REVIEW',
      'matched', to_jsonb(matched),
      'brand_state','BRANDED_OR_IP',
      'brand_name', v_brand_name,
      'brand_evidence', to_jsonb(matched),
      'brand_confidence', coalesce(v_conf,'HIGH'),
      'contract','pulse_brand_ip_screen_v2');
  END IF;

  RETURN jsonb_build_object(
    'flagged', false,
    'screening_state','GENERIC_OK',
    'matched', to_jsonb(ARRAY[]::text[]),
    'brand_state','GENERIC_OK',
    'brand_name', NULL,
    'brand_evidence', to_jsonb(ARRAY[]::text[]),
    'brand_confidence', NULL,
    'contract','pulse_brand_ip_screen_v2');
END;
$function$;

-- ============================================================================
-- 3. NULL-FRESHNESS HARDENING — fn_stage1_commerce_evidence
--    Only the freshness window handling changes; every family/price/seller rule is verbatim.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_stage1_commerce_evidence(p_tenant uuid, p_product uuid, p_country text, p_freshness_hours integer DEFAULT 336)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_country,'')));
  v_fresh int := coalesce(p_freshness_hours, 336);  -- INVARIANT: never NULL; never <=0
  cm record; v_units numeric; v_rev numeric; v_cnt int; v_providers text[];
  v_price numeric; v_ccy text; v_ebay boolean; v_sellers text[]; v_scount int;
BEGIN
  IF v_fresh <= 0 THEN v_fresh := 336; END IF;

  SELECT count(*) AS c,
         max(nullif(s.value->>'sales_units','')::numeric) AS u,
         max(nullif(s.value->>'revenue','')::numeric) AS r,
         array_agg(DISTINCT s.value->>'source') AS provs
    INTO cm
  FROM public.commerce_signals s
  WHERE s.product_id=p_product AND s.signal_type='COMMERCE_PRODUCT_NATIVE'
    AND coalesce(s.value->>'market','')=v_mkt
    AND s.observed_at > now() - make_interval(hours => v_fresh);
  v_cnt := coalesce(cm.c,0); v_units := cm.u; v_rev := cm.r;
  v_providers := coalesce(cm.provs, ARRAY[]::text[]);

  SELECT observed_price, price_currency INTO v_price, v_ccy FROM public.commerce_products WHERE id=p_product;
  SELECT EXISTS(
    SELECT 1 FROM public.market_price_observations mpo
    JOIN public.monday_opportunity_registry r ON r.product_id=p_product
    CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
    WHERE m->>'country'=v_mkt AND mpo.market=v_mkt AND mpo.source='EBAY_BROWSE'
      AND mpo.product_query = m->>'price_query' AND coalesce(mpo.total_listings,0) >= 2
  ) INTO v_ebay;

  SELECT array_agg(DISTINCT sid) INTO v_sellers FROM (
    SELECT nullif(btrim(e->'seller'->>'seller_id'),'') AS sid
      FROM public.commerce_signals s CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.evidence,'[]'::jsonb)) e
      WHERE s.product_id=p_product AND s.signal_type='COMMERCE_PRODUCT_NATIVE' AND coalesce(s.value->>'market','')=v_mkt
    UNION
    SELECT nullif(btrim(extended->>'fastmoss_seller_id'),'') FROM public.commerce_products WHERE id=p_product
    UNION
    SELECT nullif(btrim(extended->>'kalodata_seller_id'),'') FROM public.commerce_products WHERE id=p_product
  ) q WHERE sid IS NOT NULL;
  v_scount := coalesce(array_length(v_sellers,1),0);

  RETURN jsonb_build_object(
    'country', v_mkt,
    'commerce_momentum', jsonb_build_object(
      'present', (v_cnt>0), 'short_window_units', v_units, 'short_window_revenue', v_rev,
      'signal_count', v_cnt, 'providers', to_jsonb(v_providers),
      'class','EMERGING_COMMERCE_MOMENTUM',
      'sufficiency','NOT_SUFFICIENT_ALONE_FOR_STRONG',
      'note','short-window units/GMV/newness establish RESEARCH_PRIORITY/EMERGING only; never STRONG/WINNER alone'),
    'local_price', CASE WHEN v_price IS NULL THEN jsonb_build_object('class','UNKNOWN','note','no provider-observed local price')
      ELSE jsonb_build_object('class','LOCAL_OBSERVED_PRICE','amount',v_price,'currency',v_ccy,
        'validated_local_market_price', v_ebay,
        'note', CASE WHEN v_ebay THEN 'multi-listing local market validation present (eBay)'
                     ELSE 'single provider-observed listing; LOCAL_OBSERVED, NOT VALIDATED_LOCAL_MARKET_PRICE (needs multi-seller/multi-source confirmation)' END) END,
    'observed_sellers', jsonb_build_object(
      'provider_observed_distinct', CASE WHEN v_scount=0 THEN NULL ELSE v_scount END,
      'seller_ids', to_jsonb(coalesce(v_sellers,ARRAY[]::text[])), 'deduplicated', true,
      'low_competition_signal', CASE WHEN v_scount=0 THEN NULL ELSE (v_scount < 5) END,
      'note','provider seller identities deduped into the observed seller set; UNKNOWN total stays UNKNOWN and never becomes "<5 sellers"; full saturation still owned by product_market_competitors'),
    'contract','pulse_stage1_commerce_evidence_v1');
END; $function$;

-- ============================================================================
-- 4. NULL-FRESHNESS HARDENING — fn_stage1_supplier_resolution_qualified
--    Only freshness handling changes; family rules, thresholds, disqualifiers are verbatim.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_stage1_supplier_resolution_qualified(p_tenant uuid, p_product uuid, p_country text, p_freshness_hours integer DEFAULT 336)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_country,'')));
  v_fresh int := coalesce(p_freshness_hours, 336);  -- INVARIANT: never NULL; never <=0
  cp record; ce jsonb; pme record; pod record;
  cm_present boolean; cm_qual boolean; cm_units numeric; cm_rev numeric;
  adv_count int; adv_present boolean; adv_qual boolean;
  bsi_present boolean; bsi_qual boolean;
  comm_present boolean; comm_qual boolean;
  mkt_present boolean; mkt_qual boolean;
  present_ct int; qual_ct int; fams jsonb := '[]'::jsonb;
  sat_level text; sat_gap boolean; sat_repr text; observed_high_sat boolean;
  branded boolean; identity_ambiguous boolean; disq boolean;
  price_class text; price_validated boolean; sellers_distinct int;
  qualified boolean; reasons text[] := '{}';
BEGIN
  IF v_fresh <= 0 THEN v_fresh := 336; END IF;

  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product AND user_id=p_tenant;
  ce := public.fn_stage1_commerce_evidence(p_tenant, p_product, v_mkt, v_fresh);
  SELECT * INTO pme FROM public.product_market_evaluations
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=v_mkt
    ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;
  SELECT * INTO pod FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=v_mkt
    ORDER BY created_at DESC LIMIT 1;

  cm_present := coalesce((ce->'commerce_momentum'->>'present')::boolean,false);
  cm_units := nullif(ce->'commerce_momentum'->>'short_window_units','')::numeric;
  cm_rev   := nullif(ce->'commerce_momentum'->>'short_window_revenue','')::numeric;
  cm_qual  := cm_present AND coalesce(cm_units,0) > 0 AND coalesce(cm_rev,0) > 0;

  adv_count := greatest(
    coalesce(nullif(pme.evidence->'advertising_activity'->>'observed_advertisers','')::int, 0),
    coalesce((SELECT count(DISTINCT coalesce(s.value->>'advertiser_id', s.value->>'page_id', s.value->>'advertiser'))
              FROM public.commerce_signals s
              WHERE s.product_id=p_product AND s.signal_type='ADVERTISING_ACTIVITY'
                AND coalesce(s.value->>'market','')=v_mkt)::int, 0));
  adv_present := adv_count > 0;
  adv_qual := adv_count >= 2;

  bsi_present := (pme.component_scores->'buyer_search_intent'->>'subscore') IS NOT NULL;
  bsi_qual := bsi_present AND coalesce(pme.evidence->'buyer_search_intent'->>'band','') NOT IN ('NONE','VERY_LOW','UNKNOWN');

  comm_present := (pme.component_scores->'demand_momentum'->>'subscore') IS NOT NULL;
  comm_qual := comm_present;

  mkt_present := (pme.component_scores->'marketplace_validation'->>'subscore') IS NOT NULL;
  mkt_qual := mkt_present;

  present_ct := (cm_present::int)+(adv_present::int)+(bsi_present::int)+(comm_present::int)+(mkt_present::int);
  qual_ct    := (cm_qual::int)+(adv_qual::int)+(bsi_qual::int)+(comm_qual::int)+(mkt_qual::int);
  fams := jsonb_build_array(
    jsonb_build_object('family','COMMERCE_MOMENTUM','present',cm_present,'qualifying',cm_qual,'strength',jsonb_build_object('units',cm_units,'revenue',cm_rev),'rule','units>0 AND revenue>0'),
    jsonb_build_object('family','ADVERTISING_EMERGENCE','present',adv_present,'qualifying',adv_qual,'strength',jsonb_build_object('distinct_advertisers',adv_count),'rule','>=2 distinct observed advertisers'),
    jsonb_build_object('family','SEARCH_DEMAND','present',bsi_present,'qualifying',bsi_qual,'rule','genuine numeric buyer-intent, band not NONE/VERY_LOW'),
    jsonb_build_object('family','COMMUNITY_SOCIAL','present',comm_present,'qualifying',comm_qual,'rule','genuine community/social attention signal'),
    jsonb_build_object('family','MARKETPLACE_VALIDATION','present',mkt_present,'qualifying',mkt_qual,'rule','same-product selected-country marketplace evidence'));

  sat_level := coalesce(pod.saturation_state->>'level','UNKNOWN');
  sat_gap := coalesce((pod.saturation_state->>'has_defensible_gap')::boolean,false);
  observed_high_sat := (sat_level='VERY_HIGH') OR (sat_level='HIGH' AND NOT sat_gap);
  branded := coalesce((public.fn_is_branded_or_ip_sensitive(coalesce(cp.title,''))->>'flagged')::boolean,false);
  identity_ambiguous := (cp.id IS NULL) OR (coalesce(cp.identity_basis,'') NOT IN ('platform_id','canonical_url'));
  disq := observed_high_sat OR branded OR identity_ambiguous;

  sellers_distinct := nullif(ce->'observed_sellers'->>'provider_observed_distinct','')::int;
  sat_repr := CASE
    WHEN sat_level IN ('LOW','MODERATE','HIGH','VERY_HIGH') THEN 'OBSERVED_'||sat_level
    WHEN sellers_distinct IS NOT NULL THEN 'LIMITED_COVERAGE'
    ELSE 'UNKNOWN' END;

  price_class := ce->'local_price'->>'class';
  price_validated := coalesce((ce->'local_price'->>'validated_local_market_price')::boolean,false);

  qualified := (qual_ct >= 2) AND NOT disq;

  IF disq THEN
    IF observed_high_sat THEN reasons:=array_append(reasons,'DISQUALIFIED_OBSERVED_HIGH_SATURATION'); END IF;
    IF branded THEN reasons:=array_append(reasons,'DISQUALIFIED_BRANDED_OR_IP'); END IF;
    IF identity_ambiguous THEN reasons:=array_append(reasons,'DISQUALIFIED_IDENTITY_AMBIGUOUS'); END IF;
  ELSIF qualified THEN reasons:=array_append(reasons,'TWO_INDEPENDENT_QUALIFYING_FAMILIES');
  ELSIF qual_ct=1 THEN reasons:=array_append(reasons,'ONLY_ONE_QUALIFYING_FAMILY');
  ELSE reasons:=array_append(reasons,'NO_QUALIFYING_FAMILY'); END IF;

  RETURN jsonb_build_object(
    'stage1_supplier_resolution_qualified', qualified,
    'selected_country', v_mkt,
    'qualifying_family_count', qual_ct,
    'present_family_count', present_ct,
    'evidence_families', fams,
    'disqualifiers', jsonb_build_object('observed_high_saturation',observed_high_sat,'branded_or_ip',branded,'identity_ambiguous',identity_ambiguous),
    'saturation_representation', sat_repr,
    'local_price', jsonb_build_object('class', coalesce(price_class,'UNKNOWN'),'validated_local_market_price', price_validated),
    'observed_sellers_distinct', sellers_distinct,
    'reasons', to_jsonb(reasons),
    'invariants', jsonb_build_object(
      'two_independent_qualifying_families_required', true,
      'commerce_alone_insufficient', true,
      'ads_alone_insufficient', true,
      'supplier_or_economics_cannot_qualify', true,
      'validated_local_price_not_required', true,
      'validated_saturation_not_required', true,
      'observed_high_saturation_blocks', true,
      'unknown_is_not_pass_and_not_observed_negative', true,
      'one_seller_not_low_competition', true,
      'one_listing_not_validated_price', true,
      'freshness_never_null_coalesces_to_336', true),
    'meaning','Enough independent, country-specific evidence to justify exact supplier resolution; NOT launch-ready.',
    'contract','pulse_stage1_supplier_resolution_qualified_v1');
END; $function$;

-- ============================================================================
-- 5. STAGE-2E PRE-DISPATCH GUARD — fn_stage2_cj_search_claim fails closed
--    Independently re-checks the authoritative gate at the canonical freshness BEFORE
--    creating a claim row and BEFORE any CJ call. Idempotency semantics unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_search_claim(p_tenant uuid, p_product_id uuid, p_market text, p_request_id text, p_search_query text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_rid text := btrim(coalesce(p_request_id,''));
  v_id uuid; r record; v_q jsonb;
begin
  if p_tenant is null then return jsonb_build_object('ok',false,'error','tenant_required'); end if;
  if p_product_id is null then return jsonb_build_object('ok',false,'error','product_required'); end if;
  if v_mkt = '' then return jsonb_build_object('ok',false,'error','market_required'); end if;
  if v_rid = '' then return jsonb_build_object('ok',false,'error','request_id_required'); end if;

  perform 1 from public.commerce_products where id = p_product_id and user_id = p_tenant;
  if not found then
    return jsonb_build_object('ok',false,'error','product_not_found_for_tenant');
  end if;

  -- STAGE-2E ENTRY GUARD (fail closed): the supplier search may be dispatched ONLY if the
  -- product's CURRENT authoritative Stage-1 supplier-resolution gate is TRUE at the canonical
  -- freshness. This runs BEFORE the idempotency INSERT and BEFORE any CJ call, so a stale UI
  -- or old row that still says "Supplier Qualified" cannot consume a CJ search. The gate
  -- already includes the branded/IP disqualifier, so branded products are refused here too.
  v_q := public.fn_stage1_supplier_resolution_qualified(p_tenant, p_product_id, v_mkt);
  if not coalesce((v_q->>'stage1_supplier_resolution_qualified')::boolean, false) then
    return jsonb_build_object(
      'ok', false, 'proceed', false, 'claimed', false,
      'error','STAGE2_NOT_SUPPLIER_QUALIFIED',
      'qualifying_family_count', v_q->'qualifying_family_count',
      'disqualifiers', v_q->'disqualifiers',
      'reasons', v_q->'reasons',
      'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
  end if;

  insert into public.commerce_stage2_search_request
    (tenant_id, opportunity_product_id, market, request_id, search_query)
  values (p_tenant, p_product_id, v_mkt, v_rid, p_search_query)
  on conflict (tenant_id, opportunity_product_id, market, request_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('ok',true,'proceed',true,'claimed',true,'duplicate',false,'status','CLAIMED',
      'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
  end if;

  select * into r from public.commerce_stage2_search_request
   where tenant_id = p_tenant and opportunity_product_id = p_product_id and market = v_mkt and request_id = v_rid;
  return jsonb_build_object('ok',true,'proceed',false,'claimed',false,'duplicate',true,
    'status', r.status, 'provider_called', r.provider_called, 'result', r.result,
    'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
end;
$function$;

-- ============================================================================
-- 6. SELFTEST — boundary integrity (durable invariants over real data + pure brand fn)
--    No synthetic commerce_products fixtures (FK to auth.users; never pollute real tenant).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_stage2g_boundary_integrity_selftest()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  REALT uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'; -- production tenant under inspection
  OTH  uuid := '2f000000-0000-4000-a000-000000002999';  -- non-owner tenant (not in auth.users)
  HIT  uuid := 'ca4a79b0-41a7-4fc6-b267-82b99a123dff';   -- generic, 2 qualifying families (DE)
  ANK  uuid := '1f3bc864-08df-4893-9f06-faa0fa0fb52b';   -- Ankerkraut (branded CPG) (DE)
  KRIP uuid := '5bc29d0a-b8e0-4fa9-bb80-d77197d770c4';   -- Krippen (generic; already NO_VALID_CJ_MATCH) (DE)
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0;
  ok boolean; rec record;
  gHit jsonb; gAnk jsonb; gKrip jsonb; gKripNull jsonb; gHitJP jsonb; gOth jsonb;
  claimAnk jsonb; rowcnt int;
  mismatch_early int := 0; viol_onefam int := 0; viol_branded int := 0; qualified_ct int := 0; scanned int := 0;
BEGIN
  -- Durable INVARIANTS over all real DE products for the production tenant
  FOR rec IN
    SELECT DISTINCT e.product_id AS pid
      FROM public.product_market_evaluations e
     WHERE e.tenant_id=REALT AND e.country_code='DE' AND coalesce(e.is_fixture,false)=false
  LOOP
    DECLARE g jsonb; es text; hard boolean; qf int; br boolean; BEGIN
      g := public.fn_stage1_supplier_resolution_qualified(REALT, rec.pid, 'DE');
      es := public.fn_stage1_early_opportunity_state(REALT, rec.pid, 'DE')->>'early_opportunity_state';
      hard := coalesce((g->>'stage1_supplier_resolution_qualified')::boolean,false);
      qf := coalesce((g->>'qualifying_family_count')::int,0);
      br := coalesce((g->'disqualifiers'->>'branded_or_ip')::boolean,false);
      scanned := scanned + 1;
      IF (es='QUALIFIED_FOR_SUPPLIER_RESOLUTION') <> hard THEN mismatch_early := mismatch_early+1; END IF;
      IF qf < 2 AND hard THEN viol_onefam := viol_onefam+1; END IF;         -- Test A invariant
      IF br AND hard THEN viol_branded := viol_branded+1; END IF;           -- Test C invariant
      IF hard THEN qualified_ct := qualified_ct+1; END IF;
    END;
  END LOOP;

  -- INV-1: early-state QUALIFIED iff hard gate true (no early/hard divergence)
  ok := (mismatch_early = 0);
  checks := checks || jsonb_build_object('check','INV_earlystate_iff_hardgate','ok',ok,'detail',jsonb_build_object('mismatches',mismatch_early,'scanned',scanned));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- A: a one-qualifying-family product can NEVER be supplier-qualified
  ok := (viol_onefam = 0);
  checks := checks || jsonb_build_object('check','A_one_family_never_qualified','ok',ok,'detail',jsonb_build_object('violations',viol_onefam));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- C: a branded/IP product can NEVER be supplier-qualified for generic dropshipping
  ok := (viol_branded = 0);
  checks := checks || jsonb_build_object('check','C_branded_never_qualified','ok',ok,'detail',jsonb_build_object('violations',viol_branded));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- B: a real generic two-family product DOES qualify (current state: Hit the Slab)
  gHit := public.fn_stage1_supplier_resolution_qualified(REALT, HIT, 'DE');
  ok := ((gHit->>'qualifying_family_count')::int >= 2)
        AND ((gHit->'disqualifiers'->>'branded_or_ip')::boolean = false)
        AND ((gHit->>'stage1_supplier_resolution_qualified')::boolean = true);
  checks := checks || jsonb_build_object('check','B_generic_two_family_qualifies','ok',ok,
     'detail', jsonb_build_object('qf',gHit->'qualifying_family_count','hard',gHit->'stage1_supplier_resolution_qualified'));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- D: generic attributes are NOT brands; real brands ARE flagged; word-boundary safety
  ok := ((public.fn_is_branded_or_ip_sensitive('premium adventskalender widget stand')->>'flagged')::boolean = false)
        AND ((public.fn_is_branded_or_ip_sensitive('Ankerkraut Premium Adventskalender')->>'flagged')::boolean = true)
        AND ((public.fn_is_branded_or_ip_sensitive('Ankerkraut Premium Adventskalender')->>'brand_name') = 'Ankerkraut')
        AND ((public.fn_is_branded_or_ip_sensitive('Makita Adventskalender')->>'flagged')::boolean = true)
        AND ((public.fn_is_branded_or_ip_sensitive('cool mist humidifier')->>'flagged')::boolean = false)
        AND ((public.fn_is_branded_or_ip_sensitive('snuggle nugget organizer')->>'flagged')::boolean = false);
  checks := checks || jsonb_build_object('check','D_generic_not_brand_registry_catches_real','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- E: historical real Krippen NO_VALID_CJ_MATCH evidence preserved (bound=false)
  SELECT EXISTS(
    SELECT 1 FROM public.commerce_concrete_supplier_resolution
     WHERE opportunity_product_id = KRIP AND market='DE'
       AND identity_result='NO_VALID_CJ_MATCH' AND bound=false) INTO ok;
  checks := checks || jsonb_build_object('check','E_krippen_history_preserved','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- F: Stage-2E guard refuses a product whose current authoritative qualification is false
  --    (Ankerkraut is now branded -> not qualified) and creates NO claim row.
  claimAnk := public.fn_stage2_cj_search_claim(REALT, ANK, 'DE', 'stage2g-selftest-guard-ank');
  SELECT count(*) INTO rowcnt FROM public.commerce_stage2_search_request
   WHERE request_id = 'stage2g-selftest-guard-ank';
  ok := ((claimAnk->>'ok')::boolean = false)
        AND (claimAnk->>'error' = 'STAGE2_NOT_SUPPLIER_QUALIFIED')
        AND (rowcnt = 0);
  checks := checks || jsonb_build_object('check','F_stage2e_guard_fails_closed_no_row','ok',ok,
     'detail', jsonb_build_object('error',claimAnk->>'error','rows_created',rowcnt));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- FRESHNESS: NULL freshness == canonical default (footgun closed). Real Krippen's 2nd
  -- family (COMMERCE_MOMENTUM) is freshness-decisive: pre-fix NULL dropped it to qf=1.
  gKrip := public.fn_stage1_supplier_resolution_qualified(REALT, KRIP, 'DE', 336);
  gKripNull := public.fn_stage1_supplier_resolution_qualified(REALT, KRIP, 'DE', NULL);
  ok := ((gKripNull->>'stage1_supplier_resolution_qualified')::boolean = (gKrip->>'stage1_supplier_resolution_qualified')::boolean)
        AND ((gKripNull->>'qualifying_family_count')::int = (gKrip->>'qualifying_family_count')::int);
  checks := checks || jsonb_build_object('check','FRESHNESS_null_equals_default_no_footgun','ok',ok,
     'detail', jsonb_build_object('qf_null',gKripNull->'qualifying_family_count','qf_336',gKrip->'qualifying_family_count'));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- G: country isolation — DE evidence does not leak to an un-evaluated market (JP)
  gHitJP := public.fn_stage1_supplier_resolution_qualified(REALT, HIT, 'JP');
  ok := ((gHit->>'stage1_supplier_resolution_qualified')::boolean = true)
        AND ((gHitJP->>'stage1_supplier_resolution_qualified')::boolean = false)
        AND ((gHitJP->>'qualifying_family_count')::int = 0);
  checks := checks || jsonb_build_object('check','G_country_isolation','ok',ok,
     'detail', jsonb_build_object('DE',gHit->'stage1_supplier_resolution_qualified','JP',gHitJP->'stage1_supplier_resolution_qualified'));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- H: tenant isolation — Hit the Slab under a non-owner tenant fails closed (not owned)
  gOth := public.fn_stage1_supplier_resolution_qualified(OTH, HIT, 'DE');
  ok := ((gOth->>'stage1_supplier_resolution_qualified')::boolean = false)
        AND ((gOth->'disqualifiers'->>'identity_ambiguous')::boolean = true);
  checks := checks || jsonb_build_object('check','H_tenant_isolation','ok',ok,
     'detail', jsonb_build_object('other_tenant_hard',gOth->'stage1_supplier_resolution_qualified'));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object(
    'contract','pulse_stage2g_boundary_integrity_selftest_v1',
    'passed', passed, 'failed', failed, 'total', passed+failed,
    'ok', (failed = 0),
    'corrected_de_supplier_qualified_count', qualified_ct,
    'de_products_scanned', scanned,
    'checks', checks,
    'generated_at', now());
END; $function$;

COMMIT;
