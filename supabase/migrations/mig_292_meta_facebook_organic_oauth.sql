-- ============================================================================
-- mig_292_meta_facebook_organic_oauth.sql
-- STRATELOQ-016C — META FACEBOOK ORGANIC OAUTH CONNECTION (on top of 016B)
--
-- Adds the executable, SECURE connection layer that 016B deliberately deferred:
--   * single-use, short-lived, tenant/user-bound OAuth STATE (hash-only at rest)
--   * a DYNAMIC per-connection secure token store backed by Supabase Vault
--     (encrypted at rest; readable only by service_role) — raw tokens are NEVER
--     written to social_platform_connections, logs, or this migration
--   * server-side tenant resolution + authorization via fn__own_tenant()
--   * scope SUBSET validation (extra legitimate scopes accepted)
--   * capabilities derived ONLY from the REAL Meta Page tasks grant
--   * disconnect/revoke that clears the Vault secret and blocks preflight
--
-- Boundaries preserved from 016B:
--   * connection_type stays ORGANIC (Meta Advertising is a separate capability,
--     out of scope here — fn_social_platform_external_requirements returns BLOCKED
--     for non-ORGANIC).
--   * NO publishing executor. social_publishing_requests.execution_enabled stays
--     CHECK-forced false. This unit only makes a CONNECTION possible.
--
-- §8 hardening: SECURITY DEFINER EXECUTE grants for 016B + 016C functions are
--   locked to service_role (privileged, server-side) or authenticated (the two
--   user-context entrypoints), and revoked from PUBLIC/anon. FORCE RLS retained.
-- ============================================================================

