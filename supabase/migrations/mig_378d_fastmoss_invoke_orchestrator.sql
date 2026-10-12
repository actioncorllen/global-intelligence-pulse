-- mig_378d — Secure DB-orchestrated trigger for FastMoss (mirrors the Kalodata orchestrator).
-- Reuses the shared single-use capability nonce (kalodata_invoke_nonce +
-- fn_kalodata_consume_invoke_nonce) the fastmoss-discovery broker validates via its own
-- service-role DB access. Broker stays verify_jwt=true; no shared secret exposed; the FastMoss
-- client secret stays only in the edge env. Backend-only (service_role). Anon key (public) is
-- passed only to satisfy the gateway's verify_jwt.
CREATE OR REPLACE FUNCTION public.fn_fastmoss_run_discovery(p_user_id uuid, p_market text, p_candidate_limit int, p_anon_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_req bigint;
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/fastmoss-discovery';
BEGIN
  IF p_user_id IS NULL OR coalesce(btrim(p_market),'')='' OR coalesce(btrim(p_anon_key),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,p_user_id,upper(btrim(p_market)));
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',upper(btrim(p_market)),'user_id',p_user_id,
                               'candidate_limit',greatest(1,least(coalesce(p_candidate_limit,10),10))),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,
                                  'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_req;
  RETURN jsonb_build_object('ok',true,'request_id',v_req,'market',upper(btrim(p_market)));
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_run_discovery(uuid, text, int, text) TO service_role;
