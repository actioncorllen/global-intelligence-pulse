-- ============================================================================
-- MIG-293 — STRATELOQ-016C.2 · Meta Facebook ORGANIC safe-read contract
-- ----------------------------------------------------------------------------
-- Closes the ONLY gap that blocked the 016C organic-connection UI: the browser
-- had no authenticated, tenant-scoped read path for (a) the Pages discovered
-- during OAuth (needed to render the Page-selection step) and (b) the current
-- Facebook Page organic connection (needed to render the connection card).
--
-- This migration adds READ-ONLY, safe-metadata contracts ONLY. It:
--   * NEVER returns a Page/user access token, secret_ref, Vault identifier,
--     oauth_state, error_detail, Meta App Secret, or any provider credential.
--   * exposes only what the UI needs: Page id/name for selection; connection
--     status / page id / display name / capabilities / lifecycle timestamps.
--   * keeps social_platform_connections FORCE RLS deny-by-default. No new table
--     RLS policy is added; the table is NEVER exposed to the browser directly.
--     Access remains via SECURITY DEFINER functions only.
--   * follows the proven mig_217 pattern: a definer-only CORE (explicit p_tenant,
--     strict tenant scope, deterministically testable) + a thin authenticated
--     wrapper that resolves the caller's tenant server-side via fn__own_tenant().
--
-- Additive only. No data change. No token handling. No advertising surface.
-- Depends on mig_291 (social_platform_connections) and mig_292 (discovered_pages
-- metadata shape, capability/boundary contracts) — both applied in production.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CORE (definer-only) — list discovered Pages for a PENDING_OAUTH connection
--    Returns ONLY safe selection metadata (page_id, page_name). Strict tenant
--    scope + META_FACEBOOK + ORGANIC + PENDING_OAUTH. No cross-tenant read.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_list_discovered_core(
  p_tenant        uuid,
  p_connection_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_meta  jsonb;
  v_pages jsonb;
BEGIN
  IF p_tenant IS NULL OR p_connection_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_unresolved');
  END IF;

  SELECT display_metadata INTO v_meta
  FROM public.social_platform_connections
  WHERE id = p_connection_id
    AND tenant_id = p_tenant                 -- strict tenant scope (no cross-tenant enumeration)
    AND platform = 'META_FACEBOOK'
    AND connection_type = 'ORGANIC'          -- organic only; advertising never returned here
    AND authorization_status = 'PENDING_OAUTH';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pending_connection_not_found');
  END IF;

  -- Project ONLY id -> page_id and name -> page_name. Any other field that may
  -- exist on a discovered-page object (e.g. a defensively-passed token) is
  -- dropped by this explicit projection and can never reach the browser.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'page_id',   pg->>'id',
            'page_name', pg->>'name')), '[]'::jsonb)
    INTO v_pages
  FROM jsonb_array_elements(coalesce(v_meta->'discovered_pages','[]'::jsonb)) AS pg
  WHERE coalesce(pg->>'id','') <> '';

  RETURN jsonb_build_object(
    'ok', true,
    'connection_id', p_connection_id,
    'page_count', jsonb_array_length(v_pages),
    'pages', v_pages);
END $$;

-- ----------------------------------------------------------------------------
-- 2. CORE (definer-only) — the caller-tenant's Meta Facebook ORGANIC connection
--    Returns ONLY safe card metadata. Prefers a CONNECTED row; otherwise the
--    most recent row. Advertising rows are never considered.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_my_facebook_connection_core(
  p_tenant uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  r         record;
  v_conn    jsonb;
  v_pending int;
BEGIN
  IF p_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'connected', false,
      'authorization_status', 'NOT_CONNECTED', 'connection', NULL);
  END IF;

  SELECT id, authorization_status, external_account_id, display_name, capabilities,
         connected_at, expires_at, revoked_at, display_metadata
    INTO r
  FROM public.social_platform_connections
  WHERE tenant_id = p_tenant
    AND platform = 'META_FACEBOOK'
    AND connection_type = 'ORGANIC'          -- organic only; advertising excluded
  ORDER BY (authorization_status = 'CONNECTED') DESC,
           connected_at DESC NULLS LAST,
           updated_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'connected', false,
      'authorization_status', 'NOT_CONNECTED', 'connection', NULL);
  END IF;

  -- page_count is only meaningful while a selection is pending
  v_pending := jsonb_array_length(coalesce(r.display_metadata->'discovered_pages','[]'::jsonb));

  -- SAFE fields ONLY. secret_ref, oauth_state, error_detail and raw
  -- display_metadata are deliberately NOT included.
  v_conn := jsonb_build_object(
    'connection_id',        r.id,
    'authorization_status', r.authorization_status,
    'page_id',              r.external_account_id,
    'display_name',         r.display_name,
    'capabilities',         coalesce(r.capabilities, '[]'::jsonb),
    'connected_at',         r.connected_at,
    'expires_at',           r.expires_at,
    'revoked_at',           r.revoked_at,
    'selection_required',   coalesce((r.display_metadata->>'selection_required')::boolean, false),
    'page_count',           v_pending);

  RETURN jsonb_build_object(
    'ok', true,
    'connected', (r.authorization_status = 'CONNECTED'),
    'authorization_status', r.authorization_status,
    'connection', v_conn);
