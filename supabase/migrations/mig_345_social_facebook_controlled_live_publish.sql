-- mig_345: Controlled LIVE organic Facebook publish — minimum delta on the existing executor.
--
-- Builds on mig_344 (VALIDATE_ONLY executor + attempt/result ledger). Adds the smallest capability
-- needed to perform ONE founder-authorized, per-request organic Facebook Page publication:
--
--   1. Additive TEXT-post support in the existing publish gate. The media-first foundation
--      (fn_social_publishing_preflight / fn_social_publishing_request) previously blocked any request
--      with no media asset. A legitimate TEXT post has no media ("approved media WHERE applicable").
--      This change is purely ADDITIVE: when there is no media asset AND the content is TEXT, the media
--      checks are skipped; every image/video path and every other gate is unchanged (proven by
--      re-running the existing social self-tests).
--   2. A per-request, single-use LIVE grant (social_live_publish_grants). LIVE execution requires an
--      explicit grant row for that exact publishing_request_id; the grant is consumed on success, so
--      no standing/general publishing authority exists. VALIDATE_ONLY remains the default and there is
--      no automatic transition to LIVE.
--   3. An isolated, restricted outbound send helper (fn__social_fb_graph_send) that is the ONLY place
--      an HTTP primitive appears. It is EXECUTE-restricted to postgres/service_role; app users reach it
--      only indirectly through the SECURITY DEFINER executor, and only on the LIVE+grant path.
--   4. LIVE handling in fn_social_facebook_organic_execute: all mig_344 gates + the grant, then a real
--      Graph API POST (token resolved from the vault, passed in-memory to the helper, never returned,
--      logged or stored), PUBLISHED result recorded with the real post id/permalink, grant consumed.
--   5. fn_social_facebook_verify_post: reads the post back from Graph to confirm Page + content.
--
-- TEXT and SINGLE_IMAGE+caption only. No video/reels/stories/carousel/multi-image/cross-platform.
-- No scheduling, no auto-publish, no n8n trigger. Paid lane untouched.

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

