-- mig_344: Facebook Organic Publish Executor + durable attempt/result ledger.
--
-- Context (verified live against the existing Strateloq social publishing spine):
--   * There is a connection/preflight/request contract (social_platform_connections,
--     fn_social_publishing_preflight, fn_social_publishing_request, fn_social_required_scopes,
--     fn_social_scope_subset_ok, fn_social_secret_read) but NO executor that consumes an
--     approved ORGANIC publishing request and NO attempt/result ledger. This migration adds
--     exactly that missing execution leg, EXTENDING the existing architecture (it reuses the
--     preflight, the required-scopes contract, the secret vault read, and the connection row;
--     it does NOT create a second OAuth/token system, nor rename any production contract).
--
-- Hard safety invariants enforced here:
--   1. REAL public Facebook posting is NOT authorized. This executor has NO live-send code
--      path at all: it always stops before any Graph API call. It builds the real outbound
--      payload and records a non-published VALIDATED result, but never performs an HTTP call
--      (no net.http_* / http() reference anywhere in the body). There is therefore no path by
--      which a dry-run can "fall through" to a live post.
--   2. OAuth / access tokens are NEVER persisted in either ledger table and NEVER returned or
--      logged. The Page token is resolved only through the existing SECURITY DEFINER vault read
--      (fn_social_secret_read) into a local variable, used for nothing (dry-run), and discarded.
--   3. ORGANIC / PAID hard separation: this executor has ZERO authority over Meta campaigns,
--      adsets, ads, spend reservations or marketing_spend_authority. Its body references none of
--      the paid-lane contracts; a self-test asserts both the static absence and that a run
--      creates zero spend_reservations rows.
--   4. Tenant isolation: the actor's tenant is resolved from their member row and the request's
--      tenant_id must match; cross-tenant execution is rejected. Ledger tables have RLS enabled
--      (members read only their own tenant's rows; all writes go through this SECURITY DEFINER
--      executor / service_role).
--   5. Durable DB-backed idempotency: at most one PUBLISHED result can ever exist per request
--      (enforced by a partial unique index), the executor short-circuits to the existing result
--      instead of republishing, and an explicit idempotency key gives safe double-click/retry
--      replay.
--
-- Content types supported: TEXT and SINGLE_IMAGE (+caption) only. Carousel / video / reels /
-- stories / multi-image / cross-platform are rejected (adapter kept extensible).

