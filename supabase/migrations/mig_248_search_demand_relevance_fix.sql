-- ============================================================================
-- mig_248_search_demand_relevance_fix.sql
-- STRATELOQ-SEARCH-DEMAND-RELEVANCE-FIX-013L
--
-- Truthfulness fix (not a score boost) for the 013K finding: for product
-- "kids nightlight projector" (GB), real category queries "star projector"
-- (2,900/mo), "galaxy projector" (3,600/mo), "night light projector" (1,600/mo)
-- were classified IRRELEVANT -> buyer_search_intent = 0.
--
-- Root cause in fn_classify_search_query_relevance (pure product-name token
-- overlap):
--   1. Category queries share only the head noun "projector" -> overlap 1/3 =
--      0.33, just below the 0.34 floor -> IRRELEVANT.
--   2. "nightlight" (one token) never matches "night light" (two tokens):
--      compound-word normalization gap.
--   3. No CATEGORY_DEMAND / SOLUTION_DEMAND tier existed at all.
--
-- Fix: (a) de-spaced compound containment -> CLOSE_VARIANT (fixes nightlight vs
-- night light); (b) head-noun (category) sharing -> CATEGORY_DEMAND; (c) shared
-- non-head product tokens -> SOLUTION_DEMAND; (d) any shared token -> ADJACENT.
-- The receiver counts CATEGORY_DEMAND/SOLUTION_DEMAND at a DISCOUNTED weight
-- (0.35) tracked SEPARATELY from product-direct volume, and never claims category
-- volume as product-specific searches. Nothing is patched; the canonical pipeline
-- recomputes. A lower or higher score is whatever the weighted real evidence gives.
--
-- Known limitation (documented, not gamed): the head-noun heuristic treats every
-- same-head-noun query as category demand, so a different projector sub-category
-- (e.g. "office projector") also reads CATEGORY_DEMAND; distinguishing decorative
-- vs video projectors needs a category taxonomy (future). Category demand is
-- weighted weakly and the orchestrator seeds product-relevant terms, so impact is
-- bounded. "projector screen" is caught as ACCESSORY via the generic 'screen' term.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_classify_search_query_relevance(p_product_name text, p_query text)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE
  prod text; q text; ptoks text[]; qtoks text[]; overlap numeric; shared int; has_mod boolean;
  head text; dprod text; dq text; contain boolean; cov numeric;
  accessory_kw text[] := ARRAY['case','cover','mount','stand','bag','strap','adapter','charger','cable','holder','sleeve','skin','protector','compatible','accessory','accessories','battery','batteries','screen'];
  info_kw text[] := ARRAY['how','what','why','when','where','guide','tutorial','recipe','recipes','meaning','definition','review','reviews','tips','diy','instructions','instruction','manual','versus','vs'];
  service_kw text[] := ARRAY['service','services','technician','technicians','professional','professionals','company','companies','quote','quotes','booking','installer','installation','handyman','contractor','repairman','upholsterer','near','nearby','rental','hire','salary','jobs'];
  modifier_kw text[] := ARRAY['patch','patches','kit','kits','tape','tool','tools','marker','markers','compound','device','machine','replacement','part','parts','pack','set','sheet','sheets','sticker','stickers','paste','glue','filler','pen','pens','cream','solution','spray'];
