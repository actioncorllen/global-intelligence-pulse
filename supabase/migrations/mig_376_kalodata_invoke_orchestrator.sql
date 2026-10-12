-- mig_376 — Secure DB-orchestrated trigger for the Kalodata COMMERCE lane.
--
-- The COMMERCE lane needs a backend trigger (the SEARCH lane has n8n 013Q). This adds a
-- DB-side orchestrator that invokes the kalodata-discovery broker via pg_net, authenticated
-- by a single-use, 5-minute capability nonce. The broker validates the nonce using its own
-- service-role DB access (fn_kalodata_consume_invoke_nonce) — so the Edge Function stays
-- verify_jwt=true, no shared secret is exposed, and the Kalodata key stays only in edge env.
-- Strength is equivalent to a bearer token: a caller needs a valid, unused, unexpired,
-- DB-created 244-bit nonce. Backend-only (service_role). The anon key (public) is passed at
-- call time only to satisfy the gateway's verify_jwt; it grants no trust by itself.

CREATE TABLE IF NOT EXISTS public.kalodata_invoke_nonce (
  token      text PRIMARY KEY,
  user_id    uuid,
  market     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  used_at    timestamptz
);
ALTER TABLE public.kalodata_invoke_nonce ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.fn_kalodata_consume_invoke_nonce(p_token text)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE ok boolean := false;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN RETURN false; END IF;
  UPDATE public.kalodata_invoke_nonce
    SET used_at = now()
    WHERE token = p_token AND used_at IS NULL AND created_at > now() - interval '5 minutes'
    RETURNING true INTO ok;
  RETURN coalesce(ok, false);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_consume_invoke_nonce(text) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_discovery(p_user_id uuid, p_market text, p_candidate_limit int, p_anon_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_req bigint;
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/kalodata-discovery';
BEGIN
  IF p_user_id IS NULL OR coalesce(btrim(p_market),'')='' OR coalesce(btrim(p_anon_key),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,p_user_id,upper(btrim(p_market)));
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',upper(btrim(p_market)),'user_id',p_user_id,
                               'candidate_limit',greatest(1,least(coalesce(p_candidate_limit,10),25))),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,
                                  'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_req;
  RETURN jsonb_build_object('ok',true,'request_id',v_req,'market',upper(btrim(p_market)));
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_discovery(uuid, text, int, text) TO service_role;
