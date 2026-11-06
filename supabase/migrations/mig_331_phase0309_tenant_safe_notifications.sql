-- mig_331_phase0309_tenant_safe_notifications.sql
-- Phase 03.09: smallest tenant-safe notifications backend. APPLIED to prod nxaunmyihhjixxxljcqt (founder-approved).
--
-- Inspected first (no suitable existing feed to reuse): daily_briefs (a brief, not a notifications feed),
-- growth_messages (separate consent-gated growth-agent subsystem), user_events (raw analytics log),
-- ad_studio_briefs (campaign briefs). None models per-user read/unread notifications.
--
-- Established pattern: RLS owner-only read + SECURITY DEFINER auth.uid() wrappers for read/mark; writes are
-- system-side only (service_role via fn_emit_notification). Reversible; touches no existing data.
--
-- Verified live (self-cleaning QA): emit -> owner sees 1 unread; cross-tenant sees 0 (isolation);
-- mark_all -> updated=1, unread->0; unauthenticated -> status unauthenticated; grants auth_read=true /
-- anon_read=false / auth_emit=false / svc_emit=true; QA row removed (0 remaining).
--
-- Rollback: DROP FUNCTION fn_emit_notification(uuid,text,text,text,text), mark_all_notifications_read(),
--   mark_notification_read(uuid), get_own_notifications(integer); DROP TABLE public.pulse_notifications.

CREATE TABLE IF NOT EXISTS public.pulse_notifications (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind       text NOT NULL DEFAULT 'INFO',
  title      text NOT NULL,
  body       text,
  link       text,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at    timestamptz
);
CREATE INDEX IF NOT EXISTS idx_pulse_notifications_user_created
  ON public.pulse_notifications (user_id, created_at DESC);

ALTER TABLE public.pulse_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pulse_notifications_owner_select ON public.pulse_notifications;
CREATE POLICY pulse_notifications_owner_select ON public.pulse_notifications
  FOR SELECT TO authenticated USING (user_id = auth.uid());
-- No authenticated INSERT/UPDATE/DELETE policy -> direct writes denied; mark-read via SECURITY DEFINER fn.
REVOKE ALL ON public.pulse_notifications FROM anon, authenticated;
GRANT SELECT ON public.pulse_notifications TO authenticated;  -- still gated by the owner-only policy

CREATE OR REPLACE FUNCTION public.get_own_notifications(p_limit integer DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_limit integer := greatest(1, least(coalesce(p_limit,30), 100));
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','unauthenticated','items',jsonb_build_array(),'unread_count',0);
  END IF;
  RETURN jsonb_build_object(
    'status','ok',
    'unread_count', (SELECT count(*) FROM public.pulse_notifications WHERE user_id=v_uid AND read_at IS NULL),
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'title', s.title, 'body', s.body, 'link', s.link,
        'created_at', s.created_at, 'read', (s.read_at IS NOT NULL)))
      FROM (SELECT * FROM public.pulse_notifications WHERE user_id=v_uid
            ORDER BY (read_at IS NULL) DESC, created_at DESC LIMIT v_limit) s), jsonb_build_array())
  );
END; $function$;
REVOKE ALL ON FUNCTION public.get_own_notifications(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_notifications(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_n integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  UPDATE public.pulse_notifications SET read_at=now() WHERE id=p_id AND user_id=v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','updated',v_n);
END; $function$;
REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_n integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  UPDATE public.pulse_notifications SET read_at=now() WHERE user_id=v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','updated',v_n);
END; $function$;
REVOKE ALL ON FUNCTION public.mark_all_notifications_read() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;

-- Service-side emit (generators / n8n via service_role). NOT exposed to authenticated/anon.
CREATE OR REPLACE FUNCTION public.fn_emit_notification(p_user uuid, p_kind text, p_title text, p_body text DEFAULT NULL, p_link text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid;
BEGIN
  IF p_user IS NULL OR coalesce(btrim(p_title),'')='' THEN RETURN NULL; END IF;
  INSERT INTO public.pulse_notifications(user_id, kind, title, body, link)
  VALUES (p_user, coalesce(nullif(btrim(p_kind),''),'INFO'), p_title, p_body, p_link)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_emit_notification(uuid,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_emit_notification(uuid,text,text,text,text) TO service_role;

COMMENT ON TABLE public.pulse_notifications IS 'Phase 03.09 tenant-safe notifications. RLS owner-only read; writes via service_role fn_emit_notification; reads/marks via auth.uid() SECURITY DEFINER wrappers.';