BEGIN
  prod := btrim(regexp_replace(lower(coalesce(p_product_name,'')), '[^a-z0-9]+',' ','g'));
  q    := btrim(regexp_replace(lower(coalesce(p_query,'')),        '[^a-z0-9]+',' ','g'));
  IF prod = '' OR q = '' THEN RETURN jsonb_build_object('relevance','AMBIGUOUS','reason','empty'); END IF;
  IF q = prod THEN RETURN jsonb_build_object('relevance','DIRECT_PRODUCT','reason','exact'); END IF;
  ptoks := string_to_array(prod,' ');
  qtoks := string_to_array(q,' ');
  has_mod := EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(modifier_kw));
  head := ptoks[array_length(ptoks,1)];                 -- product category head noun
  dprod := replace(prod,' ',''); dq := replace(q,' ','');  -- de-spaced compound forms

  -- SERVICE intent
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(service_kw))
     OR q LIKE '%repair shop%' OR q LIKE '%repair store%' OR q LIKE '%near me%'
     OR (q LIKE 'book %' AND q LIKE '%repair%') THEN
    RETURN jsonb_build_object('relevance','SERVICE','reason','service_or_local_intent');
  END IF;
  -- INFORMATIONAL
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(info_kw)) THEN
    RETURN jsonb_build_object('relevance','INFORMATIONAL','reason','informational_intent');
  END IF;
  -- ACCESSORY noun present but not part of the product's own name
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(accessory_kw) AND t <> ALL(ptoks)) THEN
    RETURN jsonb_build_object('relevance','ACCESSORY','reason','accessory_term');
  END IF;

  SELECT count(*) INTO shared FROM (SELECT unnest(ptoks) INTERSECT SELECT unnest(qtoks)) s;
  overlap := shared::numeric / greatest(array_length(ptoks,1),1);
  contain := (position(dq in dprod) > 0) OR (position(dprod in dq) > 0);
  cov := least(length(dq),length(dprod))::numeric / greatest(length(dq),length(dprod),1);

  IF overlap >= 0.75 THEN
    RETURN jsonb_build_object('relevance','DIRECT_PRODUCT','reason','strong_token_overlap','overlap',round(overlap,2),'has_modifier',has_mod);
  ELSIF contain AND cov >= 0.6 THEN
    -- de-spaced compound containment (fixes "nightlight" vs "night light")
    RETURN jsonb_build_object('relevance','CLOSE_VARIANT','reason','compound_variant_containment','overlap',round(overlap,2),'coverage',round(cov,2));
  ELSIF (has_mod AND overlap >= 0.5) OR overlap >= 0.6 THEN
    RETURN jsonb_build_object('relevance','CLOSE_VARIANT','reason','product_variant','overlap',round(overlap,2),'has_modifier',has_mod);
  ELSIF head = ANY(qtoks) THEN
    -- shares the product's category head noun -> broader category demand
    RETURN jsonb_build_object('relevance','CATEGORY_DEMAND','reason','shares_category_head_noun','head',head,'overlap',round(overlap,2));
  ELSIF shared >= 1 AND overlap >= 0.34 THEN
    -- shares meaningful non-head product tokens (same audience/use-case, different form)
    RETURN jsonb_build_object('relevance','SOLUTION_DEMAND','reason','shared_use_case_tokens','overlap',round(overlap,2));
  ELSIF shared >= 1 THEN
    RETURN jsonb_build_object('relevance','ADJACENT','reason','weak_token_share','overlap',round(overlap,2));
  ELSE
    RETURN jsonb_build_object('relevance','IRRELEVANT','reason','no_token_share','overlap',round(overlap,2));
  END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Receiver: count CATEGORY_DEMAND/SOLUTION_DEMAND at a discounted weight, tracked