END $$;

-- ----------------------------------------------------------------------------
-- 3. PUBLIC WRAPPERS (authenticated) — resolve the caller's tenant server-side
--    via fn__own_tenant() (auth.uid()) and delegate to the definer-only CORE.
--    The client can never assert a tenant.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_list_discovered(
  p_connection_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_tenant uuid := public.fn__own_tenant();
BEGIN
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_unresolved');
  END IF;
  RETURN public.fn_social_meta_list_discovered_core(v_tenant, p_connection_id);
END $$;

CREATE OR REPLACE FUNCTION public.fn_social_my_facebook_connection()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_tenant uuid := public.fn__own_tenant();
BEGIN
  -- Unresolved tenant reports NOT_CONNECTED (safe, no enumeration) so the card
  -- renders an honest empty state rather than an error.
  RETURN public.fn_social_my_facebook_connection_core(v_tenant);
END $$;

-- ----------------------------------------------------------------------------
-- 4. LEAST-PRIVILEGE GRANTS
--    CORE: definer-only (revoke PUBLIC/anon/authenticated).
--    WRAPPERS: authenticated only (the browser read entrypoints).
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  -- cores: definer-only
  EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_list_discovered_core(uuid,uuid) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_my_facebook_connection_core(uuid) FROM PUBLIC';
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_list_discovered_core(uuid,uuid) FROM anon';          EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_list_discovered_core(uuid,uuid) FROM authenticated'; EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_my_facebook_connection_core(uuid) FROM anon';             EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_my_facebook_connection_core(uuid) FROM authenticated';    EXCEPTION WHEN undefined_object THEN NULL; END;

  -- wrappers: browser entrypoints — authenticated only (revoke PUBLIC/anon first)
  EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_list_discovered(uuid) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_my_facebook_connection() FROM PUBLIC';
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_list_discovered(uuid) FROM anon';       EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_my_facebook_connection() FROM anon';         EXCEPTION WHEN undefined_object THEN NULL; END;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_meta_list_discovered(uuid) TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_my_facebook_connection() TO authenticated';
END $$;

-- ----------------------------------------------------------------------------
-- 5. ZERO-COST DETERMINISTIC SELFTEST — fn_social_meta_facebook_read_selftest()
--    No live Meta call. Inserts synthetic rows, asserts the safe-read contract
--    and least-privilege grants, then cleans up. Proves the security boundary.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_facebook_read_selftest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_checks   jsonb := '[]'::jsonb;
  v_pass     boolean := true;
  b          boolean;
  v_tenant   uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
  v_adv_ten  uuid := gen_random_uuid();
  v_pending  uuid;
  v_conn     uuid;
  v_adv      uuid;
  v_out      jsonb;
  v_txt      text;
  v_secret   text;
  v_state    text := encode(extensions.digest('mig293-'||gen_random_uuid()::text,'sha256'),'hex');
  v_keys     text;
BEGIN
  v_secret := 'social:'||gen_random_uuid()::text||':user';   -- a NON-token Vault name

  -- Synthetic PENDING_OAUTH connection with discovered pages. The discovered
  -- object intentionally carries an extra 'access_token' field to prove the
  -- projection strips everything except id/name.
  INSERT INTO public.social_platform_connections(
    tenant_id, platform, connection_type, authorization_status, secret_ref, oauth_state,
    display_metadata)
  VALUES (v_tenant, 'META_FACEBOOK', 'ORGANIC', 'PENDING_OAUTH', v_secret, v_state,
    jsonb_build_object('selection_required', true, 'discovered_pages', jsonb_build_array(
      jsonb_build_object('id','PID_1','name','Strateloq Page','tasks',jsonb_build_array('CREATE_CONTENT'),
                         'access_token','LEAK_eyJhbGciNEVER'),
      jsonb_build_object('id','PID_2','name','Second Page','tasks',jsonb_build_array('ANALYZE')))))
  RETURNING id INTO v_pending;

  -- (1) authenticated same-tenant read succeeds (via CORE with the real tenant)
  v_out := public.fn_social_meta_list_discovered_core(v_tenant, v_pending);
  b := (v_out->>'ok' = 'true')
       AND (v_out->>'page_count' = '2')
       AND (v_out->'pages'->0->>'page_id' = 'PID_1')
       AND (v_out->'pages'->0->>'page_name' = 'Strateloq Page');
  v_checks := v_checks || jsonb_build_object('check','same_tenant_discovered_read_ok','pass',b); v_pass := v_pass AND b;

  -- (2) cross-tenant connection id is rejected / not returned
  v_out := public.fn_social_meta_list_discovered_core(v_other, v_pending);
  b := (v_out->>'ok' = 'false') AND (v_out->>'error' = 'pending_connection_not_found');
  v_checks := v_checks || jsonb_build_object('check','cross_tenant_discovered_rejected','pass',b); v_pass := v_pass AND b;

  -- (3) discovered Page list exposes ONLY safe id/name (no extra keys, no token)
  v_out := public.fn_social_meta_list_discovered_core(v_tenant, v_pending);
  SELECT string_agg(k, ',' ORDER BY k) INTO v_keys
  FROM jsonb_object_keys(v_out->'pages'->0) AS k;
  v_txt := v_out::text;
  b := (v_keys = 'page_id,page_name')
       AND position('access_token' in v_txt) = 0
       AND position('LEAK_eyJhbGciNEVER' in v_txt) = 0
       AND position('eyJ' in v_txt) = 0;
  v_checks := v_checks || jsonb_build_object('check','discovered_pages_safe_id_name_only','pass',b); v_pass := v_pass AND b;

  -- (4) secret_ref / oauth_state never appear in the discovered-read output
  v_txt := public.fn_social_meta_list_discovered_core(v_tenant, v_pending)::text;
  b := position('secret_ref' in v_txt) = 0
       AND position(v_secret in v_txt) = 0
       AND position('oauth_state' in v_txt) = 0
       AND position(v_state in v_txt) = 0;
  v_checks := v_checks || jsonb_build_object('check','discovered_no_secret_or_state','pass',b); v_pass := v_pass AND b;

  -- Promote the pending row to a CONNECTED connection for card-read tests.
  UPDATE public.social_platform_connections
    SET authorization_status = 'CONNECTED', external_account_id = 'PID_1',
        display_name = 'Strateloq Page', capabilities = '["READ_PROFILE","PUBLISH_IMAGE"]'::jsonb,
        connected_at = now(), expires_at = NULL,
        display_metadata = jsonb_build_object('page_tasks', jsonb_build_array('CREATE_CONTENT'),
                                              'selection_required', false, 'verified_readonly', true)
    WHERE id = v_pending;
  v_conn := v_pending;

  -- (5) card read: connected state returns safe fields; NO secret_ref/state/token
  v_out := public.fn_social_my_facebook_connection_core(v_tenant);
  v_txt := v_out::text;
  b := (v_out->>'connected' = 'true')
       AND (v_out->'connection'->>'page_id' = 'PID_1')
       AND (v_out->'connection'->>'display_name' = 'Strateloq Page')
       AND (v_out->'connection'->'capabilities' ? 'PUBLISH_IMAGE')
       AND position('secret_ref' in v_txt) = 0
       AND position(v_secret in v_txt) = 0
       AND position('oauth_state' in v_txt) = 0
       AND position('eyJ' in v_txt) = 0;
  v_checks := v_checks || jsonb_build_object('check','connection_card_safe_fields_only','pass',b); v_pass := v_pass AND b;

  -- (6) cross-tenant card read returns NOT_CONNECTED (no leak of another tenant)
  v_out := public.fn_social_my_facebook_connection_core(v_other);
  b := (v_out->>'connected' = 'false')
       AND (v_out->>'authorization_status' = 'NOT_CONNECTED')
       AND (jsonb_typeof(v_out->'connection') = 'null');
  v_checks := v_checks || jsonb_build_object('check','cross_tenant_card_not_connected','pass',b); v_pass := v_pass AND b;

  -- (7) advertising connection is NEVER returned by the organic RPCs
  INSERT INTO public.social_platform_connections(
    tenant_id, platform, connection_type, authorization_status, external_account_id,
    display_name, capabilities, connected_at)
  VALUES (v_adv_ten, 'META_FACEBOOK', 'ADVERTISING', 'CONNECTED', 'ADACC_1',
    'Ad Account', '["ACTIVATE_CAMPAIGN"]'::jsonb, now())
  RETURNING id INTO v_adv;
  b := (public.fn_social_my_facebook_connection_core(v_adv_ten)->>'connected' = 'false')
       AND (jsonb_typeof(public.fn_social_my_facebook_connection_core(v_adv_ten)->'connection') = 'null')
       AND (public.fn_social_meta_list_discovered_core(v_adv_ten, v_adv)->>'error' = 'pending_connection_not_found');
  v_checks := v_checks || jsonb_build_object('check','advertising_excluded_from_organic_read','pass',b); v_pass := v_pass AND b;

  -- (8) revoked / expired states represented truthfully
  UPDATE public.social_platform_connections
    SET authorization_status = 'REVOKED', revoked_at = now() WHERE id = v_conn;
  v_out := public.fn_social_my_facebook_connection_core(v_tenant);
  b := (v_out->>'connected' = 'false')
       AND (v_out->'connection'->>'authorization_status' = 'REVOKED')
       AND (v_out->'connection'->>'revoked_at' IS NOT NULL);
  UPDATE public.social_platform_connections
    SET authorization_status = 'EXPIRED', revoked_at = NULL, expires_at = now() - interval '1 day'
    WHERE id = v_conn;
  b := b AND (public.fn_social_my_facebook_connection_core(v_tenant)->'connection'->>'authorization_status' = 'EXPIRED');
  v_checks := v_checks || jsonb_build_object('check','revoked_expired_truthful','pass',b); v_pass := v_pass AND b;

  -- (9) least privilege: authenticated CAN exec wrappers; anon CANNOT; and
  --     neither anon nor authenticated can exec the definer-only cores.
  b := has_function_privilege('authenticated', 'public.fn_social_meta_list_discovered(uuid)', 'EXECUTE')
       AND has_function_privilege('authenticated', 'public.fn_social_my_facebook_connection()', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.fn_social_meta_list_discovered(uuid)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.fn_social_my_facebook_connection()', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public.fn_social_meta_list_discovered_core(uuid,uuid)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.fn_social_meta_list_discovered_core(uuid,uuid)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public.fn_social_my_facebook_connection_core(uuid)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.fn_social_my_facebook_connection_core(uuid)', 'EXECUTE');
  v_checks := v_checks || jsonb_build_object('check','least_privilege_grants','pass',b); v_pass := v_pass AND b;

  -- (10) FORCE RLS on social_platform_connections remains enabled (never weakened)
  SELECT (c.relrowsecurity AND c.relforcerowsecurity) INTO b
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'social_platform_connections';
  v_checks := v_checks || jsonb_build_object('check','force_rls_intact','pass',coalesce(b,false));
  v_pass := v_pass AND coalesce(b,false);

  -- (11) 016B organic/advertising capability boundary still intact
  b := (public.fn_social_connection_capabilities('META_FACEBOOK','ORGANIC')->'capabilities' ? 'PUBLISH_IMAGE')
       AND NOT (public.fn_social_connection_capabilities('META_FACEBOOK','ORGANIC')->'capabilities' ? 'ACTIVATE_CAMPAIGN')
       AND (public.fn_social_platform_external_requirements('META_FACEBOOK','ADVERTISING')->>'stage_gate' = 'BLOCKED');
  v_checks := v_checks || jsonb_build_object('check','organic_advertising_boundary_intact','pass',b); v_pass := v_pass AND b;

  -- cleanup synthetic rows
  DELETE FROM public.social_platform_connections WHERE id IN (v_pending, v_adv);

  RETURN jsonb_build_object('suite','meta_facebook_organic_safe_read','passed',v_pass,
    'total', jsonb_array_length(v_checks), 'checks', v_checks);
END $$;

DO $$ BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_facebook_read_selftest() FROM PUBLIC';
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_facebook_read_selftest() FROM anon';          EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'REVOKE ALL ON FUNCTION public.fn_social_meta_facebook_read_selftest() FROM authenticated'; EXCEPTION WHEN undefined_object THEN NULL; END;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_meta_facebook_read_selftest() TO service_role';
END $$;

-- ============================================================================
-- END MIG-293
-- ============================================================================
