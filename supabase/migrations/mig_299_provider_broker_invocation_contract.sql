-- mig_299_provider_broker_invocation_contract.sql
-- STRATELOQ — durable server-side invocation contract for the provider broker edge function.
--
-- ROOT CAUSE of the recurring `401 {"code":"UNAUTHORIZED_LEGACY_JWT","message":"Invalid JWT"}`
-- (pg_net requests 137 and 143): ad-hoc, hand-authored server-side SQL pasted the ~220-char gateway
-- JWT directly into the net.http_post `Authorization: Bearer <...>` literal and mistyped it. The
-- Supabase Edge *gateway* (verify_jwt=true) rejected the malformed JWT BEFORE the function body ran
-- — proven by the gateway error envelope ({"code","message"}) which the function never emits (the
-- function's own auth denial is `403 {"ok":false,"error":"forbidden_requires_service_role_or_valid_nonce"}`),
-- and by every correctly-keyed sibling request reaching the function. It was an operator transcription
-- error in investigative SQL, NOT a defect in any committed caller:
--   * fn_fastmoss_run_discovery / fn_kalodata_run_discovery receive the (public) anon key as a
--     parameter supplied by the frontend and never hand-type it;
--   * server_integration_config holds only the n8n research webhook (url + opaque secret), no JWT;
--   * there was previously NO sanctioned server-side (frontend-less) invocation path, so manual test
--     SQL hand-pasted the key — the sole recurrence vector.
--
-- FIX (smallest durable correction; prevents recurrence without weakening security):
-- fn_invoke_provider_broker(...) is the single sanctioned server-side path to the broker. It reads the
-- gateway credential from server_integration_config (never hand-typed) and standardizes on the NEW
-- Supabase PUBLISHABLE key class (sb_publishable_...), which the gateway accepts and which is not a
-- legacy JWT — de-risking the legacy-key migration. verify_jwt stays ON. The broker's independent
-- in-function authorization gate is unchanged: a single-use nonce (minted here) OR service_role. The
-- publishable key only satisfies the gateway; it grants nothing on its own (a valid gateway credential
-- with no/forged nonce is still denied 403 by the broker). Least privilege: service_role only.
--
-- OPERATIONAL PREREQUISITE (applied live, NOT committed — no credential ever lands in source control):
-- the row server_integration_config WHERE key='edge_gateway' must hold:
--     url    = the project base URL (https://<ref>.supabase.co)
--     secret = the project's PUBLIC publishable key (sb_publishable_...)   -- public; not a secret
-- Populate it once via the Supabase Dashboard / a non-committed statement, e.g.:
--     INSERT INTO public.server_integration_config(key,url,secret,updated_at)
--     VALUES ('edge_gateway','https://<ref>.supabase.co','<sb_publishable_...>',now())
--     ON CONFLICT ... ;   -- (or guarded insert/update)
-- fn_invoke_provider_broker raises `edge_gateway_unconfigured` until the row is populated.
--
-- SECURITY: no secret values are present in this file. The publishable key is public by design; the
-- real authorization is (a) EXECUTE restricted to service_role, and (b) the single-use nonce consumed
-- by the broker. Tenant/market binding flows through the nonce. No change to verify_jwt, to the broker
-- source, to tenant isolation, to nonce single-use, to secret redaction, or to the Product Asset Lock.

CREATE OR REPLACE FUNCTION public.fn_invoke_provider_broker(
  p_function text, p_payload jsonb, p_user_id uuid, p_market text)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_slug  text := lower(btrim(coalesce(p_function,'')));
  v_base  text;
  v_key   text;
  v_token text;
  v_req   bigint;
BEGIN
  -- Allowlist: never invoke an arbitrary edge function.
  IF v_slug NOT IN ('fastmoss-product-detail') THEN
    RAISE EXCEPTION 'broker_function_not_allowlisted' USING ERRCODE='22023';
  END IF;
  IF p_user_id IS NULL OR coalesce(btrim(p_market),'')='' OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'missing_args' USING ERRCODE='22023';
  END IF;
  -- Gateway credential read from config (migration-forward publishable key); never hand-typed.
  SELECT url, secret INTO v_base, v_key
    FROM public.server_integration_config WHERE key='edge_gateway';
  IF coalesce(btrim(v_base),'')='' OR coalesce(btrim(v_key),'')='' THEN
    RAISE EXCEPTION 'edge_gateway_unconfigured' USING ERRCODE='22023';
  END IF;
  -- Independent in-function authorization gate: single-use nonce (64 hex chars) bound to tenant+market.
  v_token := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market)
    VALUES (v_token, p_user_id, upper(btrim(p_market)));
  SELECT net.http_post(
    url := rtrim(v_base,'/')||'/functions/v1/'||v_slug,
    body := p_payload,
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'apikey', v_key,
      'Authorization','Bearer '||v_key,
      'x-pulse-nonce', v_token),
    timeout_milliseconds := 60000
  ) INTO v_req;
  RETURN v_req;
END $function$;

-- Least privilege: server/internal only. A SECURITY DEFINER function that mints a trust nonce MUST NOT
-- be callable by customer/browser roles.
REVOKE ALL ON FUNCTION public.fn_invoke_provider_broker(text,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_invoke_provider_broker(text,jsonb,uuid,text) TO service_role;
