-- STRATELOQ video render backend — config-drift fix + honest backend resolution.
--
-- Two problems this migration fixes (no new provider, no parallel system, Product Asset Lock intact):
--
-- 1) CONFIG DRIFT (crash): a prior migration dropped `candidate_backends` from the
--    STRATELOQ_VIDEO_COMPOSITION provider, so fn_ad_render_dispatch emitted candidate_backends=null
--    and jsonb_array_length(null) crashed the dispatch. We restore the 2 Strateloq-OWNED FFmpeg
--    render options (a self-hosted FFmpeg worker, or an n8n FFmpeg executor) — NOT a third-party
--    render SaaS. These are render *options*, not a connected worker.
--
-- 2) ACCIDENTAL "not connected": fn_media_composition_backend() resolved a backend by matching
--    config->>'capability'='VIDEO_COMPOSITION', but the STRATELOQ_VIDEO_COMPOSITION provider never
--    carried that key, so resolution returned NULL for the *wrong* reason (missing key) instead of
--    the honest one (no render worker is actually provisioned). We make resolution deliberate AND
--    honest: the provider now *declares* VIDEO_COMPOSITION, and a backend resolves to a concrete
--    name ONLY when an `active_backend` with a non-empty server-side worker reference is connected.
--    Until a founder provisions a worker, resolution stays NULL and dispatch stays
--    BLOCKED_RENDER_BACKEND — the composition spec remains ready and provider-independent.
--
-- Nothing here marks a backend connected; no secret/URL value is stored (worker_ref is a reference).

-- (1) Honest, pure resolution of a composition backend from a provider config.
--     Connected == active_backend is an object carrying a non-empty worker_ref. Else NULL.
CREATE OR REPLACE FUNCTION public.fn_media_composition_backend_resolve(p_config jsonb)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_config IS NOT NULL
         AND jsonb_typeof(p_config->'active_backend') = 'object'
         AND coalesce(nullif(btrim(p_config->'active_backend'->>'worker_ref'), ''), '') <> ''
    THEN nullif(btrim(p_config->'active_backend'->>'name'), '')
    ELSE NULL
  END;
$function$;
REVOKE ALL ON FUNCTION public.fn_media_composition_backend_resolve(jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_media_composition_backend_resolve(jsonb) TO authenticated, service_role;

-- (2) Composition backend resolver: the enabled provider that DECLARES VIDEO_COMPOSITION, resolved
--     honestly through the helper. Returns NULL (→ dispatch BLOCKED_RENDER_BACKEND) until a worker
--     is actually connected. Signature/behaviour contract unchanged for callers.
CREATE OR REPLACE FUNCTION public.fn_media_composition_backend()
 RETURNS text LANGUAGE sql STABLE SET search_path TO ''
AS $function$
  SELECT public.fn_media_composition_backend_resolve(config)
    FROM public.media_providers
   WHERE enabled AND config->>'capability' = 'VIDEO_COMPOSITION'
   ORDER BY created_at LIMIT 1;
$function$;

-- (3) Repair STRATELOQ_VIDEO_COMPOSITION config: declare the capability, record the honest
--     connection_state, and (re)assert the 2 Strateloq-owned render options. active_backend is left
--     absent on purpose (no worker provisioned), so the provider stays honestly NOT_CONNECTED.
UPDATE public.media_providers
   SET config = (config - 'active_backend')
     || jsonb_build_object(
          'capability', 'VIDEO_COMPOSITION',
          'connection_state', 'NOT_CONNECTED',
          'candidate_backends', jsonb_build_array(
            jsonb_build_object(
              'name','self_hosted_ffmpeg_worker','kind','STRATELOQ_OWNED_FFMPEG_WORKER',
              'fit','primary: runs scripts/compositor/pulse_compositor.py on a controlled server/container with bundled static FFmpeg; $0 external API; needs a provisioned worker URL + server-side auth'),
            jsonb_build_object(
              'name','n8n_ffmpeg_executor','kind','STRATELOQ_OWNED_FFMPEG_WORKER',
              'fit','alt: an n8n workflow that runs the same FFmpeg composition using existing n8n infra')),
          'connection_contract', 'To connect: set config.active_backend = {name, kind, worker_ref} where worker_ref names a server-side worker endpoint + auth (never stored here as a value). Resolution then returns that backend name and dispatch can cross to RENDERING.')
 WHERE name = 'STRATELOQ_VIDEO_COMPOSITION';

-- (4) Dedicated honesty selftest for the resolution mechanism (pure; no data, no provider mutation).
CREATE OR REPLACE FUNCTION public.fn_media_composition_backend_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; v_connected jsonb; v_live_cap text; v_live_state text; v_n int;
BEGIN
  -- Not connected: candidate_backends present but no active_backend → NULL (honest BLOCKED).
  v := v || jsonb_build_object('case','RESOLVE_NULL_WHEN_NO_ACTIVE_BACKEND','pass',
    public.fn_media_composition_backend_resolve(jsonb_build_object(
      'capability','VIDEO_COMPOSITION','candidate_backends',jsonb_build_array(jsonb_build_object('name','x')))) IS NULL);

  -- Active backend present but with an empty worker_ref → still NULL (not falsely connected).
  v := v || jsonb_build_object('case','RESOLVE_NULL_WHEN_WORKER_REF_EMPTY','pass',
    public.fn_media_composition_backend_resolve(jsonb_build_object(
      'capability','VIDEO_COMPOSITION','active_backend',jsonb_build_object('name','self_hosted_ffmpeg_worker','worker_ref',''))) IS NULL);

  -- Properly connected: active_backend with a non-empty worker_ref → resolves to that name.
  v_connected := jsonb_build_object('capability','VIDEO_COMPOSITION',
    'active_backend',jsonb_build_object('name','self_hosted_ffmpeg_worker','kind','STRATELOQ_OWNED_FFMPEG_WORKER','worker_ref','worker://ffmpeg-1'));
  v := v || jsonb_build_object('case','RESOLVE_NAME_WHEN_CONNECTED','pass',
    public.fn_media_composition_backend_resolve(v_connected) = 'self_hosted_ffmpeg_worker');

  -- Live provider: declares VIDEO_COMPOSITION, is honestly NOT_CONNECTED, and exposes >=2 options.
  SELECT config->>'capability', config->>'connection_state',
         jsonb_array_length(config->'candidate_backends')
    INTO v_live_cap, v_live_state, v_n
    FROM public.media_providers WHERE name='STRATELOQ_VIDEO_COMPOSITION';
  v := v || jsonb_build_object('case','LIVE_PROVIDER_DECLARES_CAPABILITY','pass',(v_live_cap='VIDEO_COMPOSITION'),'detail',v_live_cap);
  v := v || jsonb_build_object('case','LIVE_PROVIDER_HONESTLY_NOT_CONNECTED','pass',
    (v_live_state='NOT_CONNECTED' AND public.fn_media_composition_backend() IS NULL),'detail',v_live_state);
  v := v || jsonb_build_object('case','LIVE_PROVIDER_HAS_STRATELOQ_OWNED_OPTIONS','pass',
    (v_n>=2 AND NOT EXISTS(SELECT 1 FROM public.media_providers p,
        jsonb_array_elements(p.config->'candidate_backends') cb
      WHERE p.name='STRATELOQ_VIDEO_COMPOSITION' AND cb->>'kind'<>'STRATELOQ_OWNED_FFMPEG_WORKER')),'detail',v_n);

  RETURN jsonb_build_object('suite','composition_backend_resolution',
    'total', jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_composition_backend_selftest() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_media_composition_backend_selftest() TO authenticated, service_role;