-- ============================================================================
-- 1. ADDITIVE TEXT-POST SUPPORT IN THE EXISTING PUBLISH GATE
-- ============================================================================
-- fn_social_publishing_preflight: NULL media + TEXT content => text post (skip media checks only).
CREATE OR REPLACE FUNCTION public.fn_social_publishing_preflight(
  p_tenant_id uuid, p_platform text, p_media_asset_id uuid, p_destination_account text,
  p_caption_approved boolean, p_publish_mode text, p_automation_authorized boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_conn        public.social_platform_connections%ROWTYPE;
  v_asset       public.media_assets%ROWTYPE;
  v_reasons     text[] := ARRAY[]::text[];
  v_state       text;
  v_needed_cap  text;
  v_has_conn    boolean := false;
  v_media_type  text;
  v_is_text     boolean := (p_media_asset_id IS NULL);   -- ADDITIVE: no media => TEXT post
BEGIN
  SELECT media_type INTO v_media_type FROM public.media_assets WHERE id = p_media_asset_id;
  v_needed_cap := CASE upper(coalesce(v_media_type,'')) WHEN 'VIDEO' THEN 'PUBLISH_VIDEO'
                                                        WHEN 'IMAGE' THEN 'PUBLISH_IMAGE'
                                                        ELSE 'PUBLISH_TEXT' END;

  SELECT * INTO v_conn
  FROM public.social_platform_connections
  WHERE tenant_id = p_tenant_id
    AND platform = p_platform
    AND connection_type = 'ORGANIC'
    AND authorization_status = 'CONNECTED'
    AND (revoked_at IS NULL)
    AND (expires_at IS NULL OR expires_at > now())
    AND capabilities ? v_needed_cap
  ORDER BY connected_at DESC NULLS LAST
  LIMIT 1;
  v_has_conn := FOUND;

  IF NOT v_has_conn THEN
    v_reasons := array_append(v_reasons, 'no_connected_organic_'||p_platform||'_connection_with_'||v_needed_cap);
  END IF;

  -- Media gates apply ONLY to media posts. A TEXT post (no media asset) skips them; every other gate
  -- below (connection, destination, caption, automation) is unchanged.
  IF NOT v_is_text THEN
    SELECT * INTO v_asset FROM public.media_assets WHERE id = p_media_asset_id;
    IF NOT FOUND THEN
      v_reasons := array_append(v_reasons, 'media_asset_not_found');
    ELSE
      IF coalesce(v_asset.approval_state,'') <> 'APPROVED' THEN
        v_reasons := array_append(v_reasons, 'creative_not_approved');
      END IF;
      IF coalesce(v_asset.is_launch_safe,false) = false THEN
        v_reasons := array_append(v_reasons, 'creative_not_launch_safe');
      END IF;
      IF coalesce(v_asset.identity_state,'') = 'IDENTITY_REVIEW_REQUIRED' THEN
        v_reasons := array_append(v_reasons, 'product_identity_review_required');
      END IF;
    END IF;
  END IF;

  IF p_destination_account IS NULL OR length(trim(p_destination_account)) = 0 THEN
    v_reasons := array_append(v_reasons, 'no_destination_account_selected');
  END IF;
  IF coalesce(p_caption_approved,false) = false THEN
    v_reasons := array_append(v_reasons, 'caption_not_approved');
  END IF;

  IF coalesce(p_publish_mode,'MANUAL') = 'AUTHORIZED_AUTO' AND coalesce(p_automation_authorized,false) = false THEN
    v_reasons := array_append(v_reasons, 'automation_not_explicitly_authorized');
  END IF;

  IF NOT v_has_conn THEN
    v_state := 'BLOCKED_PENDING_PLATFORM_CONNECTION';
  ELSIF ('creative_not_approved' = ANY(v_reasons)
         OR 'creative_not_launch_safe' = ANY(v_reasons)
         OR 'product_identity_review_required' = ANY(v_reasons)
         OR 'media_asset_not_found' = ANY(v_reasons)) THEN
    v_state := 'BLOCKED_PENDING_APPROVAL';
  ELSIF ('no_destination_account_selected' = ANY(v_reasons) OR 'caption_not_approved' = ANY(v_reasons)) THEN
    v_state := 'BLOCKED_PENDING_CONTENT';
  ELSIF 'automation_not_explicitly_authorized' = ANY(v_reasons) THEN
    v_state := 'BLOCKED_PENDING_AUTOMATION_AUTHORIZATION';
  ELSE
    v_state := 'READY_FOR_MANUAL_PUBLISH';
  END IF;

  RETURN jsonb_build_object(
    'execution_state',  v_state,
    'execution_enabled', false,
    'blocked_reasons',  to_jsonb(v_reasons),
    'needed_capability', v_needed_cap,
    'content_kind', CASE WHEN v_is_text THEN 'TEXT' ELSE 'MEDIA' END,
    'has_connected_organic_connection', v_has_conn,
    'publish_mode',     coalesce(p_publish_mode,'MANUAL')
  );
END $function$;

-- fn_social_publishing_request: allow NULL media when content is TEXT (additive).
CREATE OR REPLACE FUNCTION public.fn_social_publishing_request(
  p_tenant_id uuid, p_platform text, p_media_asset_id uuid,
  p_marketing_draft_id uuid DEFAULT NULL, p_creative_request_id uuid DEFAULT NULL,
  p_business_id uuid DEFAULT NULL, p_destination_account text DEFAULT NULL,
  p_content jsonb DEFAULT '{}'::jsonb, p_scheduled_at timestamptz DEFAULT NULL,
  p_approval_id uuid DEFAULT NULL, p_caption_approved boolean DEFAULT false,
  p_publish_mode text DEFAULT 'MANUAL', p_automation_authorized boolean DEFAULT false,
  p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_pre  jsonb;
  v_id   uuid;
  v_err  text[] := ARRAY[]::text[];
  v_is_text boolean := (upper(coalesce(p_content->>'type','')) = 'TEXT');
BEGIN
  IF p_platform NOT IN ('META_FACEBOOK','META_INSTAGRAM','TIKTOK','LINKEDIN') THEN
    v_err := array_append(v_err,'invalid_platform');
  END IF;
  IF coalesce(p_publish_mode,'MANUAL') NOT IN ('MANUAL','AUTHORIZED_AUTO') THEN
    v_err := array_append(v_err,'invalid_publish_mode');
  END IF;
  -- Media required EXCEPT for an explicit TEXT post (additive).
  IF p_media_asset_id IS NULL AND NOT v_is_text THEN
    v_err := array_append(v_err,'missing_media_asset');
  END IF;
  IF array_length(v_err,1) > 0 THEN
    RETURN jsonb_build_object('ok',false,'errors',to_jsonb(v_err));
  END IF;

  v_pre := public.fn_social_publishing_preflight(
    p_tenant_id, p_platform, p_media_asset_id, p_destination_account,
    p_caption_approved, p_publish_mode, p_automation_authorized);

  IF p_persist THEN
    INSERT INTO public.social_publishing_requests(
      tenant_id, business_id, marketing_draft_id, creative_request_id, media_asset_id,
      platform, connection_type, destination_account, content, scheduled_at, approval_id,
      caption_approved, publish_mode, automation_authorized, execution_enabled,
      execution_state, blocked_reasons)
    VALUES(
      p_tenant_id, p_business_id, p_marketing_draft_id, p_creative_request_id, p_media_asset_id,
      p_platform, 'ORGANIC', p_destination_account, coalesce(p_content,'{}'::jsonb), p_scheduled_at, p_approval_id,
      coalesce(p_caption_approved,false), coalesce(p_publish_mode,'MANUAL'), coalesce(p_automation_authorized,false), false,
      v_pre->>'execution_state', v_pre->'blocked_reasons')
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'request_id', v_id,
    'execution_state', v_pre->>'execution_state', 'execution_enabled', false,
    'blocked_reasons', v_pre->'blocked_reasons',
    'lineage', jsonb_build_object('marketing_draft_id', p_marketing_draft_id,
      'creative_request_id', p_creative_request_id, 'media_asset_id', p_media_asset_id));
END $function$;

-- ============================================================================
-- 2. PER-REQUEST, SINGLE-USE LIVE GRANT
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.social_live_publish_grants (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publishing_request_id  uuid NOT NULL UNIQUE
                           REFERENCES public.social_publishing_requests(id) ON DELETE CASCADE,
  tenant_id              uuid NOT NULL,
  granted_by             uuid,
  granted_at             timestamptz NOT NULL DEFAULT now(),
  consumed_at            timestamptz,
  note                   text
);
ALTER TABLE public.social_live_publish_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS social_live_publish_grants_select_own ON public.social_live_publish_grants;
CREATE POLICY social_live_publish_grants_select_own
  ON public.social_live_publish_grants FOR SELECT TO authenticated
  USING (tenant_id = public.fn__own_tenant());

COMMENT ON TABLE public.social_live_publish_grants IS
  'Per-request, single-use authorization for ONE live organic publish. Consumed on success; grants no standing publishing authority. mig_345.';

-- Grant-maker: only the owning tenant member (or service_role via p_actor) may grant, for their own request.
CREATE OR REPLACE FUNCTION public.fn_social_grant_live_publish(
  p_request_id uuid, p_actor uuid DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_actor uuid; v_tenant uuid; v_mcount int; v_req_tenant uuid; v_id uuid;
BEGIN
  v_actor := coalesce(auth.uid(), p_actor);
  IF v_actor IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT count(*), min(m.application_ref::text)::uuid INTO v_mcount, v_tenant
  FROM public.member m WHERE m.auth_user_id = v_actor;
  IF v_mcount <> 1 OR v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','actor_tenant_unresolved'); END IF;
  SELECT tenant_id INTO v_req_tenant FROM public.social_publishing_requests WHERE id = p_request_id;
  IF v_req_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','request_not_found'); END IF;
  IF v_req_tenant <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  INSERT INTO public.social_live_publish_grants(publishing_request_id, tenant_id, granted_by, note)
  VALUES (p_request_id, v_tenant, v_actor, p_note)
  ON CONFLICT (publishing_request_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.social_live_publish_grants WHERE publishing_request_id = p_request_id;
  END IF;
  RETURN jsonb_build_object('ok',true,'grant_id',v_id,'publishing_request_id',p_request_id,'tenant_id',v_tenant);
END $function$;
REVOKE ALL ON FUNCTION public.fn_social_grant_live_publish(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_social_grant_live_publish(uuid,uuid,text) TO authenticated, service_role;

-- ============================================================================
-- 3. ISOLATED, RESTRICTED OUTBOUND SEND HELPER (only place an HTTP primitive lives)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn__social_fb_graph_send(p_url text, p_form jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_resp extensions.http_response;
BEGIN
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','20000');
  v_resp := extensions.http_post(p_url, p_form);     -- form-url-encodes p_form (incl. access_token)
  RETURN jsonb_build_object('status', v_resp.status, 'body',
    CASE WHEN v_resp.content IS NULL OR v_resp.content = '' THEN '{}'::jsonb
         ELSE (v_resp.content)::jsonb END);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 0, 'body', jsonb_build_object('transport_error', SQLERRM));
END $function$;
-- Supabase default privileges auto-grant EXECUTE on new public functions to anon/authenticated,
-- which REVOKE ... FROM PUBLIC does not remove. Revoke those roles explicitly so this raw outbound
-- send primitive is reachable ONLY by the SECURITY DEFINER executor / service_role.
REVOKE ALL ON FUNCTION public.fn__social_fb_graph_send(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn__social_fb_graph_send(text,jsonb) TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.fn__social_fb_graph_get(p_url text)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_resp extensions.http_response;
BEGIN
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','20000');
  v_resp := extensions.http_get(p_url);
  RETURN jsonb_build_object('status', v_resp.status, 'body',
    CASE WHEN v_resp.content IS NULL OR v_resp.content = '' THEN '{}'::jsonb
         ELSE (v_resp.content)::jsonb END);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 0, 'body', jsonb_build_object('transport_error', SQLERRM));
END $function$;
REVOKE ALL ON FUNCTION public.fn__social_fb_graph_get(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn__social_fb_graph_get(text) TO postgres, service_role;

-- ============================================================================
-- 4. EXECUTOR — add LIVE (grant-gated) path; VALIDATE_ONLY remains default
-- ============================================================================
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
  v_token      text;
  v_key        text;
  v_attempt_no int;
  v_attempt_id uuid;
  v_result_id  uuid;
  v_existing   record;
  v_payload    jsonb;
  v_err_class  text;
  v_err_msg    text;
  v_page_id    text;
  v_grant_id   uuid;
  v_send       jsonb;
  v_resp       jsonb;
  v_status     int;
  v_body       jsonb;
  v_post_id    text;
  v_permalink  text;
BEGIN
  v_actor := coalesce(auth.uid(), p_actor);
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','unauthenticated','retryable',false);
  END IF;

  SELECT count(*), min(m.application_ref::text)::uuid INTO v_mcount, v_tenant
  FROM public.member m WHERE m.auth_user_id = v_actor;
  IF v_mcount <> 1 OR v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','actor_tenant_unresolved','retryable',false);
  END IF;

  SELECT * INTO v_req FROM public.social_publishing_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error_class','INTERNAL_ERROR','error_message','request_not_found','retryable',false);
  END IF;

  IF v_req.tenant_id <> v_tenant THEN
    RETURN jsonb_build_object('ok',false,'error_class','CROSS_TENANT_REJECTED','error_message','request_belongs_to_another_tenant','retryable',false);
  END IF;

  IF v_req.platform <> 'META_FACEBOOK' THEN
    RETURN jsonb_build_object('ok',false,'error_class','PLATFORM_REJECTED','error_message','executor_handles_META_FACEBOOK_only','retryable',false);
  END IF;
  IF v_req.connection_type <> 'ORGANIC' THEN
    RETURN jsonb_build_object('ok',false,'error_class','WRONG_CONNECTION_TYPE','error_message','organic_executor_requires_ORGANIC_connection_type','retryable',false);
  END IF;

  v_content := coalesce(v_req.content, '{}'::jsonb);
  v_ctype   := upper(coalesce(v_content->>'type',
                 CASE WHEN v_req.media_asset_id IS NULL THEN 'TEXT' ELSE 'SINGLE_IMAGE' END));
  IF v_ctype NOT IN ('TEXT','SINGLE_IMAGE') THEN
    RETURN jsonb_build_object('ok',false,'error_class','UNSUPPORTED_CONTENT_TYPE',
      'error_message','only_TEXT_and_SINGLE_IMAGE_supported','content_type',v_ctype,'retryable',false);
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT a.id, a.execution_state, a.error_class, a.error_message INTO v_existing
    FROM public.social_publish_attempts a WHERE a.idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', v_existing.execution_state IN ('VALIDATED','PUBLISHED'),
        'idempotent_replay', true, 'attempt_id', v_existing.id,
        'execution_state', v_existing.execution_state,
        'error_class', v_existing.error_class, 'error_message', v_existing.error_message,
        'live_send_performed', false);
    END IF;
  END IF;

  -- ALREADY_PUBLISHED short-circuit (authoritative: never republish).
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

  v_key := coalesce(p_idempotency_key, gen_random_uuid()::text);
  SELECT coalesce(max(attempt_no),0)+1 INTO v_attempt_no
  FROM public.social_publish_attempts WHERE publishing_request_id = p_request_id;

  INSERT INTO public.social_publish_attempts(
    tenant_id, actor_user_id, publishing_request_id, platform, connection_id,
    attempt_no, idempotency_key, execution_mode, execution_state, started_at, created_at)
  VALUES (v_tenant, v_actor, p_request_id, v_req.platform, NULL,
    v_attempt_no, v_key, CASE WHEN v_mode='LIVE' THEN 'LIVE' WHEN v_mode='DRY_RUN' THEN 'DRY_RUN' ELSE 'VALIDATE_ONLY' END,
    'CLAIMED', now(), now())
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_attempt_id;

  IF v_attempt_id IS NULL THEN
    SELECT a.id, a.execution_state INTO v_existing
    FROM public.social_publish_attempts a WHERE a.idempotency_key = v_key;
    RETURN jsonb_build_object('ok', v_existing.execution_state IN ('VALIDATED','PUBLISHED'),
      'idempotent_replay', true, 'attempt_id', v_existing.id,
      'execution_state', v_existing.execution_state, 'live_send_performed', false);
  END IF;

  -- Preflight (defense in depth).
  v_pre := public.fn_social_publishing_preflight(
    v_tenant, v_req.platform, v_req.media_asset_id, v_req.destination_account,
    v_req.caption_approved, v_req.publish_mode, v_req.automation_authorized);
  v_pre_state := v_pre->>'execution_state';
  v_reasons   := coalesce(v_pre->'blocked_reasons','[]'::jsonb);

  IF v_pre_state <> 'READY_FOR_MANUAL_PUBLISH' THEN
    v_err_class := CASE
      WHEN v_reasons::text ILIKE '%no_connected_organic%' THEN 'NO_CONNECTED_ACCOUNT'
      WHEN v_reasons::text ILIKE '%launch_safe%' OR v_reasons::text ILIKE '%identity_review%' THEN 'IDENTITY_SAFETY_FAILED'
      WHEN v_reasons::text ILIKE '%media_asset_not_found%' THEN 'ASSET_NOT_READY'
      WHEN v_reasons::text ILIKE '%not_approved%' OR v_reasons::text ILIKE '%caption_not_approved%'
           OR v_reasons::text ILIKE '%no_destination_account%' THEN 'APPROVAL_REQUIRED'
      WHEN v_reasons::text ILIKE '%automation_not_explicitly_authorized%' THEN 'APPROVAL_REQUIRED'
      ELSE 'PREFLIGHT_FAILED' END;
    v_err_msg := 'preflight_state='||v_pre_state;
    UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'blocked_reasons',v_reasons,'retryable',false,'live_send_performed',false);
  END IF;

  v_needed_cap := CASE WHEN v_ctype = 'SINGLE_IMAGE' THEN 'PUBLISH_IMAGE' ELSE 'PUBLISH_TEXT' END;
  SELECT * INTO v_conn
  FROM public.social_platform_connections
  WHERE tenant_id = v_tenant AND platform = v_req.platform AND connection_type = 'ORGANIC'
    AND authorization_status = 'CONNECTED' AND revoked_at IS NULL
    AND (expires_at IS NULL OR expires_at > now()) AND capabilities ? v_needed_cap
  ORDER BY connected_at DESC NULLS LAST LIMIT 1;

  IF NOT FOUND THEN
    v_err_class := 'NO_CONNECTED_ACCOUNT'; v_err_msg := 'no_connected_organic_facebook_connection_with_'||v_needed_cap;
    UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'retryable',false,'live_send_performed',false);
  END IF;

  UPDATE public.social_publish_attempts SET connection_id = v_conn.id WHERE id = v_attempt_id;
  v_page_id := v_conn.external_account_id;

  v_required := public.fn_social_required_scopes(v_req.platform, 'ORGANIC');
  v_scope_ok := public.fn_social_scope_subset_ok(v_required, coalesce(v_conn.granted_scopes,'[]'::jsonb));
  IF NOT v_scope_ok THEN
    SELECT coalesce(jsonb_agg(req.v),'[]'::jsonb) INTO v_missing
    FROM jsonb_array_elements_text(v_required) req(v)
    WHERE lower(trim(req.v)) NOT IN (SELECT lower(trim(g.v)) FROM jsonb_array_elements_text(coalesce(v_conn.granted_scopes,'[]'::jsonb)) g(v));
    v_err_class := 'INSUFFICIENT_SCOPE'; v_err_msg := 'BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION';
    UPDATE public.social_publish_attempts SET execution_state='BLOCKED_EXTERNAL', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message,outbound_payload)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'BLOCKED_EXTERNAL',v_err_class,v_err_msg,
        jsonb_build_object('missing_scopes',v_missing,'required_scopes',v_required)) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'blocked','BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION',
      'missing_scopes',v_missing,'required_scopes',v_required,'retryable',false,'live_send_performed',false);
  END IF;

  v_token := public.fn_social_secret_read(v_conn.secret_ref);
  IF v_token IS NULL OR length(v_token) = 0 THEN
    v_err_class := 'NO_CONNECTED_ACCOUNT'; v_err_msg := 'page_token_unavailable';
    UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'retryable',false,'live_send_performed',false);
  END IF;

  -- Prepared outbound payload for the ledger (credential ALWAYS excluded).
  IF v_ctype = 'TEXT' THEN
    v_payload := jsonb_build_object('method','POST',
      'endpoint','https://graph.facebook.com/v21.0/'||v_page_id||'/feed',
      'body', jsonb_build_object('message', coalesce(v_content->>'message', v_content->>'caption','')),
      'credential','OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME');
  ELSE
    v_payload := jsonb_build_object('method','POST',
      'endpoint','https://graph.facebook.com/v21.0/'||v_page_id||'/photos',
      'body', jsonb_build_object('url', coalesce(v_content->>'image_url', v_content->>'url',''),
        'caption', coalesce(v_content->>'caption', v_content->>'message','')),
      'credential','OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME');
  END IF;

  -- ---- MODE DISPATCH -------------------------------------------------------------------------
  IF v_mode IN ('VALIDATE_ONLY','DRY_RUN') THEN
    v_token := NULL;  -- not used; discarded
    UPDATE public.social_publish_attempts SET execution_state='VALIDATED', completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,platform_post_id,permalink,published_at,result_state,outbound_payload)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,NULL,NULL,NULL,'VALIDATED',v_payload) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',true,'attempt_id',v_attempt_id,'result_id',v_result_id,'tenant_id',v_tenant,
      'request_id',p_request_id,'mode','VALIDATE_ONLY','content_type',v_ctype,'execution_state','VALIDATED','result_state','VALIDATED',
      'page_id',v_page_id,'connection_id',v_conn.id,'scope_ok',true,'required_scopes',v_required,
      'token_resolved',true,'token_exposed',false,'live_send_performed',false,'outbound_payload_prepared',true,
      'note','Validated. No Facebook post created (VALIDATE_ONLY).');

  ELSIF v_mode = 'LIVE' THEN
    -- Explicit, per-request, single-use grant REQUIRED. No grant => no send.
    SELECT id INTO v_grant_id FROM public.social_live_publish_grants
      WHERE publishing_request_id = p_request_id AND consumed_at IS NULL;
    IF v_grant_id IS NULL THEN
      v_token := NULL;
      v_err_class := 'LIVE_PUBLISH_NOT_AUTHORIZED'; v_err_msg := 'no_active_live_grant_for_request';
      UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
      INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message,outbound_payload)
        VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg,v_payload) RETURNING id INTO v_result_id;
      RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
        'error_class',v_err_class,'error_message',v_err_msg,'live_send_performed',false,'retryable',false);
    END IF;

    -- Assemble the real send payload WITH the token (local only; never stored/returned).
    IF v_ctype = 'TEXT' THEN
      v_send := jsonb_build_object('message', coalesce(v_content->>'message', v_content->>'caption',''), 'access_token', v_token);
    ELSE
      v_send := jsonb_build_object('url', coalesce(v_content->>'image_url', v_content->>'url',''),
                                   'caption', coalesce(v_content->>'caption', v_content->>'message',''), 'access_token', v_token);
    END IF;

    v_resp := public.fn__social_fb_graph_send((v_payload->>'endpoint'), v_send);
    v_token := NULL; v_send := NULL;   -- scrub
    v_status := coalesce((v_resp->>'status')::int, 0);
    v_body   := coalesce(v_resp->'body','{}'::jsonb);

    IF v_status IN (200,201) AND (v_body ? 'id' OR v_body ? 'post_id') THEN
      v_post_id := coalesce(v_body->>'post_id', v_body->>'id');
      v_permalink := 'https://www.facebook.com/'||v_post_id;
      UPDATE public.social_publish_attempts SET execution_state='PUBLISHED', completed_at=now() WHERE id=v_attempt_id;
      INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,platform_post_id,permalink,published_at,result_state,outbound_payload)
        VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,v_post_id,v_permalink,now(),'PUBLISHED',v_payload) RETURNING id INTO v_result_id;
      UPDATE public.social_live_publish_grants SET consumed_at = now() WHERE id = v_grant_id;
      UPDATE public.social_publishing_requests SET execution_state='EXECUTION_DISABLED', updated_at=now() WHERE id=p_request_id;
      RETURN jsonb_build_object('ok',true,'attempt_id',v_attempt_id,'result_id',v_result_id,'tenant_id',v_tenant,
        'request_id',p_request_id,'mode','LIVE','content_type',v_ctype,'execution_state','PUBLISHED','result_state','PUBLISHED',
        'page_id',v_page_id,'platform_post_id',v_post_id,'permalink',v_permalink,'published_at',now(),
        'token_exposed',false,'live_send_performed',true,
        'note','One organic Facebook post published.');
    ELSE
      v_err_class := CASE WHEN v_status = 0 OR v_status >= 500 THEN 'NETWORK_RETRYABLE' ELSE 'PLATFORM_REJECTED' END;
      v_err_msg := left('graph_status='||v_status||'; '||coalesce(v_body->'error'->>'message', v_body->>'transport_error',''), 400);
      UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
      INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message,outbound_payload)
        VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg,v_payload) RETURNING id INTO v_result_id;
      RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
        'error_class',v_err_class,'error_message',v_err_msg,'graph_status',v_status,
        'live_send_performed',(v_status<>0),'retryable',(v_err_class='NETWORK_RETRYABLE'));
    END IF;

  ELSE
    v_token := NULL;
    v_err_class := 'LIVE_PUBLISH_NOT_AUTHORIZED'; v_err_msg := 'unknown_execution_mode';
    UPDATE public.social_publish_attempts SET execution_state='FAILED', error_class=v_err_class, error_message=v_err_msg, completed_at=now() WHERE id=v_attempt_id;
    INSERT INTO public.social_post_results(tenant_id,actor_user_id,publishing_request_id,publish_attempt_id,platform,result_state,error_class,error_message,outbound_payload)
      VALUES (v_tenant,v_actor,p_request_id,v_attempt_id,v_req.platform,'FAILED',v_err_class,v_err_msg,v_payload) RETURNING id INTO v_result_id;
    RETURN jsonb_build_object('ok',false,'attempt_id',v_attempt_id,'result_id',v_result_id,
      'error_class',v_err_class,'error_message',v_err_msg,'live_send_performed',false,'retryable',false);
  END IF;