-- ============================================================================
-- 1. LEDGER TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.social_publish_attempts (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL,
  actor_user_id           uuid,                         -- who initiated (member identity); NEVER a token
  publishing_request_id   uuid NOT NULL
                            REFERENCES public.social_publishing_requests(id) ON DELETE CASCADE,
  platform                text NOT NULL,
  connection_id           uuid
                            REFERENCES public.social_platform_connections(id) ON DELETE SET NULL,
  attempt_no              int  NOT NULL DEFAULT 1,
  idempotency_key         text NOT NULL,
  execution_mode          text NOT NULL,                -- VALIDATE_ONLY / DRY_RUN
  execution_state         text NOT NULL,                -- CLAIMED / VALIDATED / FAILED / BLOCKED_EXTERNAL / SHORT_CIRCUIT_ALREADY_PUBLISHED
  error_class             text,                         -- safe classification enum (never a secret)
  error_message           text,                         -- safe human text (never a secret / token)
  started_at              timestamptz NOT NULL DEFAULT now(),
  completed_at            timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT social_publish_attempts_idem_uk UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS social_publish_attempts_tenant_idx
  ON public.social_publish_attempts (tenant_id);
CREATE INDEX IF NOT EXISTS social_publish_attempts_request_idx
  ON public.social_publish_attempts (publishing_request_id);

CREATE TABLE IF NOT EXISTS public.social_post_results (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL,
  actor_user_id           uuid,
  publishing_request_id   uuid NOT NULL
                            REFERENCES public.social_publishing_requests(id) ON DELETE CASCADE,
  publish_attempt_id      uuid NOT NULL
                            REFERENCES public.social_publish_attempts(id) ON DELETE CASCADE,
  platform                text NOT NULL,
  platform_post_id        text,                         -- NULL in dry-run (no post created)
  permalink               text,                         -- NULL in dry-run / where unsafe
  published_at            timestamptz,                  -- NULL in dry-run
  result_state            text NOT NULL,                -- VALIDATED / PUBLISHED / FAILED / BLOCKED_EXTERNAL
  error_class             text,
  error_message           text,
  outbound_payload        jsonb,                        -- prepared Graph request MINUS any credential (evidence only)
  created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS social_post_results_tenant_idx
  ON public.social_post_results (tenant_id);
CREATE INDEX IF NOT EXISTS social_post_results_request_idx
  ON public.social_post_results (publishing_request_id);

-- AUTHORITATIVE live-idempotency guard: at most one PUBLISHED post may ever exist per request.
-- Even under a race, the second concurrent PUBLISHED insert fails. Dry-run never writes PUBLISHED.
CREATE UNIQUE INDEX IF NOT EXISTS social_post_results_one_published_per_request
  ON public.social_post_results (publishing_request_id)
  WHERE result_state = 'PUBLISHED';

-- ----------------------------------------------------------------------------
-- RLS: members read ONLY their own tenant's ledger; writes are default-denied
-- (only this SECURITY DEFINER executor / service_role can write).
-- ----------------------------------------------------------------------------
ALTER TABLE public.social_publish_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_post_results     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS social_publish_attempts_select_own ON public.social_publish_attempts;
CREATE POLICY social_publish_attempts_select_own
  ON public.social_publish_attempts FOR SELECT TO authenticated
  USING (tenant_id = public.fn__own_tenant());

DROP POLICY IF EXISTS social_post_results_select_own ON public.social_post_results;
CREATE POLICY social_post_results_select_own
  ON public.social_post_results FOR SELECT TO authenticated
  USING (tenant_id = public.fn__own_tenant());

-- No INSERT/UPDATE/DELETE policy on either table => all writes are default-denied for
-- anon/authenticated and happen only via the SECURITY DEFINER executor or service_role.

COMMENT ON TABLE public.social_publish_attempts IS
  'Tenant-scoped durable ledger of social publish execution attempts (idempotency-keyed). Never stores OAuth/access tokens. mig_344.';
COMMENT ON TABLE public.social_post_results IS
  'Tenant-scoped durable ledger of social publish results. platform_post_id/permalink/published_at are NULL for VALIDATE_ONLY. At most one PUBLISHED row per request. Never stores OAuth/access tokens. mig_344.';

-- ============================================================================
-- 2. FACEBOOK ORGANIC PUBLISH EXECUTOR
-- ============================================================================
-- VALIDATE_ONLY by design: runs full preflight, resolves the REAL organic Page connection,
-- verifies scope, claims an idempotent attempt, resolves the Page token via the vault (used for
-- nothing), prepares the real outbound Graph payload, records a non-published VALIDATED result,
-- and STOPS. There is no live-send branch and no HTTP primitive anywhere in this body.

CREATE OR REPLACE FUNCTION public.fn_social_facebook_organic_execute(
  p_request_id      uuid,
  p_actor           uuid DEFAULT NULL,
  p_mode            text DEFAULT 'VALIDATE_ONLY',
  p_idempotency_key text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_actor      uuid;
  v_tenant     uuid;
  v_mcount     int;
  v_req        public.social_publishing_requests%ROWTYPE;
  v_conn       public.social_platform_connections%ROWTYPE;
  v_content    jsonb;
  v_ctype      text;
  v_needed_cap text;
  v_mode       text := upper(coalesce(p_mode,'VALIDATE_ONLY'));
  v_pre        jsonb;
  v_pre_state  text;
  v_reasons    jsonb;
  v_required   jsonb;
  v_scope_ok   boolean;
  v_missing    jsonb;
  v_token      text;          -- Page token (resolved via vault, used for NOTHING, never returned)
  v_key        text;
  v_attempt_no int;
  v_attempt_id uuid;
  v_result_id  uuid;
  v_existing   record;
  v_payload    jsonb;
  v_err_class  text;
  v_err_msg    text;
  v_page_id    text;

  -- Record a terminal failure/blocked outcome on the already-claimed attempt + a result row.
  -- (local helper via inline code; plpgsql has no nested procs, so done inline at call sites)
BEGIN
  -- ---- Resolve actor (authenticated callers cannot impersonate: auth.uid() wins) -----------
  v_actor := coalesce(auth.uid(), p_actor);
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','unauthenticated','retryable',false);
  END IF;

  SELECT count(*), min(m.application_ref::text)::uuid INTO v_mcount, v_tenant
  FROM public.member m WHERE m.auth_user_id = v_actor;
  IF v_mcount <> 1 OR v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','actor_tenant_unresolved','retryable',false);
  END IF;

  -- ---- Load request --------------------------------------------------------------------------
  SELECT * INTO v_req FROM public.social_publishing_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','request_not_found','retryable',false);
  END IF;

  -- ---- Tenant ownership (hard isolation) -----------------------------------------------------
  IF v_req.tenant_id <> v_tenant THEN
    RETURN jsonb_build_object('ok',false,'error_class','CROSS_TENANT_REJECTED','error_message','request_belongs_to_another_tenant','retryable',false);
  END IF;

  -- ---- Platform / connection_type structural gates (ORGANIC Facebook only) -------------------
  IF v_req.platform <> 'META_FACEBOOK' THEN
    RETURN jsonb_build_object('ok',false,'error_class','PLATFORM_REJECTED','error_message','executor_handles_META_FACEBOOK_only','retryable',false);
  END IF;
  IF v_req.connection_type <> 'ORGANIC' THEN
    -- A PAID (or any non-ORGANIC) connection can never be substituted for organic publishing.
    RETURN jsonb_build_object('ok',false,'error_class','WRONG_CONNECTION_TYPE','error_message','organic_executor_requires_ORGANIC_connection_type','retryable',false);
  END IF;

  -- ---- Content type gate (TEXT / SINGLE_IMAGE only) ------------------------------------------
  v_content := coalesce(v_req.content, '{}'::jsonb);
  v_ctype   := upper(coalesce(v_content->>'type',
                 CASE WHEN v_req.media_asset_id IS NULL THEN 'TEXT' ELSE 'SINGLE_IMAGE' END));
  IF v_ctype NOT IN ('TEXT','SINGLE_IMAGE') THEN
    RETURN jsonb_build_object('ok',false,'error_class','UNSUPPORTED_CONTENT_TYPE',
      'error_message','only_TEXT_and_SINGLE_IMAGE_supported','content_type',v_ctype,'retryable',false);
  END IF;

  -- ---- Idempotent replay by explicit key -----------------------------------------------------
  IF p_idempotency_key IS NOT NULL THEN
    SELECT a.id, a.execution_state, a.error_class, a.error_message INTO v_existing
    FROM public.social_publish_attempts a WHERE a.idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', v_existing.execution_state IN ('VALIDATED','SHORT_CIRCUIT_ALREADY_PUBLISHED'),
        'idempotent_replay', true, 'attempt_id', v_existing.id,
        'execution_state', v_existing.execution_state,
        'error_class', v_existing.error_class, 'error_message', v_existing.error_message,
        'live_send_performed', false);
    END IF;
  END IF;

  -- ---- ALREADY_PUBLISHED short-circuit (authoritative: never republish) ----------------------
  SELECT r.id, r.platform_post_id, r.permalink, r.published_at INTO v_existing
  FROM public.social_post_results r
  WHERE r.publishing_request_id = p_request_id AND r.result_state = 'PUBLISHED'
  ORDER BY r.created_at ASC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok',true,'error_class','ALREADY_PUBLISHED','idempotent_replay',true,
      'result_id', v_existing.id, 'platform_post_id', v_existing.platform_post_id,
      'permalink', v_existing.permalink, 'published_at', v_existing.published_at,
      'live_send_performed', false,
      'note','A published result already exists for this request; returned instead of republishing.');
  END IF;

  -- ---- Claim an idempotent attempt (gate before any token resolution) -------------------------
  v_key := coalesce(p_idempotency_key, gen_random_uuid()::text);
  SELECT coalesce(max(attempt_no),0)+1 INTO v_attempt_no
  FROM public.social_publish_attempts WHERE publishing_request_id = p_request_id;

  INSERT INTO public.social_publish_attempts(
    tenant_id, actor_user_id, publishing_request_id, platform, connection_id,
    attempt_no, idempotency_key, execution_mode, execution_state, started_at, created_at)
  VALUES (v_tenant, v_actor, p_request_id, v_req.platform, NULL,
    v_attempt_no, v_key, CASE WHEN v_mode = 'DRY_RUN' THEN 'DRY_RUN' ELSE 'VALIDATE_ONLY' END,
    'CLAIMED', now(), now())
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_attempt_id;

  IF v_attempt_id IS NULL THEN
    -- Lost the race / duplicate key: replay the winner's outcome.
    SELECT a.id, a.execution_state, a.error_class, a.error_message INTO v_existing
    FROM public.social_publish_attempts a WHERE a.idempotency_key = v_key;
    RETURN jsonb_build_object('ok', v_existing.execution_state IN ('VALIDATED','SHORT_CIRCUIT_ALREADY_PUBLISHED'),
      'idempotent_replay', true, 'attempt_id', v_existing.id,
      'execution_state', v_existing.execution_state, 'live_send_performed', false);
  END IF;

  -- ---- Preflight (defense in depth; stored state is NOT trusted) ------------------------------
  v_pre := public.fn_social_publishing_preflight(
    v_tenant, v_req.platform, v_req.media_asset_id, v_req.destination_account,
    v_req.caption_approved, v_req.publish_mode, v_req.automation_authorized);
  v_pre_state := v_pre->>'execution_state';
  v_reasons   := coalesce(v_pre->'blocked_reasons','[]'::jsonb);

  IF v_pre_state <> 'READY_FOR_MANUAL_PUBLISH' THEN
    -- Classify the preflight block into a safe error_class.
    v_err_class := CASE
      WHEN v_reasons::text ILIKE '%no_connected_organic%' THEN 'NO_CONNECTED_ACCOUNT'
      WHEN v_reasons::text ILIKE '%launch_safe%' OR v_reasons::text ILIKE '%identity_review%' THEN 'IDENTITY_SAFETY_FAILED'
      WHEN v_reasons::text ILIKE '%media_asset_not_found%' THEN 'ASSET_NOT_READY'
      WHEN v_reasons::text ILIKE '%not_approved%' OR v_reasons::text ILIKE '%caption_not_approved%'
           OR v_reasons::text ILIKE '%no_destination_account%' THEN 'APPROVAL_REQUIRED'
      WHEN v_reasons::text ILIKE '%automation_not_explicitly_authorized%' THEN 'APPROVAL_REQUIRED'
      ELSE 'PREFLIGHT_FAILED' END;
    v_err_msg := 'preflight_state='||v_pre_state;
    UPDATE public.social_publish_attempts
      SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now()
      WHERE id = v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
      platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg)
      RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'blocked_reasons',v_reasons,
      'retryable',false,'live_send_performed',false);
  END IF;

  -- ---- Resolve the CONNECTED ORGANIC Page connection (same match rule as preflight) ----------
  v_needed_cap := CASE WHEN v_ctype = 'SINGLE_IMAGE' THEN 'PUBLISH_IMAGE' ELSE 'PUBLISH_TEXT' END;
  SELECT * INTO v_conn
  FROM public.social_platform_connections
  WHERE tenant_id = v_tenant AND platform = v_req.platform AND connection_type = 'ORGANIC'
    AND authorization_status = 'CONNECTED' AND revoked_at IS NULL
    AND (expires_at IS NULL OR expires_at > now())
    AND capabilities ? v_needed_cap
  ORDER BY connected_at DESC NULLS LAST LIMIT 1;

  IF NOT FOUND THEN
    v_err_class := 'NO_CONNECTED_ACCOUNT'; v_err_msg := 'no_connected_organic_facebook_connection_with_'||v_needed_cap;
    UPDATE public.social_publish_attempts
      SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now()
      WHERE id = v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
      platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg)
      RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'retryable',false,'live_send_performed',false);
  END IF;

  UPDATE public.social_publish_attempts SET connection_id = v_conn.id WHERE id = v_attempt_id;
  v_page_id := v_conn.external_account_id;

  -- ---- Scope / permission verification (EXTERNAL GATE) ----------------------------------------
  v_required := public.fn_social_required_scopes(v_req.platform, 'ORGANIC');
  v_scope_ok := public.fn_social_scope_subset_ok(v_required, coalesce(v_conn.granted_scopes,'[]'::jsonb));
  IF NOT v_scope_ok THEN
    -- Compute the missing scopes (safe to surface).
    SELECT coalesce(jsonb_agg(req.v),'[]'::jsonb) INTO v_missing
    FROM jsonb_array_elements_text(v_required) req(v)
    WHERE lower(trim(req.v)) NOT IN (
      SELECT lower(trim(g.v)) FROM jsonb_array_elements_text(coalesce(v_conn.granted_scopes,'[]'::jsonb)) g(v));
    v_err_class := 'INSUFFICIENT_SCOPE';
    v_err_msg := 'BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION';
    UPDATE public.social_publish_attempts
      SET execution_state='BLOCKED_EXTERNAL', error_class=v_err_class, error_message=v_err_msg, completed_at=now()
      WHERE id = v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
      platform,result_state,error_class,error_message,outbound_payload)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'BLOCKED_EXTERNAL',v_err_class,v_err_msg,
        jsonb_build_object('missing_scopes',v_missing,'required_scopes',v_required))
      RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'blocked','BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION',
      'missing_scopes',v_missing,'required_scopes',v_required,
      'where_approved','Meta Business Login consent for the connected Page (founder-approved); Meta App Review may be required for pages_manage_posts in production.',
      'internal_status','Internal implementation complete; only the external Page publishing permission is missing.',
      'retryable',false,'live_send_performed',false);
  END IF;

  -- ---- Resolve the Page token ONLY via the existing vault read (used for NOTHING here) --------
  -- The token is read into a local variable to prove the full execution path works end-to-end,
  -- then discarded. It is never returned, never logged, never written to either ledger table.
  v_token := public.fn_social_secret_read(v_conn.secret_ref);
  IF v_token IS NULL OR length(v_token) = 0 THEN
    v_err_class := 'NO_CONNECTED_ACCOUNT'; v_err_msg := 'page_token_unavailable';
    UPDATE public.social_publish_attempts
      SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now()
      WHERE id = v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
      platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg)
      RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'retryable',false,'live_send_performed',false);
  END IF;

  -- ---- Prepare the REAL outbound Facebook Graph payload (credential intentionally EXCLUDED) ---
  -- At live time the Page access token would be attached as the access_token parameter; here it
  -- is deliberately omitted so nothing sensitive is ever stored. No HTTP call is made.
  IF v_ctype = 'TEXT' THEN
    v_payload := jsonb_build_object(
      'method','POST',
      'endpoint','https://graph.facebook.com/v21.0/'||v_page_id||'/feed',
      'body', jsonb_build_object('message', coalesce(v_content->>'message', v_content->>'caption','')),
      'credential','OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME');
  ELSE -- SINGLE_IMAGE
    v_payload := jsonb_build_object(
      'method','POST',
      'endpoint','https://graph.facebook.com/v21.0/'||v_page_id||'/photos',
      'body', jsonb_build_object(
        'url', coalesce(v_content->>'image_url', v_content->>'url',''),
        'caption', coalesce(v_content->>'caption', v_content->>'message','')),
      'credential','OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME');
  END IF;

  -- Scrub token from local scope defensively (it was never written anywhere).
  v_token := NULL;

  -- ---- Mode gate: VALIDATE_ONLY / DRY_RUN record a non-published result and STOP -------------
  -- There is NO live-send branch. Any other mode is refused WITHOUT sending.
  IF v_mode NOT IN ('VALIDATE_ONLY','DRY_RUN') THEN
    v_err_class := 'LIVE_PUBLISH_NOT_AUTHORIZED';
    v_err_msg := 'live_publish_disabled_executor_is_validate_only';
    UPDATE public.social_publish_attempts
      SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now()
      WHERE id = v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
      platform,result_state,error_class,error_message,outbound_payload)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg,v_payload)
      RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'live_send_performed',false,'retryable',false);
  END IF;

  -- VALIDATE_ONLY success: everything verified, outbound payload prepared, NOTHING sent.
  UPDATE public.social_publish_attempts
    SET execution_state='VALIDATED', error_class=NULL, error_message=NULL, completed_at=now()
    WHERE id = v_attempt_id;
  INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,
    platform,platform_post_id,permalink,published_at,result_state,outbound_payload)
    VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,NULL,NULL,NULL,'VALIDATED',v_payload)
    RETURNING id INTO v_result_id;

  RETURN jsonb_build_object(
    'ok',true,
    'attempt_id',v_attempt_id,
    'result_id',v_result_id,
    'tenant_id',v_tenant,
    'request_id',p_request_id,
    'mode','VALIDATE_ONLY',
    'content_type',v_ctype,
    'execution_state','VALIDATED',
    'result_state','VALIDATED',
    'page_id',v_page_id,                 -- public Page id (safe), proves real account resolution
    'connection_id',v_conn.id,
    'scope_ok',true,
    'required_scopes',v_required,
    'token_resolved',true,              -- the token WAS resolved via the vault (not exposed)
    'token_exposed',false,
    'live_send_performed',false,
    'outbound_payload_prepared',true,
    'note','Full preflight, real Page+scope resolution, token resolution and payload build completed. No Facebook post was created (VALIDATE_ONLY).');
