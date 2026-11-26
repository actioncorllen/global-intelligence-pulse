-- mig_369 — 2026-11-26 — GPD.07 (BE313 T2): gated, tenant-isolated, country-isolated reader for the
-- Kalodata Product Detail social-attention counts (creator_number / video_number / live_number), plus a
-- deterministic selftest. INTERNAL / NOT customer-released: this reader is the rights+isolation chokepoint
-- the (gated, not-yet-deployed) frontend panel will call; shipping the panel to subscribers remains a
-- separate founder release decision. Full DDL (authoritative) — applied via apply_migration.
--
-- Enforcement:
--   * tenant access     — an authenticated caller can ONLY read their own tenant (auth.uid() wins; p_user_id
--                         is honoured only when auth.uid() is null, i.e. service_role/test context).
--   * source rights      — KALODATA.display_derived_cleared must be TRUE, else state=RIGHTS_BLOCKED (no counts).
--   * country isolation  — the product's stored market AND the stored detail's own product_region must BOTH
--                         equal the requested market; otherwise UNAVAILABLE (never borrow another market's data).
--   * genuine zero vs missing — a present numeric count (incl. 0) is returned as a number with *_present=true;
--                         an absent key is returned as null with *_present=false.
--   * honest unavailable — product/market with no applicable Kalodata detail → UNAVAILABLE_NO_EVIDENCE
--                         (covers GB/IE/IT and any product never ingested).
-- No media URLs, descriptions or images are returned (no raw-media reuse). RLS/PAL untouched.

CREATE OR REPLACE FUNCTION public.fn_gpd07_social_attention_display(
  p_product_id uuid,
  p_market text,
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid;
  v_market text := upper(btrim(coalesce(p_market, '')));
  v_rights boolean;
  v_row public.commerce_products%rowtype;
  v_detail jsonb;
  v_region text;
  v_stored_market text;
  v_creator_present boolean;
  v_video_present boolean;
  v_live_present boolean;
  v_creator numeric;
  v_video numeric;
  v_live numeric;
  c_label constant text := 'TikTok social attention / promotional activity, not verified market demand.';
BEGIN
  -- tenant: authenticated user is pinned to their own id; service_role/test may supply p_user_id
  v_tenant := coalesce(auth.uid(), p_user_id);
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'state', 'NOT_AUTHENTICATED');
  END IF;
  IF v_market = '' THEN
    RETURN jsonb_build_object('ok', false, 'state', 'INVALID_MARKET');
  END IF;

  -- rights gate: Kalodata derived display must be cleared
  SELECT display_derived_cleared INTO v_rights
  FROM public.catalogue_source_rights
  WHERE source_provider = 'KALODATA'
  LIMIT 1;
  IF coalesce(v_rights, false) = false THEN
    RETURN jsonb_build_object('ok', false, 'state', 'RIGHTS_BLOCKED', 'provider', 'KALODATA',
      'market', v_market, 'label', c_label);
  END IF;

  -- tenant-scoped product fetch (country/ownership isolation starts here)
  SELECT * INTO v_row
  FROM public.commerce_products
  WHERE id = p_product_id AND user_id = v_tenant
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'state', 'NOT_OWNED_OR_NOT_FOUND', 'market', v_market);
  END IF;

  v_stored_market := upper(btrim(coalesce(v_row.extended->>'market', '')));
  v_detail := v_row.extended->'kalodata_detail';

  -- country isolation #1: the product's own market must equal the requested market
  IF v_stored_market <> v_market THEN
    RETURN jsonb_build_object('ok', true, 'state', 'UNAVAILABLE_NO_EVIDENCE', 'market', v_market,
      'reason', 'market_mismatch', 'provider', 'KALODATA', 'label', c_label);
  END IF;

  -- no Kalodata detail for this product/market (e.g. GB/IE/IT or never ingested)
  IF v_detail IS NULL OR jsonb_typeof(v_detail) <> 'object' THEN
    RETURN jsonb_build_object('ok', true, 'state', 'UNAVAILABLE_NO_EVIDENCE', 'market', v_market,
      'provider', 'KALODATA', 'label', c_label);
  END IF;

  -- country isolation #2: the stored detail's own region tag must equal the requested market
  v_region := lower(btrim(coalesce(v_detail->>'product_region', '')));
  IF v_region <> lower(v_market) THEN
    RETURN jsonb_build_object('ok', true, 'state', 'UNAVAILABLE_REGION_MISMATCH', 'market', v_market,
      'detail_region', v_region, 'provider', 'KALODATA', 'label', c_label);
  END IF;

  -- genuine zero vs missing, per count (present numeric incl. 0 => value+present; absent => null+not-present)
  -- coalesce so an absent key yields present=false (not NULL): genuine zero stays present=true
  v_creator_present := coalesce(jsonb_typeof(v_detail->'creator_number') = 'number', false);
  v_video_present   := coalesce(jsonb_typeof(v_detail->'video_number')   = 'number', false);
  v_live_present    := coalesce(jsonb_typeof(v_detail->'live_number')    = 'number', false);
  v_creator := CASE WHEN v_creator_present THEN (v_detail->>'creator_number')::numeric ELSE NULL END;
  v_video   := CASE WHEN v_video_present   THEN (v_detail->>'video_number')::numeric   ELSE NULL END;
  v_live    := CASE WHEN v_live_present    THEN (v_detail->>'live_number')::numeric     ELSE NULL END;

  RETURN jsonb_build_object(
    'ok', true,
    'state', 'AVAILABLE',
    'provider', 'KALODATA',
    'attribution', 'Kalodata',
    'market', v_market,
    'product_id', p_product_id,
    'kalodata_product_id', v_row.extended->>'kalodata_product_id',
    'product_name', v_detail->>'product_name',
    'creator_number', v_creator,
    'video_number', v_video,
    'live_number', v_live,
    'creator_present', v_creator_present,
    'video_present', v_video_present,
    'live_present', v_live_present,
    'observation_window', 'last7Day',
    'acquired_at', v_detail->'provenance'->>'retrieved_at',
    'label', c_label
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_gpd07_social_attention_display(uuid, text, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.fn_gpd07_social_attention_display(uuid, text, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------
-- Deterministic selftest. Uses the two genuine BE312 rows and rolled-back savepoints (no persisted test
-- data, no flag flip survives) to assert: availability, exact counts, both country-isolation guards,
-- genuine-zero-vs-missing, and the rights-blocked branch.
CREATE OR REPLACE FUNCTION public.fn_gpd07_social_attention_selftest()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  c_tenant constant uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  c_de constant uuid := 'caa240db-1970-4caf-9db3-8cbe394a6a7a';
  c_us constant uuid := '7ec7ad53-ea9d-4647-a2b9-762b340778ac';
  v jsonb;
  v_zm jsonb;
  v_blocked_state text := NULL;
  checks jsonb := '[]'::jsonb;
  n_pass int := 0;
  n_fail int := 0;
BEGIN
  -- 1) DE available with exact counts + region
  v := public.fn_gpd07_social_attention_display(c_de, 'DE', c_tenant);
  IF (v->>'state')='AVAILABLE' AND (v->>'creator_number')='109' AND (v->>'video_number')='220'
     AND (v->>'live_number')='124' AND (v->>'market')='DE' AND (v->>'attribution')='Kalodata'
     AND (v->>'label') LIKE 'TikTok social attention%'
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','DE_available', 'got', v); END IF;

  -- 2) US available with exact counts + region
  v := public.fn_gpd07_social_attention_display(c_us, 'US', c_tenant);
  IF (v->>'state')='AVAILABLE' AND (v->>'creator_number')='424' AND (v->>'video_number')='341'
     AND (v->>'live_number')='1223' AND (v->>'market')='US'
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','US_available', 'got', v); END IF;

  -- 3) country isolation: DE product requested as US => NO data, no fallback
  v := public.fn_gpd07_social_attention_display(c_de, 'US', c_tenant);
  IF (v->>'state') LIKE 'UNAVAILABLE%' AND (v->'creator_number') IS NULL
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','DE_as_US_isolated', 'got', v); END IF;

  -- 4) country isolation: US product requested as DE => NO data, no fallback
  v := public.fn_gpd07_social_attention_display(c_us, 'DE', c_tenant);
  IF (v->>'state') LIKE 'UNAVAILABLE%' AND (v->'creator_number') IS NULL
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','US_as_DE_isolated', 'got', v); END IF;

  -- 5) honest unavailable for a market with no evidence (GB) on a real product
  v := public.fn_gpd07_social_attention_display(c_de, 'GB', c_tenant);
  IF (v->>'state')='UNAVAILABLE_NO_EVIDENCE' AND (v->'creator_number') IS NULL
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','GB_unavailable', 'got', v); END IF;

  -- 6) cross-tenant isolation: foreign tenant cannot read the DE product
  v := public.fn_gpd07_social_attention_display(c_de, 'DE', '00000000-0000-0000-0000-000000000000'::uuid);
  IF (v->>'state')='NOT_OWNED_OR_NOT_FOUND'
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','cross_tenant_blocked', 'got', v); END IF;

  -- 7) genuine zero vs missing (savepoint; rolled back — real DE counts restored)
  BEGIN
    UPDATE public.commerce_products
      SET extended = jsonb_set(
            jsonb_set(
              (extended #- '{kalodata_detail,video_number}'),              -- video_number REMOVED => missing
              '{kalodata_detail,creator_number}', '0'::jsonb, true),       -- creator_number = 0 => genuine zero
            '{kalodata_detail,live_number}', '7'::jsonb, true)
      WHERE id = c_de AND user_id = c_tenant;
    v_zm := public.fn_gpd07_social_attention_display(c_de, 'DE', c_tenant);
    RAISE EXCEPTION 'pulse_selftest_rollback';   -- force rollback of the synthetic UPDATE
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- subtransaction (the UPDATE) rolled back; v_zm keeps its assigned value
  END;
  IF (v_zm->>'state')='AVAILABLE'
     AND (v_zm->>'creator_number')='0' AND (v_zm->>'creator_present')='true'      -- genuine zero
     AND (v_zm->'video_number') = 'null'::jsonb AND (v_zm->>'video_present')='false'  -- missing
     AND (v_zm->>'live_number')='7'
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','zero_vs_missing', 'got', v_zm); END IF;

  -- 8) rights-blocked branch (savepoint; flag flip rolled back)
  BEGIN
    UPDATE public.catalogue_source_rights SET display_derived_cleared = false WHERE source_provider='KALODATA';
    v_blocked_state := public.fn_gpd07_social_attention_display(c_de, 'DE', c_tenant)->>'state';
    RAISE EXCEPTION 'pulse_selftest_rollback';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the flag flip is rolled back; KALODATA.display_derived_cleared stays TRUE
  END;
  IF v_blocked_state = 'RIGHTS_BLOCKED'
  THEN n_pass:=n_pass+1; ELSE n_fail:=n_fail+1; checks := checks || jsonb_build_object('check','rights_blocked', 'got', v_blocked_state); END IF;

  RETURN jsonb_build_object(
    'suite', 'fn_gpd07_social_attention_selftest',
    'passed', n_pass,
    'failed', n_fail,
    'ok', (n_fail = 0),
    'failures', checks
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_gpd07_social_attention_selftest() FROM public;
GRANT EXECUTE ON FUNCTION public.fn_gpd07_social_attention_selftest() TO service_role;