END; $function$;

COMMENT ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) IS
  'Facebook ORGANIC publish executor. VALIDATE_ONLY default; LIVE requires a per-request single-use grant and sends via the restricted fn__social_fb_graph_send helper. Token resolved from vault, never returned/logged/stored. Durable DB idempotency (one PUBLISHED per request). mig_345.';
REVOKE ALL ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_social_facebook_organic_execute(uuid,uuid,text,text) TO authenticated, service_role;

-- ============================================================================
-- 5. VERIFY A PUBLISHED POST ON PLATFORM (owner-scoped; token never returned)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_social_facebook_verify_post(p_result_id uuid, p_actor uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_actor uuid; v_tenant uuid; v_mcount int; r record; v_conn public.social_platform_connections%ROWTYPE;
  v_token text; v_resp jsonb; v_body jsonb; v_status int;
BEGIN
  v_actor := coalesce(auth.uid(), p_actor);
  IF v_actor IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT count(*), min(m.application_ref::text)::uuid INTO v_mcount, v_tenant FROM public.member m WHERE m.auth_user_id=v_actor;
  IF v_mcount <> 1 OR v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','actor_tenant_unresolved'); END IF;

  SELECT tenant_id, platform_post_id, publishing_request_id INTO r FROM public.social_post_results WHERE id = p_result_id;
  IF r.tenant_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','result_not_found'); END IF;
  IF r.tenant_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF r.platform_post_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','no_platform_post_id'); END IF;

  SELECT * INTO v_conn FROM public.social_platform_connections
    WHERE tenant_id=v_tenant AND platform='META_FACEBOOK' AND connection_type='ORGANIC' AND authorization_status='CONNECTED'
    ORDER BY connected_at DESC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_connection'); END IF;

  v_token := public.fn_social_secret_read(v_conn.secret_ref);
  v_resp := public.fn__social_fb_graph_get('https://graph.facebook.com/v21.0/'||r.platform_post_id
            ||'?fields=id,message,created_time,permalink_url,from&access_token='||extensions.urlencode(v_token));
  v_token := NULL;
  v_status := coalesce((v_resp->>'status')::int,0);
  v_body := coalesce(v_resp->'body','{}'::jsonb);

  RETURN jsonb_build_object('ok', v_status=200 AND (v_body->>'id') IS NOT NULL,
    'graph_status', v_status,
    'post_id', v_body->>'id',
    'from_page_id', v_body->'from'->>'id',
    'from_page_name', v_body->'from'->>'name',
    'message', v_body->>'message',
    'permalink_url', v_body->>'permalink_url',
    'created_time', v_body->>'created_time',
    'matches_connection_page', (v_body->'from'->>'id') = v_conn.external_account_id,
    'token_exposed', false);
END $function$;
REVOKE ALL ON FUNCTION public.fn_social_facebook_verify_post(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_social_facebook_verify_post(uuid,uuid) TO authenticated, service_role;

-- ============================================================================
-- 6. SELF-TEST (rolled back; NO real send — live path is gated so it is never reached here)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_social_facebook_organic_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';
  c_actor  uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  c_other  uuid := '17bb631a-d4a4-4b5e-870e-d35a40dd5434';
  c_page   text := '1273960209136806';
  v_asset uuid; v_req uuid; v_req_text uuid; v_r jsonb; v_r2 jsonb; v_cnt int;
  v_exec text := pg_get_functiondef('public.fn_social_facebook_organic_execute(uuid,uuid,text,text)'::regprocedure);
  v_help text := pg_get_functiondef('public.fn__social_fb_graph_send(text,jsonb)'::regprocedure);
  v_help_auth boolean;
  v_spend_before int; v_spend_after int; v_token text; v_leak boolean;
BEGIN
  -- Static invariants.
  v := v || jsonb_build_object('case','executor_has_no_raw_http_primitive','pass',
        v_exec !~* 'http_post' AND v_exec !~* 'http_get' AND v_exec !~* 'net\.http_' AND v_exec !~* 'pg_net' AND v_exec !~* 'extensions\.http');
  v := v || jsonb_build_object('case','send_helper_contains_http_primitive','pass', v_help ~* 'http_post');
  SELECT bool_or(r.rolname IN ('authenticated','anon')) INTO v_help_auth
    FROM aclexplode((SELECT proacl FROM pg_proc WHERE oid='public.fn__social_fb_graph_send(text,jsonb)'::regprocedure)) a
    JOIN pg_roles r ON r.oid=a.grantee WHERE a.privilege_type='EXECUTE';
  v := v || jsonb_build_object('case','send_helper_not_granted_to_app_users','pass', coalesce(v_help_auth,false)=false);
  v := v || jsonb_build_object('case','no_spend_or_campaign_reference','pass',
        v_exec !~* 'reserve_spend' AND v_exec !~* 'release_spend' AND v_exec !~* 'marketing_spend_authority'
        AND v_exec !~* 'spend_reservations' AND v_exec !~* 'marketing_campaign_executions'
        AND v_exec !~* 'create_spend_authority' AND v_exec !~* 'adset' AND v_exec !~* 'campaign');

  BEGIN
    -- TEXT request (no media) now reaches READY via additive gate.
    INSERT INTO public.social_publishing_requests(tenant_id,platform,connection_type,media_asset_id,destination_account,content,caption_approved,publish_mode,automation_authorized,execution_enabled,execution_state,blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',NULL,c_page,jsonb_build_object('type','TEXT','message','Validation only — not published'),true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req_text;

    -- SINGLE_IMAGE request (approved image) still works.
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type)
    VALUES (c_tenant,'IMAGE','SUPPLIER_PROVIDED','CLEARED','COMPLETE','APPROVED',true,'IDENTITY_RESOLVED','https://img.example.com/x.jpg','image/jpeg')
    RETURNING id INTO v_asset;
    INSERT INTO public.social_publishing_requests(tenant_id,platform,connection_type,media_asset_id,destination_account,content,caption_approved,publish_mode,automation_authorized,execution_enabled,execution_state,blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,jsonb_build_object('type','SINGLE_IMAGE','image_url','https://img.example.com/x.jpg','caption','v'),true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb)
    RETURNING id INTO v_req;

    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_actor::text,'role','authenticated')::text, true);

    -- (default) VALIDATE_ONLY default + no send; TEXT path reaches VALIDATED.
    SELECT count(*) INTO v_spend_before FROM public.spend_reservations;
    v_r := public.fn_social_facebook_organic_execute(v_req_text);
    SELECT count(*) INTO v_spend_after FROM public.spend_reservations;
    v := v || jsonb_build_object('case','text_validate_only_default','pass',
          coalesce((v_r->>'ok')::boolean,false) AND v_r->>'mode'='VALIDATE_ONLY' AND v_r->>'result_state'='VALIDATED'
          AND v_r->>'content_type'='TEXT' AND (v_r->>'live_send_performed')='false');
    v := v || jsonb_build_object('case','no_spend_reservation_created','pass', v_spend_after=v_spend_before);

    -- image validate
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','image_validate_real_page','pass',
          coalesce((v_r->>'ok')::boolean,false) AND v_r->>'page_id'=c_page AND (v_r->>'token_resolved')='true' AND (v_r->>'token_exposed')='false');

    -- token never leaks
    v_token := public.fn_social_secret_read('social:4650f21e-06c3-4b28-8c99-5e47377e6536:page');
    SELECT (position(v_token in coalesce((SELECT string_agg(a::text,'') FROM public.social_publish_attempts a WHERE a.publishing_request_id IN (v_req,v_req_text)),'')) > 0
         OR position(v_token in coalesce((SELECT string_agg(r::text,'') FROM public.social_post_results r WHERE r.publishing_request_id IN (v_req,v_req_text)),'')) > 0
         OR position(v_token in v_r::text) > 0) INTO v_leak;
    v := v || jsonb_build_object('case','token_never_in_ledger_or_response','pass', v_leak=false);
    v_token := NULL;

    -- LIVE requires an explicit grant: READY request, LIVE, NO grant => refused, no send, not PUBLISHED.
    v_r := public.fn_social_facebook_organic_execute(v_req_text, NULL, 'LIVE');
    SELECT count(*) INTO v_cnt FROM public.social_post_results WHERE publishing_request_id=v_req_text AND result_state='PUBLISHED';
    v := v || jsonb_build_object('case','live_requires_grant_no_send','pass',
          v_r->>'error_class'='LIVE_PUBLISH_NOT_AUTHORIZED' AND (v_r->>'live_send_performed')='false' AND v_cnt=0);

    -- LIVE with grant but NON-READY request => gates precede send (preflight fails, no send, no PUBLISHED).
    INSERT INTO public.social_publishing_requests(tenant_id,platform,connection_type,media_asset_id,destination_account,content,caption_approved,publish_mode,automation_authorized,execution_enabled,execution_state,blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',NULL,c_page,jsonb_build_object('type','TEXT','message','x'),false,'MANUAL',false,false,'BLOCKED_PENDING_CONTENT','[]'::jsonb)
    RETURNING id INTO v_req;
    PERFORM public.fn_social_grant_live_publish(v_req, c_actor, 'selftest');
    v_r := public.fn_social_facebook_organic_execute(v_req, NULL, 'LIVE');
    SELECT count(*) INTO v_cnt FROM public.social_post_results WHERE publishing_request_id=v_req AND result_state='PUBLISHED';
    v := v || jsonb_build_object('case','live_gate_precedes_send','pass',
          coalesce((v_r->>'ok')::boolean,true)=false AND v_r->>'error_class' IN ('APPROVAL_REQUIRED','PREFLIGHT_FAILED') AND v_cnt=0,'observed',v_r->>'error_class');

    -- cross-tenant
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_other::text,'role','authenticated')::text, true);
    v_r := public.fn_social_facebook_organic_execute(v_req_text);
    v := v || jsonb_build_object('case','cross_tenant_rejected','pass', v_r->>'error_class'='CROSS_TENANT_REJECTED');
    PERFORM set_config('request.jwt.claims', json_build_object('sub',c_actor::text,'role','authenticated')::text, true);

    -- identity/launch unsafe
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type)
    VALUES (c_tenant,'IMAGE','SUPPLIER_PROVIDED','CLEARED','COMPLETE','APPROVED',false,'IDENTITY_REVIEW_REQUIRED','x','image/jpeg') RETURNING id INTO v_asset;
    INSERT INTO public.social_publishing_requests(tenant_id,platform,connection_type,media_asset_id,destination_account,content,caption_approved,publish_mode,automation_authorized,execution_enabled,execution_state,blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ORGANIC',v_asset,c_page,jsonb_build_object('type','SINGLE_IMAGE','image_url','x','caption','y'),true,'MANUAL',false,false,'BLOCKED_PENDING_APPROVAL','[]'::jsonb) RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','identity_or_launch_unsafe_rejected','pass', v_r->>'error_class'='IDENTITY_SAFETY_FAILED');

    -- wrong connection type
    INSERT INTO public.social_publishing_requests(tenant_id,platform,connection_type,media_asset_id,destination_account,content,caption_approved,publish_mode,automation_authorized,execution_enabled,execution_state,blocked_reasons)
    VALUES (c_tenant,'META_FACEBOOK','ADVERTISING',NULL,c_page,jsonb_build_object('type','TEXT','message','x'),true,'MANUAL',false,false,'READY_FOR_MANUAL_PUBLISH','[]'::jsonb) RETURNING id INTO v_req;
    v_r := public.fn_social_facebook_organic_execute(v_req);
    v := v || jsonb_build_object('case','wrong_connection_type_rejected','pass', v_r->>'error_class'='WRONG_CONNECTION_TYPE');

    -- duplicate idempotency (validate)
    v_r  := public.fn_social_facebook_organic_execute(v_req_text, NULL, 'VALIDATE_ONLY', 'idem-live-k1');
    v_r2 := public.fn_social_facebook_organic_execute(v_req_text, NULL, 'VALIDATE_ONLY', 'idem-live-k1');
    SELECT count(*) INTO v_cnt FROM public.social_publish_attempts WHERE idempotency_key='idem-live-k1';
    v := v || jsonb_build_object('case','duplicate_execution_idempotent','pass',
          coalesce((v_r2->>'idempotent_replay')::boolean,false) AND v_cnt=1);

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
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