END; $function$;

COMMENT ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) IS
  'Facebook ORGANIC publish executor (VALIDATE_ONLY). Reuses fn_social_publishing_preflight / fn_social_required_scopes / fn_social_secret_read. No live-send path, no HTTP, no spend/paid access; token never returned or stored. Durable DB idempotency. mig_344.';

-- Least-privilege EXECUTE: app members + service_role (n8n) only; never anon/public.
REVOKE ALL ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) TO authenticated, service_role;

-- ============================================================================
-- 3. SELF-TEST (rolled-back subtransactions; nothing persists; nothing posted)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_social_facebook_organic_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant   uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';   -- live tenant (real FB connection)
  c_actor    uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';   -- owner of live tenant
  c_other    uuid := '17bb631a-d4a4-4b5e-870e-d35a40dd5434';   -- a different tenant's member
  c_page     text := '1273960209136806';
  v_asset    uuid;
  v_req      uuid;
  v_req_text uuid;
  v_r        jsonb; v_r2 jsonb;
  v_def      text := pg_get_functiondef('public.fn_social_facebook_organic_execute(uuid,uuid,text,text)'::regprocedure);
  v_spend_before int; v_spend_after int;
  v_token    text;
  v_leak     boolean;
  v_cnt      int;
BEGIN
  -- Fast static assertions first (no fixtures needed).
  -- (12) dry-run cannot make an external call: body references no HTTP primitive.
  v := v || jsonb_build_object('case','no_http_primitive_in_executor','pass',
        v_def !~* 'net\.http_' AND v_def !~* 'http_post' AND v_def !~* 'http_get' AND v_def !~* 'pg_net');
  -- (11a) organic/paid separation: body references no paid-lane contract.
  v := v || jsonb_build_object('case','no_spend_or_campaign_reference','pass',
        v_def !~* 'reserve_spend' AND v_def !~* 'release_spend' AND v_def !~* 'marketing_spend_authority'
        AND v_def !~* 'spend_reservations' AND v_def !~* 'marketing_campaign_executions'
        AND v_def !~* 'create_spend_authority' AND v_def !~* 'adset' AND v_def !~* 'campaign');
  -- live-send guard: body contains no live-publish branch keyword.
  v := v || jsonb_build_object('case','no_live_send_branch','pass',
        v_def ~* 'VALIDATE_ONLY' AND v_def !~* 'LIVE_PUBLISH_PERFORMED');

  -- Behavioral scenarios in one rolled-back subtransaction.
  BEGIN
    -- Fixture: an APPROVED, launch-safe, identity-resolved IMAGE asset for the live tenant.
    INSERT INTO public.media_assets(tenant_id, media_type, source_type, rights_state, generation_status,
      approval_state, is_launch_safe, identity_state, storage_ref, mime_type)
    VALUES (c_tenant,'IMAGE','SUPPLIER_PROVIDED','CLEARED','COMPLETE','APPROVED',true,'IDENTITY_RESOLVED',
      'https://img.example.com/pulse-validation.jpg','image/jpeg')
    RETURNING id INTO v_asset;

    -- Fixture: a READY SINGLE_IMAGE ORGANIC request bound to the real Page.
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,
      jsonb_build_object('type','SINGLE_IMAGE','image_url','https://img.example.com/pulse-validation.jpg','caption','Validation only — not published'),
      true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req;

    -- Fixture: a READY TEXT request (no media asset) -- NOTE: current preflight requires a media
    -- asset even for text, so TEXT with no asset is expected to be APPROVAL/ASSET blocked. We bind
    -- the same approved asset so the TEXT path reaches READY and we exercise the TEXT payload build.
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,
      jsonb_build_object('type','TEXT','message','Hello from Pulse Intelligence (validation only)'),
      true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req_text;

    -- (13 + 1) Correct tenant executes own request against the REAL Page -> VALIDATED, no post.
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_actor::text,'role','authenticated')::text, true);
    SELECT count(*) INTO v_spend_before FROM public.spend_reservations;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    SELECT count(*) INTO v_spend_after FROM public.spend_reservations;

    v := v || jsonb_build_object('case','owner_single_image_validated','pass',
          coalesce((v_r->>'ok')::boolean,false)
          AND v_r->>'result_state'='VALIDATED'
          AND v_r->>'page_id'=c_page
          AND (v_r->>'live_send_performed')='false'
          AND (v_r->>'token_resolved')='true'
          AND (v_r->'result_id') IS NOT NULL,'observed',v_r);

    -- real result row has NO platform_post_id / published_at (nothing posted).
    SELECT count(*) INTO v_cnt FROM public.social_post_results
      WHERE id=(v_r->>'result_id')::uuid AND platform_post_id IS NULL AND published_at IS NULL AND result_state='VALIDATED';
    v := v || jsonb_build_object('case','real_connection_scope_resolution_no_post','pass', v_cnt=1);

    -- (11b) behavioral: no spend reservation created.
    v := v || jsonb_build_object('case','no_spend_reservation_created','pass', v_spend_after = v_spend_before);

    -- (10) token never leaks into attempt/result rows or the returned JSON.
    v_token := public.fn_social_secret_read('social:4650f21e-06c3-4b28-8c99-5e47377e6536:page');
    SELECT (position(v_token in coalesce((SELECT string_agg(a::text,'') FROM public.social_publish_attempts a WHERE a.publishing_request_id=v_req),'')) > 0
         OR position(v_token in coalesce((SELECT string_agg(r::text,'') FROM public.social_post_results r WHERE r.publishing_request_id=v_req),'')) > 0
         OR position(v_token in v_r::text) > 0) INTO v_leak;
    v := v || jsonb_build_object('case','token_never_in_ledger_or_response','pass', v_leak = false);
    v_token := NULL;

    -- (TEXT content path) owner TEXT request -> VALIDATED with /feed payload.
    v_r := public.fn_social_facebook_organic_execute(v_req_text);
    SELECT (r.outbound_payload->>'endpoint') INTO v_token FROM public.social_post_results r WHERE r.id=(v_r->>'result_id')::uuid;
    v := v || jsonb_build_object('case','text_path_feed_payload','pass',
          coalesce((v_r->>'ok')::boolean,false) AND v_r->>'content_type'='TEXT' AND v_token LIKE '%/feed');
    v_token := NULL;

    -- (9) duplicate execution with same explicit idempotency key -> replay, NO duplicate result.
    v_r  := public.fn_social_facebook_organic_execute(v_req, NULL, 'VALIDATE_ONLY', 'idem-dup-key-1');
    v_r2 := public.fn_social_facebook_organic_execute(v_req, NULL, 'VALIDATE_ONLY', 'idem-dup-key-1');
    SELECT count(*) INTO v_cnt FROM public.social_publish_attempts WHERE idempotency_key='idem-dup-key-1';
    v := v || jsonb_build_object('case','duplicate_execution_idempotent','pass',
          coalesce((v_r2->>'idempotent_replay')::boolean,false) AND v_cnt=1,
          'observed', jsonb_build_object('first',v_r->>'execution_state','second',v_r2->>'idempotent_replay','attempts',v_cnt));

    -- (2) cross-tenant rejected (another member cannot execute this tenant's request).
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_other::text,'role','authenticated')::text, true);
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','cross_tenant_rejected','pass', v_r->>'error_class'='CROSS_TENANT_REJECTED');
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_actor::text,'role','authenticated')::text, true);

    -- (3/4) non-READY / unapproved rejected: caption_approved=false request.
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,
      jsonb_build_object('type','SINGLE_IMAGE','image_url','x','caption','y'),
      false,'MANUAL',false,false,'BLOCKED_PENDING_CONTENT','[]'::jsonb)
    RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','unapproved_caption_rejected','pass',
          coalesce((v_r->>'ok')::boolean,true)=false AND v_r->>'error_class' IN ('APPROVAL_REQUIRED','PREFLIGHT_FAILED'));

    -- (5) identity/launch-safety failed rejected.
    INSERT INTO public.media_assets(tenant_id, media_type, source_type, rights_state, generation_status,
      approval_state, is_launch_safe, identity_state, storage_ref, mime_type)
    VALUES (c_tenant,'IMAGE','SUPPLIER_PROVIDED','CLEARED','COMPLETE','APPROVED',false,'IDENTITY_REVIEW_REQUIRED','x','image/jpeg')
    RETURNING id INTO v_asset;
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,
      jsonb_build_object('type','SINGLE_IMAGE','image_url','x','caption','y'),
      true,'MANUAL',false,false,'BLOCKED_PENDING_APPROVAL','[]'::jsonb)
    RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','identity_or_launch_unsafe_rejected','pass',
          v_r->>'error_class'='IDENTITY_SAFETY_FAILED','observed',v_r->>'error_class');

    -- (7) wrong connection_type rejected (ADVERTISING/paid-lane request row).
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ADVERTISING',NULL,c_page,
      jsonb_build_object('type','SINGLE_IMAGE'),true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','wrong_connection_type_rejected','pass', v_r->>'error_class'='WRONG_CONNECTION_TYPE');

    -- (8) paid (ADVERTISING) Meta connection cannot substitute for ORGANIC: an ORGANIC request with
    -- NO organic connection present must fail NO_CONNECTED_ACCOUNT even though an ADVERTISING
    -- connection exists. Simulate on a tenant with no organic connection (c_other), owned by c_other.
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_other::text,'role','authenticated')::text, true);
    INSERT INTO public.media_assets(tenant_id, media_type, source_type, rights_state, generation_status,
      approval_state, is_launch_safe, identity_state, storage_ref, mime_type)
    VALUES ('95bb5658-5182-43af-add0-3d2ebc93393f','IMAGE','SUPPLIER_PROVIDED','CLEARED','COMPLETE','APPROVED',true,'IDENTITY_RESOLVED','x','image/jpeg')
    RETURNING id INTO v_asset;
    INSERT INTO public.social_platform_connections(tenant_id,platform,connection_type,external_account_id,
      display_name,authorization_status,granted_scopes,capabilities,secret_ref)
    VALUES ('95bb5658-5182-43af-add0-3d2ebc93393f','META_FACEBOOK','ADVERTISING','999',
      'Ads Acct','CONNECTED','["ads_management"]'::jsonb,'["MANAGE_ADS"]'::jsonb,'social:ads:x');
    INSERT INTO public.social_publishing_requests(tenant_id, platform, connection_type, media_asset_id,
      destination_account, content, caption_approved, publish_mode, automation_authorized,
      execution_enabled, execution_state, blocked_reasons)
    VALUES ('95bb5658-5182-43af-add0-3d2ebc93393f','META_FACEBOOK','ORGANIC',v_asset,'999',
      jsonb_build_object('type','SINGLE_IMAGE','image_url','x','caption','y'),
      true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','paid_cannot_substitute_for_organic','pass',
          v_r->>'error_class'='NO_CONNECTED_ACCOUNT','observed',v_r->>'error_class');
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_actor::text,'role','authenticated')::text, true);

    -- (mode guard) non-dry-run mode refused WITHOUT sending.
    v_r := public.fn_social_facebook_organic_execute(v_req_text, NULL, 'LIVE');
    v := v || jsonb_build_object('case','live_mode_refused_no_send','pass',
          v_r->>'error_class'='LIVE_PUBLISH_NOT_AUTHORIZED' AND (v_r->>'live_send_performed')='false');

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN
      v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM);
    END IF;
  END;

  RETURN jsonb_build_object('suite','social_facebook_organic_execution',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_social_facebook_organic_selftest() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_social_facebook_organic_selftest() TO postgres, service_role;
