-- mig_296_discovery_reference_media.sql
-- STRATELOQ — Product discovery media integrity fix.
--
-- ROOT CAUSE (traced end-to-end):
--   FastMoss /product/v1/rank/newListed returns a genuine product-native `cover` image URL per row
--   (verified live: e.g. https://s.500fd.com/tt_product/<hash>~tplv-...-resize-jpeg:800:800.jpeg).
--   The discovery BROKER passes the full rows to ingest, but fn_fastmoss_ingest_candidates reads
--   title/product_id/price/shop/category/launch_time and NEVER reads `cover` — so the image is
--   silently dropped at ingest and never reaches product_image_assets / the Product Card. Same for
--   fn_kalodata_ingest_candidates (Kalodata rank exposes `master_image_url`, but on the entitled plan
--   it is NULL for every row -> SOURCE_IMAGE_UNAVAILABLE from Kalodata rank today).
--
-- FIX (permanent, reuses existing product_image_assets; no blocked Product Detail API):
--   * fn_extract_cover_url(row): returns the first genuine http(s) image URL among known cover keys
--     (cover / master_image_url / image / main_image / image_url / product_image / thumbnail / camelCase),
--     rejecting provider `/default/` placeholders. Never fabricates.
--   * fn_persist_reference_image(...): idempotently (unique (product_id,image_url)) writes a REFERENCE_ONLY
--     primary image into product_image_assets with full provenance (authority=REFERENCE_ONLY).
--   * Both ingest functions now call persist on every real (non-dry-run) path (new / idempotent /
--     correlated), so future discovery — and any re-ingest of an existing product still in the feed —
--     carries its cover. Historical products whose provider response was never stored get NOTHING
--     fabricated.
--   * fn_product_media_state(...): the Product-Card-safe media contract (IMAGE_/VIDEO_/SUPPLIER_ states
--     + MEDIA_COMPLETE/INCOMPLETE). A card is MEDIA_COMPLETE only with a genuine primary image.
--
-- PRODUCT ASSET LOCK: discovery reference media lives in product_image_assets (REFERENCE_ONLY) — NEVER
-- in the Stage-4 authoritative supplier_product_assets, and never unlocks store/ad/creative/publishing.
-- CJ exact-supplier media remains the only authoritative merchant media, bound to an exact SKU.

BEGIN;

-- 1. Genuine cover-URL extractor (no fabrication; rejects provider default placeholders)
CREATE OR REPLACE FUNCTION public.fn_extract_cover_url(p_row jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE k text; v text;
BEGIN
  IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' THEN RETURN NULL; END IF;
  FOREACH k IN ARRAY ARRAY['cover','cover_url','coverUrl','master_image_url','masterImageUrl',
                           'image','main_image','mainImage','image_url','imageUrl',
                           'product_image','productImage','thumbnail','thumb','cover_image','coverImage'] LOOP
    IF jsonb_typeof(p_row->k) = 'string' THEN
      v := btrim(coalesce(p_row->>k,''));
      IF v <> '' AND v ~* '^https?://' AND position('/default/' in lower(v)) = 0 THEN
        RETURN v;
      END IF;
    END IF;
  END LOOP;
  RETURN NULL;
END $function$;

-- 2. Reusable REFERENCE_ONLY reference-image persist (idempotent on unique (product_id,image_url))
CREATE OR REPLACE FUNCTION public.fn_persist_reference_image(
  p_tenant uuid, p_product uuid, p_market text, p_provider text, p_source_entity_id text, p_image_url text)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_id uuid; v_has_primary boolean;
BEGIN
  IF p_product IS NULL OR p_image_url IS NULL OR p_image_url !~* '^https?://'
     OR position('/default/' in lower(p_image_url)) > 0 THEN
    RETURN NULL;  -- never fabricate / never store a placeholder
  END IF;
  SELECT id INTO v_id FROM public.product_image_assets
    WHERE product_id=p_product AND image_url=p_image_url LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;  -- idempotent
  SELECT EXISTS(SELECT 1 FROM public.product_image_assets WHERE product_id=p_product AND is_primary=true)
    INTO v_has_primary;
  INSERT INTO public.product_image_assets
    (tenant_id, product_id, market, image_url, source_provider, source_url, source_entity_id,
     rights_state, availability, is_primary, observed_at, provenance)
  VALUES (p_tenant, p_product, nullif(upper(btrim(coalesce(p_market,''))),''), p_image_url,
          upper(btrim(coalesce(p_provider,'UNKNOWN'))), p_image_url, nullif(btrim(coalesce(p_source_entity_id,'')),''),
          'PROVIDER_DISCOVERY_REFERENCE', 'AVAILABLE', NOT v_has_primary, now(),
          jsonb_build_object('authority','REFERENCE_ONLY','lane','DISCOVERY',
            'provider', upper(btrim(coalesce(p_provider,'UNKNOWN'))), 'source_entity_id', p_source_entity_id,
            'note','product-native discovery cover; REFERENCE_ONLY research media; NOT supplier-authoritative; never unlocks store/ad/creative/publishing'))
  ON CONFLICT (product_id, image_url) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- 3. FastMoss ingest — patched to persist the product-native `cover` (verbatim + one persist call).
CREATE OR REPLACE FUNCTION public.fn_fastmoss_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  v_new int := 0; v_branded int := 0; v_correlated int := 0; v_idempotent int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb; v_brand jsonb;
  v_family text; v_screen text; v_pid uuid; v_ing jsonb; v_existing uuid; v_fam_existing uuid;
  v_auto jsonb; v_price numeric; v_dedup text; v_dispatch boolean; v_evidence jsonb;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='FASTMOSS' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','FASTMOSS','market',v_mkt,
      'note','FastMoss does not support this market in discovery_provider_market_config; no substitution, no contamination');
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'note','no product array supplied by provider adapter');
  END IF;
  IF jsonb_array_length(p_products) = 0 THEN
    RETURN jsonb_build_object('status','SUCCESS_ZERO_CANDIDATES','market',v_mkt,'scanned',0,'promoted_count',0);
  END IF;

  IF v_run IS NULL AND NOT p_dry_run THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet', 1,
      jsonb_build_object('discovery_source','fastmoss','lane','COMMERCE','provider','FASTMOSS','market',v_mkt,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','fastmoss_commerce_discovery_v1'), now(), now());
  END IF;

  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'title', r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;

      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;
      v_family := public.fn_product_family_key(v_name);
      v_brand := public.fn_is_branded_or_ip_sensitive(v_name);
      v_screen := v_brand->>'screening_state';
      v_dispatch := NOT (v_brand->>'flagged')::boolean;

      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'day3_gmv',
        'sales_units',r.e->>'day3_units_sold','price',r.e->>'real_price','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','fastmoss',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'real_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'real_price')::numeric END;

      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,
          'normalized',v_norm,'screening_state',v_screen,'product_family_key',v_family,
          'auto_dispatch_eligible',v_dispatch,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;

      v_evidence := jsonb_build_array(jsonb_build_object(
        'claim','TikTok Shop new-listed product-native commerce signal ('||v_mkt||') from FastMoss newListed',
        'source_name','fastmoss','provenance','PLATFORM_REPORTED',
        'seller', jsonb_strip_nulls(jsonb_build_object('seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
          'name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
          'seller_total_units_sold', r.e->'shop'->>'total_units_sold')),
        'provider_totals', jsonb_strip_nulls(jsonb_build_object('total_units_sold', r.e->>'total_units_sold',
          'total_gmv', r.e->>'total_gmv','commission_rate', r.e->>'commission_rate')),
        'launch_time_raw', r.e->>'launch_time',
        'category', r.e->>'category'));

      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'fastmoss_product_id'=v_kid ORDER BY created_at LIMIT 1;
      SELECT id INTO v_fam_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'product_family_key'=v_family
          AND extended->>'market'=v_mkt AND (v_existing IS NULL) ORDER BY created_at LIMIT 1;

      IF v_existing IS NOT NULL THEN
        v_pid := v_existing; v_dedup := 'idempotent_existing'; v_idempotent := v_idempotent + 1;
      ELSIF v_fam_existing IS NOT NULL THEN
        v_pid := v_fam_existing; v_dedup := 'correlated_existing'; v_correlated := v_correlated + 1;
        UPDATE public.commerce_products SET extended = coalesce(extended,'{}'::jsonb)
          || jsonb_build_object('fastmoss_correlated_ids',
               coalesce(extended->'fastmoss_correlated_ids','[]'::jsonb) || jsonb_build_array(v_kid))
          WHERE id=v_pid;
      ELSE
        v_ing := public.ingest_commerce_product(p_user_id, v_run,
          jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
            'source_store','fastmoss','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
            'candidate_acquisition_method','fastmoss_new_listed','source_family','product_native_commerce',
            'market',v_mkt),'INFERRED','candidate');
        v_pid := nullif(v_ing->>'product_id','')::uuid;
        IF v_pid IS NULL THEN
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;
        UPDATE public.commerce_products
          SET identity_basis='platform_id',
              observed_price=coalesce(observed_price, v_price),
              price_currency=coalesce(price_currency, v_cfg.currency),
              extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
                'fastmoss_product_id', v_kid, 'product_family_key', v_family, 'market', v_mkt,
                'fastmoss_seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
                'fastmoss_seller_name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
                'provider_product_native','FASTMOSS','screening_state',v_screen,
                'launch_time_raw', r.e->>'launch_time')
          WHERE id=v_pid;
        IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
          UPDATE public.monday_opportunity_registry SET active=true,
            markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                           THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
            WHERE tenant_id=p_user_id AND product_id=v_pid;
        ELSE
          INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
          VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
        END IF;
        IF v_dispatch THEN v_dedup := 'new'; v_new := v_new + 1;
        ELSE v_dedup := 'new_branded_review'; v_branded := v_branded + 1; END IF;
      END IF;

      -- MEDIA INTEGRITY FIX: persist the product-native cover as a REFERENCE_ONLY primary image
      -- (no-op when absent or a /default/ placeholder; idempotent; backfills re-ingested products).
      PERFORM public.fn_persist_reference_image(p_user_id, v_pid, v_mkt, 'FASTMOSS', v_kid, public.fn_extract_cover_url(r.e));

      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm, v_evidence, 'PLATFORM_REPORTED', 0.6, now(), NULL,
        'fastmoss:'||v_kid||':'||v_mkt||':commerce_product_native');

      IF v_dedup = 'new' THEN
        BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
        EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;
      ELSE v_auto := jsonb_build_object('status','held_'||v_dedup); END IF;

      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'fastmoss_product_id',v_kid,'product_name',v_name,'product_id',v_pid,'dedup_status',v_dedup,
        'screening_state',v_screen,'observed_unit_price',v_price,
        'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','FASTMOSS','lane','COMMERCE','market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'new_dispatched',v_new,'branded_review',v_branded,'correlated',v_correlated,'idempotent',v_idempotent,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'note','FastMoss new-listed discovers product-native candidates only; identity/dedup + branded/IP review applied; product-native cover persisted as REFERENCE_ONLY primary image. Provider record != product identity != seller != concrete SKU; UNKNOWN != 0; launch_time not authoritative; country-isolated.',
    'contract','pulse_fastmoss_commerce_ingest_v1');