-- separately from product-direct volume. Never claims category volume as product
-- monthly searches. DIRECT_PRODUCT + CLOSE_VARIANT remain full-weight product demand.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ingest_search_demand_for_product(p_product_id uuid, p_market text, p_source text, p_keywords jsonb, p_dry_run boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_gid uuid := public.fn_global_intelligence_uid();
  v_prod public.commerce_products%rowtype; v_name text; v_mkt text := upper(btrim(coalesce(p_market,'')));
  k jsonb; v_rel jsonb; v_relv text; v_intent text; v_vol numeric;
  v_trans numeric := 0; v_comm numeric := 0; v_total numeric := 0; v_compsum numeric := 0; v_compn int := 0;
  v_cat_trans numeric := 0; v_cat_comm numeric := 0; v_cat_total numeric := 0;
  v_catw numeric := 0.35;                                   -- category/solution demand discount
  v_e_trans numeric; v_e_comm numeric; v_e_total numeric; v_basis text;
  v_cpc_min numeric; v_cpc_max numeric; v_qcount int := 0; v_relcount int := 0; v_catcount int := 0;
  v_headline jsonb; v_headvol numeric := -1; v_cvline jsonb; v_cvvol numeric := -1;
  v_catline jsonb; v_catvol numeric := -1;
  v_hist jsonb; v_season jsonb; v_momentum jsonb;
  v_ts numeric; v_cs numeric; v_vs numeric; v_comps numeric; v_bi numeric; v_band text;
  v_details jsonb := '[]'::jsonb; v_dedup text; v_conf numeric; v_ln_max numeric := ln(50001);
BEGIN
  IF jsonb_typeof(p_keywords) <> 'array' THEN RETURN jsonb_build_object('status','not_keyword_array'); END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_name := coalesce(v_prod.extended->>'normalized_name', v_prod.title);

  FOR k IN SELECT * FROM jsonb_array_elements(p_keywords) LOOP
    v_qcount := v_qcount + 1;
    v_rel := public.fn_classify_search_query_relevance(v_name, k->>'query');
    v_relv := v_rel->>'relevance';
    v_intent := lower(coalesce(k->>'intent_label',''));
    v_vol := CASE WHEN (k->>'search_volume') ~ '^[0-9]+$' THEN (k->>'search_volume')::numeric ELSE NULL END;

    IF v_relv IN ('DIRECT_PRODUCT','CLOSE_VARIANT') THEN
      v_relcount := v_relcount + 1; v_total := v_total + coalesce(v_vol,0);
      IF v_intent='transactional' THEN v_trans := v_trans + coalesce(v_vol,0);
      ELSIF v_intent='commercial' THEN v_comm := v_comm + coalesce(v_vol,0); END IF;
      IF (k->>'competition_index') ~ '^[0-9]+' THEN v_compsum := v_compsum + (k->>'competition_index')::numeric; v_compn := v_compn+1; END IF;
      IF (k->>'cpc') ~ '^[0-9]' THEN
        v_cpc_min := least(coalesce(v_cpc_min,(k->>'cpc')::numeric),(k->>'cpc')::numeric);
        v_cpc_max := greatest(coalesce(v_cpc_max,(k->>'cpc')::numeric),(k->>'cpc')::numeric);
      END IF;
      IF v_relv='DIRECT_PRODUCT' AND coalesce(v_vol,0) > v_headvol THEN v_headvol := coalesce(v_vol,0); v_headline := k;
      ELSIF v_relv='CLOSE_VARIANT' AND coalesce(v_vol,0) > v_cvvol THEN v_cvvol := coalesce(v_vol,0); v_cvline := k; END IF;

    ELSIF v_relv IN ('CATEGORY_DEMAND','SOLUTION_DEMAND') THEN
      v_catcount := v_catcount + 1; v_cat_total := v_cat_total + coalesce(v_vol,0);
      IF v_intent='transactional' THEN v_cat_trans := v_cat_trans + coalesce(v_vol,0);
      ELSIF v_intent='commercial' THEN v_cat_comm := v_cat_comm + coalesce(v_vol,0); END IF;
      IF (k->>'competition_index') ~ '^[0-9]+' THEN v_compsum := v_compsum + (k->>'competition_index')::numeric; v_compn := v_compn+1; END IF;
      IF coalesce(v_vol,0) > v_catvol THEN v_catvol := coalesce(v_vol,0); v_catline := k; END IF;
    END IF;

    v_details := v_details || jsonb_build_array(jsonb_build_object('query',k->>'query','relevance',v_relv,'intent',v_intent,
      'search_volume',v_vol,'competition_index',k->>'competition_index','cpc',k->>'cpc'));
  END LOOP;

  -- headline prefers strongest tier: DIRECT -> CLOSE -> CATEGORY
  v_headline := coalesce(v_headline, v_cvline, v_catline);
  IF v_headline IS NULL THEN
    RETURN jsonb_build_object('status','no_relevant_query','dry_run',p_dry_run,'query_count',v_qcount,'details',v_details);
  END IF;

  v_basis := CASE WHEN v_relcount > 0 AND v_total > 0 THEN 'PRODUCT'
                  WHEN v_relcount > 0 THEN 'PRODUCT_NO_VOLUME'
                  ELSE 'CATEGORY_ONLY' END;

  -- effective volumes: product demand at full weight + category/solution demand discounted
  v_e_trans := v_trans + v_catw * v_cat_trans;
  v_e_comm  := v_comm  + v_catw * v_cat_comm;
  v_e_total := v_total + v_catw * v_cat_total;

  v_hist := v_headline->'monthly_history';
  v_season := public.fn_classify_seasonality(v_hist);
  v_momentum := public.fn_search_momentum(v_hist);

  v_ts := least(100, round(100.0 * ln(1+v_e_trans) / v_ln_max));
  v_cs := least(100, round(100.0 * ln(1+v_e_comm) / v_ln_max));
  v_vs := least(100, greatest(0, round(100.0 * ln(1+v_e_total) / v_ln_max)
            + CASE WHEN v_momentum->>'direction'='RISING' THEN 10 WHEN v_momentum->>'direction'='FALLING' THEN -10 ELSE 0 END));
  v_comps := CASE WHEN v_compn>0 THEN round(v_compsum/v_compn) ELSE NULL END;
  v_bi := round(0.40*v_ts + 0.25*v_cs + 0.20*v_vs + 0.15*coalesce(v_comps,0));
  v_band := CASE WHEN v_bi>=85 THEN 'EXCEPTIONAL' WHEN v_bi>=75 THEN 'HIGH' WHEN v_bi>=60 THEN 'GOOD' WHEN v_bi>=40 THEN 'MODERATE' ELSE 'LOW' END;

  -- confidence: baseline + history + breadth; category-only demand is weaker evidence (capped)
  v_conf := least(0.80, 0.40 + CASE WHEN jsonb_typeof(v_hist)='array' AND jsonb_array_length(v_hist)>=6 THEN 0.20 ELSE 0 END
                              + CASE WHEN (v_relcount+v_catcount)>=3 THEN 0.20 ELSE 0 END);
  IF v_basis='CATEGORY_ONLY' THEN v_conf := least(v_conf, 0.55); END IF;

  v_dedup := 'search:'||p_product_id::text||':'||v_mkt||':search_demand';

  IF NOT p_dry_run THEN
    INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,evidence,provenance,confidence,observed_at,source_event_at,dedup_key,visibility)
    VALUES (v_gid, p_product_id, 'SEARCH_DEMAND',
      jsonb_build_object('market',v_mkt,'source_platform',p_source,'headline_query',v_headline->>'query',
        'buyer_intent_score',v_bi,'buyer_intent_band',v_band,'demand_basis',v_basis,
        'subscores',jsonb_build_object('transactional',v_ts,'commercial',v_cs,'volume_growth',v_vs,'advertiser_competition',v_comps),
        'product_relevant_volume',v_total,'category_relevant_volume',v_cat_total,'category_weight',v_catw,
        'effective_relevant_volume',v_e_total,
        'transactional_volume_est',v_trans,'commercial_volume_est',v_comm,
        'competition_index_avg',v_comps,'cpc_min',v_cpc_min,'cpc_max',v_cpc_max,'cpc_currency','USD',
        'seasonality',v_season,'search_momentum',v_momentum,
        'relevant_query_count',v_relcount,'category_query_count',v_catcount,'query_count',v_qcount,
        'relevance_classifier','fn_classify_search_query_relevance_v2',
        'claim_safety','search interest ESTIMATED (Google-Ads-derived); intent INFERRED; CPC PLATFORM_REPORTED; category/solution demand is BROADER-than-product, weighted x'||v_catw::text||' and NOT counted as product-specific monthly searches; NOT sales/orders/revenue/conversion'),
      v_details,
      jsonb_build_object('source',p_source,'derivation','GOOGLE_ADS_via_DATAFORSEO','volume','ESTIMATED','intent','INFERRED','cpc','PLATFORM_REPORTED','demand_basis',v_basis),
      v_conf, now(), NULL, v_dedup, 'GLOBAL_SAFE')
    ON CONFLICT (user_id, dedup_key) DO UPDATE SET
      value=excluded.value, evidence=excluded.evidence,
      -- merge, preserving any research_run_id/attempt provenance a prior run stamped
      provenance=coalesce(commerce_signals.provenance,'{}'::jsonb) || excluded.provenance,
      confidence=excluded.confidence, observed_at=now();
  END IF;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'market',v_mkt,'headline_query',v_headline->>'query',
    'demand_basis',v_basis,'buyer_intent_score',v_bi,'buyer_intent_band',v_band,
    'subscores',jsonb_build_object('transactional',v_ts,'commercial',v_cs,'volume_growth',v_vs,'advertiser_competition',v_comps),
    'product_relevant_volume',v_total,'category_relevant_volume',v_cat_total,'effective_relevant_volume',v_e_total,
    'relevant_query_count',v_relcount,'category_query_count',v_catcount,'confidence',v_conf,'details',v_details);
