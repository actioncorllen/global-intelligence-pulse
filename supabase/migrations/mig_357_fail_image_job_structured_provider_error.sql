-- STRATELOQ post-P0 integrity #4: structured provider-error observability.
-- New overload of fn_media_fail_image_job that records a sanitized, structured provider failure on
-- the job provenance (provider / stage / provider_error_code / provider_error_type /
-- provider_error_param / provider_error_message) in addition to the short error_state. No secrets,
-- credentials or raw payloads are stored. The existing 3-arg overload is unchanged; the request
-- state sync is handled by the status-change trigger (mig_352). The edge function
-- creative-image-execute passes the provider error (e.g. OpenAI unsupported_file_mimetype) here.

CREATE OR REPLACE FUNCTION public.fn_media_fail_image_job(p_job_id uuid, p_tenant uuid, p_reason text, p_provider_error jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_ok boolean; v_err jsonb;
BEGIN
  v_err := CASE WHEN p_provider_error IS NULL OR jsonb_typeof(p_provider_error) <> 'object' THEN NULL
    ELSE jsonb_strip_nulls(jsonb_build_object(
      'provider', left(coalesce(p_provider_error->>'provider',''),80),
      'stage', left(coalesce(p_provider_error->>'stage',''),80),
      'provider_error_code', left(coalesce(p_provider_error->>'provider_error_code',''),120),
      'provider_error_type', left(coalesce(p_provider_error->>'provider_error_type',''),120),
      'provider_error_param', left(coalesce(p_provider_error->>'provider_error_param',''),120),
      'provider_error_message', left(coalesce(p_provider_error->>'provider_error_message',''),500))) END;
  UPDATE public.media_image_jobs
     SET status='FAILED', error_state=left(coalesce(p_reason,'executor_failed'),200), updated_at=now(),
         provenance = coalesce(provenance,'{}'::jsonb)
           || jsonb_build_object('failed_at', now(), 'fail_reason', left(coalesce(p_reason,''),300))
           || CASE WHEN v_err IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('provider_error', v_err) END
   WHERE id=p_job_id AND tenant_id=p_tenant AND status IN ('GENERATING','READY_TO_DISPATCH')
  RETURNING true INTO v_ok;
  RETURN jsonb_build_object('ok', coalesce(v_ok,false), 'job_id', p_job_id,
    'status', CASE WHEN coalesce(v_ok,false) THEN 'FAILED' ELSE 'no_transition' END,
    'provider_error', v_err);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_media_fail_image_job(uuid,uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_fail_image_job(uuid,uuid,text,jsonb) TO service_role;