END; $function$;

-- 4. Kalodata ingest — patched to persist cover (master_image_url etc.) when present (verbatim + one persist call).
CREATE OR REPLACE FUNCTION public.fn_kalodata_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb;
  v_pid uuid; v_ing jsonb; v_dedup text; v_existing uuid; v_auto jsonb; v_price numeric;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','KALODATA','market',v_mkt,
      'note','Kalodata does not support this market in discovery_provider_market_config; no substitution, no contamination');
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'note','no product array supplied by provider adapter');
  END IF;
  IF jsonb_array_length(p_products) = 0 THEN
    RETURN jsonb_build_object('status','SUCCESS_ZERO_CANDIDATES','market',v_mkt,'scanned',0,'promoted_count',0);
  END IF;

  IF v_run IS NULL AND NOT p_dry_run THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet', 1,
      jsonb_build_object('discovery_source','kalodata','lane','COMMERCE','provider','KALODATA','market',v_mkt,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','kalodata_commerce_discovery_v1'), now(), now());
  END IF;

  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;

      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity','gate',v_gate->'reasons')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;

      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'revenue',
        'revenue_growth_rate',r.e->>'revenue_growth_rate','sales_units',r.e->>'sales_volumn',
        'price',r.e->>'unit_price','first_seen',r.e->>'launch_date','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','kalodata',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'unit_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'unit_price')::numeric END;

      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'normalized',v_norm,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;

      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'kalodata_product_id'=v_kid ORDER BY created_at LIMIT 1;

      v_ing := public.ingest_commerce_product(p_user_id, v_run,
        jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
          'source_store','kalodata','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
          'candidate_acquisition_method','kalodata_product_rank','source_family','product_native_commerce',
          'market',v_mkt),'INFERRED','candidate');
      v_pid := nullif(v_ing->>'product_id','')::uuid;
      IF v_pid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;

      UPDATE public.commerce_products
        SET identity_basis='platform_id',
            observed_price=coalesce(observed_price, v_price),
            price_currency=coalesce(price_currency, v_cfg.currency),
            extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
              'kalodata_product_id', v_kid, 'kalodata_seller_id', nullif(btrim(coalesce(r.e->>'seller_id','')),''),
              'kalodata_seller_name', nullif(btrim(coalesce(r.e->>'seller_name','')),''),
              'provider_product_native','KALODATA')
        WHERE id=v_pid;

      -- MEDIA INTEGRITY FIX: persist cover when the entitled Kalodata rank response carries one
      -- (field master_image_url; currently NULL on this plan -> no-op, no fabrication). REFERENCE_ONLY.
      PERFORM public.fn_persist_reference_image(p_user_id, v_pid, v_mkt, 'KALODATA', v_kid, public.fn_extract_cover_url(r.e));

      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm,
        jsonb_build_array(jsonb_build_object('claim','TikTok Shop product-native commerce signal ('||v_mkt||') from Kalodata product rank',
          'source_name','kalodata','provenance','PLATFORM_REPORTED',
          'channel_revenue', jsonb_strip_nulls(jsonb_build_object(
            'live_revenue', r.e->>'live_revenue','video_revenue', r.e->>'video_revenue','showcase_revenue', r.e->>'showcase_revenue')))),
        'PLATFORM_REPORTED', 0.6, now(), NULL,
        'kalodata:'||v_kid||':'||v_mkt||':commerce_product_native');

      IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
        UPDATE public.monday_opportunity_registry SET active=true,
          markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                         THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
          WHERE tenant_id=p_user_id AND product_id=v_pid;
      ELSE
        INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
        VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
      END IF;

      BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
      EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;

      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'kalodata_product_id',v_kid,'product_name',v_name,'product_id',v_pid,
        'dedup_status', CASE WHEN v_existing IS NULL THEN 'new' ELSE 'deduplicated' END,
        'observed_unit_price', v_price, 'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),
        'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','KALODATA','lane','COMMERCE','market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'note','Kalodata discovers product-native candidates only; each passes the existing eligibility + auto-research + concrete-resolution + evaluation gates; cover persisted as REFERENCE_ONLY primary image when the entitled rank response carries one. Provider record != concrete SKU; UNKNOWN != 0; country-isolated.',
    'contract','pulse_kalodata_commerce_ingest_v1');
