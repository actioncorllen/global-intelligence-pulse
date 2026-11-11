-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_product_detail_fetch.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 7 — Product Detail fetch wiring)
--
-- PURPOSE: wire the MISSING Product Detail fetch path so the already-deployed persister
-- public.fn_persist_kalodata_product_detail(tenant, product, market, detail) actually
-- receives a product/detail response. Reuses, never duplicates, existing production
-- infrastructure:
--   * market gate      -> discovery_provider_market_config (same as product/rank)
--   * auth             -> secret-key header + KALODATA_SECRET_KEY (edge only; see edge fn)
--   * persistence      -> fn_persist_kalodata_product_detail (REFERENCE_ONLY; tenant-isolated)
--   * usage accounting -> fn_kalodata_record_usage + fn_kalodata_record_lane_outcome
--   * reference image  -> fn_persist_reference_image (inside the persister)
--
-- VERIFIED (safe to encode): endpoint https://www.kalodata.com/openapi/v1/tiktok/product/detail;
-- auth = secret-key header; the product/detail RESPONSE schema (product_id, master_image_url,
-- product_description, attributes[], variants[], pri/sec/ter_cate_id) from the deployed persister;
-- Kalodata's product-id field name is `product_id` (used in both rank and detail responses);
-- region/language/currency come from discovery_provider_market_config exactly as product/rank does.
--
-- NOT VERIFIED (flagged, never guessed into a live call): the EXACT product/detail REQUEST
-- parameter SET. This builder assembles a request from the verified field names above and marks
-- request_params_verified=false. Confirm against Kalodata Open Center docs before the first live
-- call. Nothing here makes a chargeable call; the edge function is not deployed.
--
-- APPLY ONLY via the canonical Supabase migration pipeline (not by replaying this repo).
-- ============================================================================

-- Request builder: market-gated, secret-free (mirrors fn_kalodata_discovery_request).
CREATE OR REPLACE FUNCTION public.fn_kalodata_detail_request(p_market text, p_kalodata_product_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record; v_pid text := nullif(btrim(coalesce(p_kalodata_product_id,'')),'');
BEGIN
  IF v_pid IS NULL THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','reason','MISSING_PRODUCT_ID'); END IF;
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/product/detail',
    'auth','secret-key header (backend broker only; never in DB/logs/response)',
    -- region/language/currency: verified rank-request fields. product_id: Kalodata's own verified
    -- product-id field name. EXACT param set pending Open Center confirmation (see flag below).
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),
      'currency',c.currency,'product_id',v_pid),
    'request_params_verified', false,
    'verify_before_live','Confirm the product/detail request parameters against Kalodata Open Center before any paid call.',
    'contract','pulse_kalodata_detail_request_v1_provisional');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_detail_request(text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_detail_request(text,text) TO authenticated, service_role;

-- Self-test: request-builder gating + persister guards (verified parts only; no commerce_products
-- insert, so it is safe to run in any environment). The successful persist MAPPING is covered by the
-- ephemeral harness that stubs commerce_products.
CREATE OR REPLACE FUNCTION public.fn_kalodata_product_detail_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; r_us jsonb; r_ie jsonb; r_ca jsonb; r_noid jsonb;
  v_sample jsonb := jsonb_build_object('product_id','kd_detail_1','master_image_url','https://cdn.kalodata.example/d.jpg',
    'product_description', jsonb_build_array('line a','line b'),
    'attributes', jsonb_build_array(jsonb_build_object('k','color','v','black')),
    'variants', jsonb_build_array(jsonb_build_object('sku','s1')),
    'pri_cate_id','1','sec_cate_id','12','ter_cate_id','123');
  p_notowned jsonb; p_missing jsonb;
BEGIN
  r_us   := public.fn_kalodata_detail_request('US','kd_detail_1');
  r_ie   := public.fn_kalodata_detail_request('IE','kd_detail_1');   -- disabled market
  r_ca   := public.fn_kalodata_detail_request('CA','kd_detail_1');   -- not covered
  r_noid := public.fn_kalodata_detail_request('US', NULL);

  v := v || jsonb_build_object('case','detail_request_enabled_market','pass',
        ((r_us->>'ok')::boolean = true AND r_us->>'endpoint' ~* 'tiktok/product/detail'
         AND r_us->'request_body'->>'region'='US' AND r_us->'request_body'->>'product_id'='kd_detail_1'
         AND (r_us->>'request_params_verified')::boolean = false));
  v := v || jsonb_build_object('case','detail_request_disabled_market_blocked','pass',
        (r_ie->>'reason'='UNSUPPORTED_MARKET' AND (r_ie->>'ok')::boolean = false));
  v := v || jsonb_build_object('case','detail_request_uncovered_market_blocked','pass',
        (r_ca->>'reason'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('case','detail_request_requires_product_id','pass',
        (r_noid->>'reason'='MISSING_PRODUCT_ID'));
  v := v || jsonb_build_object('case','detail_request_never_carries_secret','pass',
        (NOT (r_us->'request_body' ? 'secret') AND NOT (r_us->'request_body' ? 'secret-key')
         AND NOT (r_us->'request_body' ? 'key') AND NOT (r_us->'request_body' ? 'authorization')));
  -- persister tenant-isolation guard (no row exists for this sentinel -> not_owned); reuse, not duplicate
  p_notowned := public.fn_persist_kalodata_product_detail(
    '00000000-0000-4000-8000-0000000000aa'::uuid, '00000000-0000-4000-8000-0000000000bb'::uuid, 'US', v_sample);
  v := v || jsonb_build_object('case','persister_tenant_isolation_guard','pass', (p_notowned->>'reason'='not_owned'));
  p_missing := public.fn_persist_kalodata_product_detail(
    '00000000-0000-4000-8000-0000000000aa'::uuid, '00000000-0000-4000-8000-0000000000bb'::uuid, 'US', '[]'::jsonb);
  v := v || jsonb_build_object('case','persister_rejects_non_object_detail','pass', (p_missing->>'reason'='missing_args'));

  RETURN jsonb_build_object('suite','kalodata_product_detail_fetch',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'request_params_verified', false,
    'note','request-builder + persister guards (verified). Live fetch is gated on confirmed detail request params + chargeable-call approval + deploy via the canonical pipeline.',
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_product_detail_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_product_detail_selftest() TO service_role;