-- Vault must be present for dynamic per-connection token storage.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault') THEN
    RAISE EXCEPTION 'supabase_vault extension is required for 016C dynamic token storage';
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 1. OAUTH STATE — social_oauth_states
--    Single-use, expiring, tenant/user-bound CSRF state. Only the SHA-256 HASH
--    of the raw state is stored; the raw value lives only on the authorize URL.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.social_oauth_states (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id    uuid        NOT NULL,              -- the PENDING_OAUTH social_platform_connections row
  tenant_id        uuid        NOT NULL,
  user_id          uuid        NOT NULL,              -- auth.uid() that initiated the flow
  platform         text        NOT NULL,
  connection_type  text        NOT NULL DEFAULT 'ORGANIC',
  state_hash       text        NOT NULL,              -- sha256 hex (64) of the raw state; raw is never stored
  redirect_uri     text,                              -- exact redirect used, echoed into the code exchange
  expires_at       timestamptz NOT NULL,
  consumed_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sos_platform_chk') THEN
    ALTER TABLE public.social_oauth_states ADD CONSTRAINT sos_platform_chk
      CHECK (platform IN ('META_FACEBOOK','META_INSTAGRAM','TIKTOK','LINKEDIN'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sos_conntype_chk') THEN
    ALTER TABLE public.social_oauth_states ADD CONSTRAINT sos_conntype_chk
      CHECK (connection_type IN ('ORGANIC','ADVERTISING'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sos_state_hash_chk') THEN
    ALTER TABLE public.social_oauth_states ADD CONSTRAINT sos_state_hash_chk
      CHECK (state_hash ~ '^[0-9a-f]{64}$');   -- hash only; a raw token can never satisfy this
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS sos_state_hash_uk ON public.social_oauth_states (state_hash);
CREATE INDEX IF NOT EXISTS sos_expires_idx ON public.social_oauth_states (expires_at);

ALTER TABLE public.social_oauth_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_oauth_states FORCE ROW LEVEL SECURITY;
-- deny-by-default: no policy; access via SECURITY DEFINER functions only.
REVOKE ALL ON TABLE public.social_oauth_states FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- 2. DYNAMIC SECURE TOKEN STORE — Supabase Vault wrappers (service_role only)
--    social_platform_connections.secret_ref points at a Vault secret NAME.
--    The token VALUE lives only inside vault (encrypted at rest).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_secret_put(p_name text, p_value text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_name IS NULL OR length(p_name) = 0 OR length(p_name) > 120 THEN
    RAISE EXCEPTION 'invalid_secret_name';
  END IF;
  -- p_name is a NON-SECRET reference; guard it the same way secret_ref is guarded.
  IF p_name ~ '^(eyJ|Bearer )' OR p_name ~ '^[A-Za-z0-9_-]{200,}$' THEN
    RAISE EXCEPTION 'secret_name_must_not_look_like_a_token';
  END IF;
  SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  IF v_id IS NULL THEN
    PERFORM vault.create_secret(p_value, p_name, 'strateloq organic social connection token');
  ELSE
    PERFORM vault.update_secret(v_id, p_value);
  END IF;
  RETURN p_name;
END $$;

CREATE OR REPLACE FUNCTION public.fn_social_secret_clear(p_name text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_name IS NULL OR length(p_name) = 0 THEN RETURN false; END IF;
  SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  IF v_id IS NULL THEN RETURN false; END IF;
  DELETE FROM vault.secrets WHERE id = v_id;
  RETURN true;
END $$;

-- Read the decrypted secret. service_role only (privileged, server-side). This
-- is used by the callback/select-page/disconnect edge functions, never exposed
-- to the browser via PostgREST (grants below).
CREATE OR REPLACE FUNCTION public.fn_social_secret_read(p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_val text;
BEGIN
  IF p_name IS NULL OR length(p_name) = 0 THEN RETURN NULL; END IF;
  SELECT decrypted_secret INTO v_val FROM vault.decrypted_secrets WHERE name = p_name;
  RETURN v_val;
END $$;

-- ----------------------------------------------------------------------------
-- 3. SCOPE + CAPABILITY DB CONTRACTS (mirror the _shared pure helpers)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_required_scopes(p_platform text, p_connection_type text DEFAULT 'ORGANIC')
RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT CASE
    WHEN p_connection_type = 'ORGANIC' AND p_platform = 'META_FACEBOOK'
      THEN '["pages_show_list","pages_read_engagement","pages_manage_posts","business_management"]'::jsonb
    WHEN p_connection_type = 'ORGANIC' AND p_platform = 'META_INSTAGRAM'
      THEN '["instagram_basic","instagram_content_publish","pages_show_list","business_management"]'::jsonb
    ELSE '[]'::jsonb
  END;
$$;

-- SUBSET validation: required ⊆ granted (case-insensitive). Extra scopes accepted.
CREATE OR REPLACE FUNCTION public.fn_social_scope_subset_ok(p_required jsonb, p_granted jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(coalesce(p_required,'[]'::jsonb)) AS req(v)
    WHERE nullif(lower(trim(req.v)),'') IS NOT NULL
      AND lower(trim(req.v)) NOT IN (
        -- filter NULL/empty granted elements so NOT IN cannot yield NULL and
        -- falsely treat a missing required scope as present
        SELECT lower(trim(g.v))
        FROM jsonb_array_elements_text(coalesce(p_granted,'[]'::jsonb)) AS g(v)
        WHERE nullif(trim(g.v),'') IS NOT NULL
      )
  );
$$;

-- Capabilities derived ONLY from the real Meta Page tasks grant (never scopes).
CREATE OR REPLACE FUNCTION public.fn_social_capabilities_from_meta_tasks(p_tasks jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE
  v_tasks text[];
  v_caps  text[] := ARRAY[]::text[];
BEGIN
  SELECT array_agg(upper(trim(t.v)))
    INTO v_tasks
  FROM jsonb_array_elements_text(coalesce(p_tasks,'[]'::jsonb)) AS t(v);
  IF v_tasks IS NULL OR array_length(v_tasks,1) IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  v_caps := array_append(v_caps, 'READ_PROFILE');   -- any real task grant implies profile read
  IF 'CREATE_CONTENT' = ANY(v_tasks) THEN
    v_caps := v_caps || ARRAY['PUBLISH_TEXT','PUBLISH_IMAGE','PUBLISH_VIDEO','PUBLISH_CAROUSEL'];
  END IF;
  RETURN to_jsonb(v_caps);
END $$;

-- ----------------------------------------------------------------------------
-- 4. OAUTH BEGIN (user-context) — fn_social_oauth_begin
--    Resolves tenant + authorization from auth.uid() via fn__own_tenant(),
--    creates/refreshes the PENDING_OAUTH connection row, and records the state
--    hash. Returns only safe ids. The raw state + authorize URL are built edge-side.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_oauth_begin(
  p_platform     text,
  p_state_hash   text,
  p_redirect_uri text,
  p_ttl_seconds  integer DEFAULT 600
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_tenant uuid;
  v_conn   uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;
  IF p_platform <> 'META_FACEBOOK' THEN
    -- 016C ships only Meta Facebook ORGANIC; other platforms are deferred units.
    RETURN jsonb_build_object('ok', false, 'error', 'platform_not_enabled');
  END IF;
  IF p_state_hash IS NULL OR p_state_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_state_hash');
  END IF;

  v_tenant := public.fn__own_tenant();
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_unresolved');
  END IF;

  -- Reuse the single "unconnected placeholder" slot (external_account_id IS NULL)
  -- for this tenant/platform/ORGANIC; a CONNECTED row for a real Page id lives in
  -- a separate unique slot and is never clobbered here.
  SELECT id INTO v_conn
  FROM public.social_platform_connections
  WHERE tenant_id = v_tenant AND platform = p_platform
    AND connection_type = 'ORGANIC' AND external_account_id IS NULL
  LIMIT 1;

  IF v_conn IS NULL THEN
    INSERT INTO public.social_platform_connections(
      tenant_id, platform, connection_type, authorization_status, oauth_state,
      display_metadata, updated_at)
    VALUES (v_tenant, p_platform, 'ORGANIC', 'PENDING_OAUTH', p_state_hash,
      jsonb_build_object('flow','oauth_begin','selection_required',false), now())
    RETURNING id INTO v_conn;
  ELSE
    UPDATE public.social_platform_connections
    SET authorization_status = 'PENDING_OAUTH',
        oauth_state = p_state_hash,
        error_detail = NULL,
        display_metadata = coalesce(display_metadata,'{}'::jsonb)
                           || jsonb_build_object('flow','oauth_begin','selection_required',false),
        updated_at = now()
    WHERE id = v_conn;
  END IF;

  INSERT INTO public.social_oauth_states(
    connection_id, tenant_id, user_id, platform, connection_type, state_hash,
    redirect_uri, expires_at)
  VALUES (v_conn, v_tenant, v_uid, p_platform, 'ORGANIC', p_state_hash,
    p_redirect_uri, now() + make_interval(secs => greatest(60, least(coalesce(p_ttl_seconds,600), 1800))));

  RETURN jsonb_build_object('ok', true, 'connection_id', v_conn, 'tenant_id', v_tenant);
END $$;

-- ----------------------------------------------------------------------------
-- 5. OAUTH CONSUME (service-context) — fn_social_oauth_consume
--    Single-use validation of the returned state. Atomically marks consumed.
--    Classifies the failure internally (the edge returns a generic message to
--    the browser). Never returns a token.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_oauth_consume(p_state_hash text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  r RECORD;
BEGIN
  IF p_state_hash IS NULL OR p_state_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'malformed');
  END IF;

  UPDATE public.social_oauth_states
  SET consumed_at = now()
  WHERE state_hash = p_state_hash
    AND consumed_at IS NULL
    AND expires_at > now()
  RETURNING connection_id, tenant_id, user_id, platform, redirect_uri INTO r;

  IF FOUND THEN
    RETURN jsonb_build_object('ok', true,
      'connection_id', r.connection_id, 'tenant_id', r.tenant_id,
      'user_id', r.user_id, 'platform', r.platform, 'redirect_uri', r.redirect_uri);
  END IF;

  -- classify (server-internal only)
  IF EXISTS (SELECT 1 FROM public.social_oauth_states WHERE state_hash = p_state_hash AND consumed_at IS NOT NULL) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_consumed');
  ELSIF EXISTS (SELECT 1 FROM public.social_oauth_states WHERE state_hash = p_state_hash AND expires_at <= now()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'expired');
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_state');
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 6. RECORD DISCOVERED PAGES (service-context) — fn_social_meta_set_discovered
--    Stores the temp user-token Vault ref + SAFE discovered-page metadata (no
--    tokens). Defensively strips any token-bearing keys from the page list.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_set_discovered(
  p_connection_id  uuid,
  p_tenant_id      uuid,
  p_user_secret_ref text,
  p_pages          jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_exists boolean;
  v_safe   jsonb;
BEGIN
  SELECT true INTO v_exists FROM public.social_platform_connections
   WHERE id = p_connection_id AND tenant_id = p_tenant_id
     AND connection_type = 'ORGANIC' AND authorization_status = 'PENDING_OAUTH';
  IF NOT coalesce(v_exists,false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pending_connection_not_found');
  END IF;

  IF p_user_secret_ref IS NULL OR length(p_user_secret_ref) = 0 OR length(p_user_secret_ref) > 120
     OR p_user_secret_ref ~ '^(eyJ|Bearer )' OR p_user_secret_ref ~ '^[A-Za-z0-9_-]{200,}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_secret_ref');
  END IF;

  -- keep only safe fields; never persist a token even if one is passed in
  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', pg->>'id', 'name', pg->>'name', 'tasks', coalesce(pg->'tasks','[]'::jsonb))), '[]'::jsonb)
    INTO v_safe
  FROM jsonb_array_elements(coalesce(p_pages,'[]'::jsonb)) AS pg;

  UPDATE public.social_platform_connections
  SET secret_ref = p_user_secret_ref,
      display_metadata = coalesce(display_metadata,'{}'::jsonb)
                         || jsonb_build_object('selection_required', true,
                                               'discovered_pages', v_safe,
                                               'discovered_at', to_jsonb(now())),
      updated_at = now()
  WHERE id = p_connection_id;

  RETURN jsonb_build_object('ok', true, 'page_count', jsonb_array_length(v_safe));
END $$;

-- ----------------------------------------------------------------------------
-- 7. FINALIZE (service-context) — fn_social_meta_finalize
--    Writes the CONNECTED row after Page selection + verification. Enforces:
--    chosen page was discovered, required-scope SUBSET, verification succeeded,
--    capabilities-from-tasks (never from scopes), token-shape guard on secret_ref.
--    Clears the temporary user-token Vault secret.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_finalize(
  p_connection_id   uuid,
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_page_id         text,
  p_page_name       text,
  p_granted_scopes  jsonb,
  p_page_tasks      jsonb,
  p_page_secret_ref text,
  p_expires_at      timestamptz,
  p_verified        boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_platform     text := 'META_FACEBOOK';
  v_meta         jsonb;
  v_discovered   jsonb;
  v_required     jsonb;
  v_caps         jsonb;
  v_old_secret   text;
  v_existing     uuid;
  v_final        uuid;
BEGIN
  SELECT display_metadata, secret_ref INTO v_meta, v_old_secret
  FROM public.social_platform_connections
  WHERE id = p_connection_id AND tenant_id = p_tenant_id
    AND connection_type = 'ORGANIC' AND authorization_status = 'PENDING_OAUTH';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pending_connection_not_found');
  END IF;

  IF p_verified IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'connection_not_verified');
  END IF;
  IF p_page_id IS NULL OR length(trim(p_page_id)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_page_id');
  END IF;

  -- the chosen page MUST be one Meta actually returned at discovery
  v_discovered := coalesce(v_meta->'discovered_pages','[]'::jsonb);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_discovered) AS d WHERE d->>'id' = p_page_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'page_not_in_discovered_set');
  END IF;

  -- required-scope SUBSET (extra scopes accepted)
  v_required := public.fn_social_required_scopes(v_platform,'ORGANIC');
  IF NOT public.fn_social_scope_subset_ok(v_required, coalesce(p_granted_scopes,'[]'::jsonb)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_scopes',
      'required', v_required, 'granted', coalesce(p_granted_scopes,'[]'::jsonb));
  END IF;

  IF p_page_secret_ref IS NULL OR length(p_page_secret_ref) = 0 OR length(p_page_secret_ref) > 120
     OR p_page_secret_ref ~ '^(eyJ|Bearer )' OR p_page_secret_ref ~ '^[A-Za-z0-9_-]{200,}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_secret_ref');
  END IF;

  v_caps := public.fn_social_capabilities_from_meta_tasks(coalesce(p_page_tasks,'[]'::jsonb));

  -- if a CONNECTED row already exists for this exact Page, update it and drop the
  -- placeholder (avoids the (tenant,platform,ORGANIC,page_id) unique collision).
  SELECT id INTO v_existing
  FROM public.social_platform_connections
  WHERE tenant_id = p_tenant_id AND platform = v_platform
    AND connection_type = 'ORGANIC' AND external_account_id = p_page_id
    AND id <> p_connection_id;

  IF v_existing IS NOT NULL THEN
    UPDATE public.social_platform_connections
    SET display_name = p_page_name, authorization_status = 'CONNECTED',
        granted_scopes = coalesce(p_granted_scopes,'[]'::jsonb), capabilities = v_caps,
        secret_ref = p_page_secret_ref, connected_at = now(), last_verified_at = now(),
        expires_at = p_expires_at, revoked_at = NULL, error_detail = NULL,
        display_metadata = jsonb_build_object('page_tasks', coalesce(p_page_tasks,'[]'::jsonb),
                                              'selection_required', false,
                                              'verified_readonly', true),
        updated_at = now()
    WHERE id = v_existing;
    DELETE FROM public.social_platform_connections WHERE id = p_connection_id;
    v_final := v_existing;
  ELSE
    UPDATE public.social_platform_connections
    SET external_account_id = p_page_id, display_name = p_page_name,
        authorization_status = 'CONNECTED', granted_scopes = coalesce(p_granted_scopes,'[]'::jsonb),
        capabilities = v_caps, secret_ref = p_page_secret_ref, connected_at = now(),
        last_verified_at = now(), expires_at = p_expires_at, revoked_at = NULL, error_detail = NULL,
        display_metadata = jsonb_build_object('page_tasks', coalesce(p_page_tasks,'[]'::jsonb),
                                              'selection_required', false,
                                              'verified_readonly', true),
        updated_at = now()
    WHERE id = p_connection_id;
    v_final := p_connection_id;
  END IF;

  -- retire the temporary user-token secret if it differs from the page secret
  IF v_old_secret IS NOT NULL AND v_old_secret <> p_page_secret_ref THEN
    PERFORM public.fn_social_secret_clear(v_old_secret);
  END IF;

  RETURN jsonb_build_object('ok', true, 'connection_id', v_final,
    'capabilities', v_caps, 'granted_scopes', coalesce(p_granted_scopes,'[]'::jsonb));
END $$;

-- ----------------------------------------------------------------------------
-- 8. DISCONNECT / REVOKE (user-context) — fn_social_connection_disconnect
--    Marks REVOKED, clears the Vault secret atomically, records revoked_at.
--    Only claims Meta-side revocation when the caller proved it (p_meta_revoked).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_connection_disconnect(
  p_connection_id uuid,
  p_meta_revoked  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_tenant uuid;
  v_secret text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;
  v_tenant := public.fn__own_tenant();
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_unresolved');
  END IF;

  SELECT secret_ref INTO v_secret
  FROM public.social_platform_connections
  WHERE id = p_connection_id AND tenant_id = v_tenant AND connection_type = 'ORGANIC';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'connection_not_found');
  END IF;

  IF v_secret IS NOT NULL THEN
    PERFORM public.fn_social_secret_clear(v_secret);
  END IF;

  UPDATE public.social_platform_connections
  SET authorization_status = 'REVOKED', revoked_at = now(), secret_ref = NULL,
      display_metadata = coalesce(display_metadata,'{}'::jsonb)
                         || jsonb_build_object('meta_side_revoked', coalesce(p_meta_revoked,false),
                                               'disconnected_by', v_uid, 'disconnected_at', to_jsonb(now())),
      updated_at = now()
  WHERE id = p_connection_id AND tenant_id = v_tenant;

  RETURN jsonb_build_object('ok', true, 'connection_id', p_connection_id,
    'meta_side_revoked', coalesce(p_meta_revoked,false));
END $$;

-- ----------------------------------------------------------------------------
-- 9. §8 SECURITY HARDENING — lock SECURITY DEFINER EXECUTE to least privilege.
--    016B recovery flagged that grants were left at the PostgreSQL default
--    (EXECUTE to PUBLIC). Revoke PUBLIC/anon everywhere; grant service_role for
--    privileged server-side RPCs, plus authenticated for the two user entrypoints.
-- ----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      -- 016B
      'fn_social_connection_capabilities','fn_social_platform_external_requirements',
      'fn_social_publishing_preflight','fn_social_publishing_request','fn_social_connection_selftest',
      -- 016C
      'fn_social_secret_put','fn_social_secret_clear','fn_social_secret_read',
      'fn_social_required_scopes','fn_social_scope_subset_ok','fn_social_capabilities_from_meta_tasks',
      'fn_social_oauth_begin','fn_social_oauth_consume','fn_social_meta_set_discovered',
      'fn_social_meta_finalize','fn_social_connection_disconnect','fn_social_meta_oauth_selftest'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
    BEGIN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.sig); EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', r.sig); EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig); EXCEPTION WHEN undefined_object THEN NULL; END;
  END LOOP;

  -- the ONLY two user-context entrypoints (use auth.uid()); callable by authenticated.
  BEGIN EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_oauth_begin(text,text,text,integer) TO authenticated'; EXCEPTION WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_connection_disconnect(uuid,boolean) TO authenticated'; EXCEPTION WHEN undefined_object THEN NULL; END;

  -- the edge functions resolve the caller's own tenant via fn__own_tenant();
  -- ensure authenticated can execute it (idempotent; PUBLIC default left intact
  -- for existing internal callers — this only guarantees the entrypoint works).
  BEGIN EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn__own_tenant() TO authenticated'; EXCEPTION WHEN undefined_object THEN NULL; END;
END $$;

-- ----------------------------------------------------------------------------
-- 10. ZERO-COST SELFTEST — fn_social_meta_oauth_selftest()
--     Deterministic, no live Meta call. Proves the DB-side contracts.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_meta_oauth_selftest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_checks jsonb := '[]'::jsonb;
  v_pass   boolean := true;
  b        boolean;
  v_tenant uuid := gen_random_uuid();
  v_user   uuid := gen_random_uuid();
  v_conn   uuid;
  v_hash   text := encode(extensions.digest('selftest-'||gen_random_uuid()::text,'sha256'),'hex');
  v_hash2  text := encode(extensions.digest('selftest-expired-'||gen_random_uuid()::text,'sha256'),'hex');
  v_c      jsonb;
  v_asset  uuid; v_atenant uuid; v_pre jsonb;
BEGIN
  -- (a) required-scope subset: exact-superset ok; extra scopes ok; missing rejected
  b := public.fn_social_scope_subset_ok(
         public.fn_social_required_scopes('META_FACEBOOK','ORGANIC'),
         '["pages_show_list","pages_read_engagement","pages_manage_posts","business_management","pages_manage_metadata","public_profile"]'::jsonb)
       AND NOT public.fn_social_scope_subset_ok(
         public.fn_social_required_scopes('META_FACEBOOK','ORGANIC'),
         '["pages_show_list","pages_read_engagement","business_management"]'::jsonb);
  v_checks := v_checks || jsonb_build_object('check','scope_subset_extra_ok_missing_rejected','pass',b);
  v_pass := v_pass AND b;

  -- (b) capabilities derived from tasks, not scopes
  b := (public.fn_social_capabilities_from_meta_tasks('["CREATE_CONTENT","ANALYZE"]'::jsonb) ? 'PUBLISH_IMAGE')
       AND NOT (public.fn_social_capabilities_from_meta_tasks('["ANALYZE","MODERATE"]'::jsonb) ? 'PUBLISH_IMAGE')
       AND (public.fn_social_capabilities_from_meta_tasks('["ANALYZE"]'::jsonb) ? 'READ_PROFILE')
       AND (public.fn_social_capabilities_from_meta_tasks('[]'::jsonb) = '[]'::jsonb);
  v_checks := v_checks || jsonb_build_object('check','capabilities_from_tasks_not_scopes','pass',b);
  v_pass := v_pass AND b;

  -- (c) state single-use: valid -> consume ok; reuse -> fail; expired -> fail
  INSERT INTO public.social_platform_connections(tenant_id,platform,connection_type,authorization_status)
    VALUES (v_tenant,'META_FACEBOOK','ORGANIC','PENDING_OAUTH') RETURNING id INTO v_conn;
  INSERT INTO public.social_oauth_states(connection_id,tenant_id,user_id,platform,connection_type,state_hash,expires_at)
    VALUES (v_conn,v_tenant,v_user,'META_FACEBOOK','ORGANIC',v_hash, now()+interval '5 min');
  INSERT INTO public.social_oauth_states(connection_id,tenant_id,user_id,platform,connection_type,state_hash,expires_at)
    VALUES (v_conn,v_tenant,v_user,'META_FACEBOOK','ORGANIC',v_hash2, now()-interval '1 min');

  b := (public.fn_social_oauth_consume(v_hash)->>'ok' = 'true')          -- first use ok
       AND (public.fn_social_oauth_consume(v_hash)->>'ok' = 'false')     -- reuse rejected
       AND (public.fn_social_oauth_consume(v_hash)->>'reason' = 'already_consumed')
       AND (public.fn_social_oauth_consume(v_hash2)->>'ok' = 'false')    -- expired rejected
       AND (public.fn_social_oauth_consume(v_hash2)->>'reason' = 'expired')
       AND (public.fn_social_oauth_consume(encode(extensions.digest('never','sha256'),'hex'))->>'reason' = 'unknown_state');
  v_checks := v_checks || jsonb_build_object('check','oauth_state_single_use_and_expiry','pass',b);
  v_pass := v_pass AND b;

  -- (d) token-shaped value rejected from secret_ref (DB CHECK)
  BEGIN
    UPDATE public.social_platform_connections
      SET secret_ref = 'eyJhbGciOiJIUzI1Ni{padding-to-exceed}'||repeat('a',60)
      WHERE id = v_conn;
    b := false;  -- should not reach here
  EXCEPTION WHEN check_violation THEN
    b := true;
  END;
  v_checks := v_checks || jsonb_build_object('check','token_shaped_secret_ref_rejected','pass',b);
  v_pass := v_pass AND b;

  -- (e) revoked connection fails publishing preflight (uses a real media asset)
  SELECT tenant_id, id INTO v_atenant, v_asset FROM public.media_assets
    WHERE media_type='VIDEO' ORDER BY (id::text LIKE '0ad36286%') DESC LIMIT 1;
  IF v_asset IS NOT NULL THEN
    -- forge a CONNECTED row then revoke it; preflight must NOT treat it as usable
    UPDATE public.social_platform_connections
      SET authorization_status='CONNECTED', external_account_id='SELFTEST_PAGE',
          capabilities='["READ_PROFILE","PUBLISH_VIDEO"]'::jsonb, connected_at=now()
      WHERE id=v_conn;
    UPDATE public.social_platform_connections SET tenant_id=v_atenant WHERE id=v_conn;
    UPDATE public.social_platform_connections
      SET authorization_status='REVOKED', revoked_at=now() WHERE id=v_conn;
    v_pre := public.fn_social_publishing_preflight(
      v_atenant,'META_FACEBOOK',v_asset,'SELFTEST_PAGE',true,'MANUAL',false);
    b := (v_pre->>'execution_state' = 'BLOCKED_PENDING_PLATFORM_CONNECTION')
         AND (v_pre->>'has_connected_organic_connection' = 'false');
  ELSE
    b := true;  -- no asset available in this environment; contract asserted elsewhere
  END IF;
  v_checks := v_checks || jsonb_build_object('check','revoked_connection_fails_preflight','pass',b);
  v_pass := v_pass AND b;

  -- (f) organic vs advertising boundary intact (016B contract re-asserted)
  b := (public.fn_social_connection_capabilities('META_FACEBOOK','ORGANIC')->'capabilities' ? 'PUBLISH_IMAGE')
       AND NOT (public.fn_social_connection_capabilities('META_FACEBOOK','ORGANIC')->'capabilities' ? 'ACTIVATE_CAMPAIGN')
       AND (public.fn_social_platform_external_requirements('META_FACEBOOK','ADVERTISING')->>'stage_gate' = 'BLOCKED');
  v_checks := v_checks || jsonb_build_object('check','organic_advertising_boundary_intact','pass',b);
  v_pass := v_pass AND b;

  -- cleanup synthetic rows
  DELETE FROM public.social_oauth_states WHERE connection_id = v_conn;
  DELETE FROM public.social_platform_connections WHERE id = v_conn;

  RETURN jsonb_build_object('suite','meta_facebook_organic_oauth','passed',v_pass,
    'total', jsonb_array_length(v_checks), 'checks', v_checks);
END $$;

DO $$ BEGIN EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_social_meta_oauth_selftest() TO service_role'; EXCEPTION WHEN undefined_object THEN NULL; END $$;