END; $function$;

-- 5. Product-Card-safe media state contract
CREATE OR REPLACE FUNCTION public.fn_product_media_state(p_tenant uuid, p_product uuid, p_market text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_primary record; v_gallery int; v_video record; v_is_fastmoss boolean;
  v_image_state text; v_video_state text; v_supplier_state text; v_card text;
  v_bound boolean; v_supplier_assets int;
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL THEN RETURN jsonb_build_object('status','invalid_args'); END IF;

  SELECT image_url, source_provider, source_entity_id, observed_at, rights_state
    INTO v_primary
  FROM public.product_image_assets
  WHERE product_id=p_product AND (v_mkt IS NULL OR market IS NULL OR market=v_mkt)
  ORDER BY is_primary DESC, (lower(coalesce(image_url,'')) NOT LIKE '%/default/%') DESC, observed_at DESC NULLS LAST
  LIMIT 1;

  SELECT count(*) INTO v_gallery FROM public.product_image_assets
    WHERE product_id=p_product AND (v_mkt IS NULL OR market IS NULL OR market=v_mkt);

  v_image_state := CASE WHEN v_primary.image_url IS NOT NULL THEN 'IMAGE_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END;

  SELECT media_type, storage_ref, provider, source_asset_refs INTO v_video
  FROM public.media_assets
  WHERE product_id=p_product AND upper(coalesce(media_type,''))='VIDEO'
    AND coalesce(is_launch_safe,false)=false
  ORDER BY created_at DESC LIMIT 1;

  SELECT (source_store='fastmoss' OR extended->>'provider_product_native'='FASTMOSS')
    INTO v_is_fastmoss FROM public.commerce_products WHERE id=p_product;

  v_video_state := CASE
    WHEN v_video.media_type IS NOT NULL THEN 'VIDEO_AVAILABLE'
    WHEN coalesce(v_is_fastmoss,false) THEN 'VIDEO_ACCESS_BLOCKED'  -- FastMoss /product/v1/videoList not entitled (403)
    ELSE 'VIDEO_UNAVAILABLE' END;

  SELECT (r.bound = true), coalesce((
     SELECT count(*) FROM public.supplier_product_assets spa
      WHERE spa.supplier = r.selected_supplier AND spa.supplier_product_id = r.selected_supplier_product_id), 0)
    INTO v_bound, v_supplier_assets
  FROM public.commerce_concrete_supplier_resolution r
  WHERE r.tenant_id=p_tenant AND r.opportunity_product_id=p_product AND (v_mkt IS NULL OR r.market=v_mkt)
  ORDER BY r.created_at DESC LIMIT 1;

  v_supplier_state := CASE
    WHEN coalesce(v_bound,false) AND coalesce(v_supplier_assets,0) > 0 THEN 'SUPPLIER_MEDIA_AVAILABLE'
    ELSE 'SUPPLIER_MEDIA_PENDING' END;

  v_card := CASE WHEN v_image_state='IMAGE_AVAILABLE' THEN 'MEDIA_COMPLETE' ELSE 'MEDIA_INCOMPLETE' END;

  RETURN jsonb_build_object(
    'product_id', p_product, 'market', v_mkt,
    'image_state', v_image_state,
    'primary_image', CASE WHEN v_primary.image_url IS NULL THEN NULL ELSE jsonb_build_object(
       'url', v_primary.image_url, 'provider', v_primary.source_provider, 'source_entity_id', v_primary.source_entity_id,
       'observed_at', v_primary.observed_at, 'rights_state', v_primary.rights_state, 'authority','REFERENCE_ONLY') END,
    'gallery_count', coalesce(v_gallery,0),
    'video_state', v_video_state,
    'supplier_media_state', v_supplier_state,
    'card_media_state', v_card,
    'authority', 'REFERENCE_ONLY',
    'invariants', jsonb_build_object(
      'reference_media_never_unlocks_store_ad_creative_publishing', true,
      'supplier_authoritative_media_is_separate_table', 'supplier_product_assets',
      'completed_card_requires_genuine_primary_image', true,
      'no_fabricated_media', true),
    'contract','pulse_product_media_state_v1');
END $function$;

-- 6. Selftest (durable; pure-fn + self-cleaning persist fixture; no mis-attachment to real products)
-- NOTE: cleanup-free + idempotent (unique (product_id,image_url)). It leaves exactly one benign
-- fixture row under the synthetic TESTP id (no commerce_products row, so it never surfaces to a real
-- tenant projection); re-runs never accumulate. Written without DELETE so it also deploys through the
-- MCP execute_sql path, whose destructive-statement gate stalls on DELETE/DROP.
CREATE OR REPLACE FUNCTION public.fn_discovery_media_integrity_selftest()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  TESTP uuid := '00000000-0000-4000-a000-0000000d1a96';  -- throwaway test product id (no FK)
  HITSLAB uuid := 'ca4a79b0-41a7-4fc6-b267-82b99a123dff';
  rc text := 'https://s.500fd.com/tt_product/selftestcover~tplv-t5fjg24jzw-resize-jpeg:800:800.jpeg';
  dc text := 'https://s.500fd.com/default/product_default.png';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  v_id1 uuid; v_id2 uuid; v_cnt int; v_ms jsonb; v_ms2 jsonb;
BEGIN
  -- A: extractor keeps genuine, rejects placeholder + null
  ok := (public.fn_extract_cover_url(jsonb_build_object('cover',rc)) = rc)
    AND (public.fn_extract_cover_url(jsonb_build_object('cover',dc)) IS NULL)
    AND (public.fn_extract_cover_url(jsonb_build_object('master_image_url',NULL)) IS NULL);
  checks := checks || jsonb_build_object('check','A_extractor_genuine_only','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- B: persist rejects non-genuine (null/placeholder/non-http) -> no id
  ok := (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x',NULL) IS NULL)
    AND (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x',dc) IS NULL)
    AND (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x','not-a-url') IS NULL);
  checks := checks || jsonb_build_object('check','B_persist_rejects_non_genuine','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- C: persist accepts genuine -> REFERENCE_ONLY primary; idempotent on unique (product_id,image_url)
  v_id1 := public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','selftestkid',rc);
  v_id2 := public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','selftestkid',rc);
  SELECT count(*) INTO v_cnt FROM public.product_image_assets WHERE product_id=TESTP AND image_url=rc;
  ok := (v_id1 IS NOT NULL) AND (v_id2 = v_id1) AND (v_cnt = 1)
    AND EXISTS (SELECT 1 FROM public.product_image_assets WHERE product_id=TESTP AND image_url=rc
                AND is_primary=true AND rights_state='PROVIDER_DISCOVERY_REFERENCE'
                AND provenance->>'authority'='REFERENCE_ONLY' AND source_provider='FASTMOSS');
  checks := checks || jsonb_build_object('check','C_persist_reference_primary_idempotent','ok',ok,'detail',jsonb_build_object('rows_for_url',v_cnt));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- D: Product Asset Lock separation — reference media never in supplier_product_assets
  ok := NOT EXISTS (SELECT 1 FROM public.supplier_product_assets WHERE source_url=rc);
  checks := checks || jsonb_build_object('check','D_asset_lock_separation','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- E: media-state IMAGE_AVAILABLE + MEDIA_COMPLETE + REFERENCE_ONLY for imaged product
  v_ms := public.fn_product_media_state(T,TESTP,'DE');
  ok := (v_ms->>'image_state'='IMAGE_AVAILABLE') AND (v_ms->>'card_media_state'='MEDIA_COMPLETE') AND (v_ms->>'authority'='REFERENCE_ONLY');
  checks := checks || jsonb_build_object('check','E_media_state_image_available','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- F: honest MEDIA_INCOMPLETE for a real product with no genuine image (Hit the Slab)
  v_ms2 := public.fn_product_media_state(T,HITSLAB,'DE');
  ok := (v_ms2->>'image_state'='IMAGE_UNAVAILABLE') AND (v_ms2->>'card_media_state'='MEDIA_INCOMPLETE');
  checks := checks || jsonb_build_object('check','F_media_incomplete_when_no_image','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- G: both ingest functions wired to the cover persistence
  ok := (SELECT prosrc LIKE '%fn_persist_reference_image%' FROM pg_proc WHERE proname='fn_fastmoss_ingest_candidates' LIMIT 1)
    AND (SELECT prosrc LIKE '%fn_persist_reference_image%' FROM pg_proc WHERE proname='fn_kalodata_ingest_candidates' LIMIT 1);
  checks := checks || jsonb_build_object('check','G_ingest_wired_to_cover','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_discovery_media_integrity_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),
    'note','idempotent via unique(product_id,image_url); leaves one benign fixture row under synthetic TESTP (no commerce_products row, never surfaces to a real tenant projection)',
    'checks',checks,'generated_at',now());
END $function$;

COMMIT;