END; $function$;

-- ----------------------------------------------------------------------------
-- Self-test (service_role): the verified 013K case, plus tier + guard checks.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_search_relevance_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE p text := 'kids nightlight projector'; v jsonb := '[]'::jsonb; pass boolean := true;
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('kids nightlight projector','DIRECT_PRODUCT'),   -- exact
      ('night light projector','CLOSE_VARIANT'),        -- compound-variant containment (was IRRELEVANT)
      ('night light projector for kids','CLOSE_VARIANT'),-- shares kids+projector
      ('kids star projector','CLOSE_VARIANT'),          -- shares kids+projector
      ('star projector','CATEGORY_DEMAND'),             -- category head noun (was IRRELEVANT)
      ('galaxy projector','CATEGORY_DEMAND'),           -- category head noun (was IRRELEVANT)
      ('buy star projector','CATEGORY_DEMAND'),         -- category head noun
      ('projector screen','ACCESSORY'),                 -- generic accessory noun
      ('projector how to setup guide','INFORMATIONAL'), -- informational
      ('dishwasher tablets','IRRELEVANT')               -- no shared token
    ) AS t(query, expected)
  LOOP
    DECLARE got text;
    BEGIN
      got := (public.fn_classify_search_query_relevance(p, r.query))->>'relevance';
      v := v || jsonb_build_array(jsonb_build_object('query',r.query,'expected',r.expected,'got',got,'pass',(got=r.expected)));
      pass := pass AND (got = r.expected);
    END;
  END LOOP;
  RETURN jsonb_build_object('all_pass',pass,'cases',v,'contract','pulse_search_relevance_selftest_v1_013l');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_search_relevance_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_search_relevance_selftest() TO service_role;

-- one-time: restore research provenance on the founder SEARCH_DEMAND signal if a
-- prior (pre-merge) upsert overwrote it (the SEARCH_DEMAND attempt of run ae239472).
DO $bf$
DECLARE v_run uuid := 'ae239472-e458-4605-936f-c69886a61d31';
        v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba'; v_att uuid;
BEGIN
  SELECT id INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='SEARCH_DEMAND' LIMIT 1;
  IF v_att IS NOT NULL THEN
    UPDATE public.commerce_signals
      SET provenance = coalesce(provenance,'{}'::jsonb)
        || jsonb_build_object('research_run_id',v_run,'source_attempt_id',v_att,'research_market','GB','provenance_restored','mig_248')
      WHERE product_id=v_prod AND signal_type='SEARCH_DEMAND'
        AND (provenance->>'research_run_id') IS NULL;
  END IF;
END; $bf$;
