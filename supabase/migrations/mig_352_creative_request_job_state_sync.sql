-- STRATELOQ post-P0 integrity #1: request<->job generation_state synchronization.
-- creative_production_requests.generation_state is a MIRROR of the authoritative media job
-- status (fn_creative_studio_generate sets it synchronously at dispatch). Async completion/
-- failure never re-synced it, leaving requests stuck at GENERATING. These derived-state triggers
-- (same pattern as the existing updated_at triggers) propagate the job's status onto the linked
-- request on every status change. Not a parallel state machine.
-- Verified: SUCCESS (job GENERATED_REVIEW_REQUIRED -> request GENERATED_REVIEW_REQUIRED) and
-- FAILURE (job FAILED -> request FAILED).

CREATE OR REPLACE FUNCTION public.fn_sync_request_state_from_image_job()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.creative_production_requests
       SET generation_state = NEW.status
     WHERE generated_image_job_id = NEW.id
       AND tenant_id = NEW.tenant_id
       AND generation_state IS DISTINCT FROM NEW.status;
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_sync_request_state_from_video_job()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.creative_production_requests
       SET generation_state = NEW.status
     WHERE generated_video_job_id = NEW.id
       AND tenant_id = NEW.tenant_id
       AND generation_state IS DISTINCT FROM NEW.status;
  END IF;
  RETURN NEW;
END; $function$;

REVOKE ALL ON FUNCTION public.fn_sync_request_state_from_image_job() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_sync_request_state_from_video_job() FROM public, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sync_request_from_image_job ON public.media_image_jobs;
CREATE TRIGGER trg_sync_request_from_image_job
  AFTER UPDATE OF status ON public.media_image_jobs
  FOR EACH ROW EXECUTE FUNCTION public.fn_sync_request_state_from_image_job();

DROP TRIGGER IF EXISTS trg_sync_request_from_video_job ON public.media_video_jobs;
CREATE TRIGGER trg_sync_request_from_video_job
  AFTER UPDATE OF status ON public.media_video_jobs
  FOR EACH ROW EXECUTE FUNCTION public.fn_sync_request_state_from_video_job();
