-- mig_292 (2026-11-20): Kalodata Product Rank request builder — request need_image=1 so the entitled
-- rank response carries master_image_url (no additional charge per Kalodata, Andrew Lin 2026-11-20).
-- The ingestion path already persists it as a REFERENCE_ONLY research image via
-- fn_extract_cover_url + fn_persist_reference_image (rights_state PROVIDER_DISCOVERY_REFERENCE;
-- never displaces an existing primary asset; never unlocks store/ad/creative/publishing).
-- Only request_body gains need_image; every other field, the market gate and paging are unchanged.
-- Applied to production 2026-11-20 as migration kalodata_discovery_request_need_image.
CREATE OR REPLACE FUNCTION public.fn_kalodata_discovery_request(p_market text, p_page_number integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record; v_page int := greatest(1, coalesce(p_page_number,1));
BEGIN
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/product/rank',
    'auth','X-API-Key header (backend broker only; never in DB/logs/response)',
    'strategy','early_emerging','page_number',v_page,
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range','last7Day','sort',jsonb_build_object('field','revenue_growth_rate','type','DESC'),
      'page_size',10,'page_number',v_page,'launch_date','<30','need_image',1),
    'note','early/emerging bias: revenue_growth_rate DESC + recent launch; page_number advances to avoid re-buying the same results. need_image=1 requests master_image_url (REFERENCE_ONLY research cover; no extra charge). Candidates only; not opportunity.',
    'contract','pulse_kalodata_request_v3_need_image');
END; $function$
