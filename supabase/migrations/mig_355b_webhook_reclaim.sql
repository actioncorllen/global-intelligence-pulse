-- mig_355b: webhook event claims that FAILED processing are reclaimable.
-- Without this, a transient processing failure after the dedupe claim would make every
-- Stripe retry read as duplicate and the event would never take effect. A claim whose
-- outcome starts 'error:' is re-openable (received_at refreshed, outcome cleared,
-- duplicate=false). Successful/ignored outcomes stay permanently deduplicated.
-- Safe: the downstream effects (card upsert, wallet purchase) are themselves idempotent.
CREATE OR REPLACE FUNCTION public.fn_psp_webhook_begin(p_event_id text, p_event_type text, p_livemode boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_id text := nullif(btrim(coalesce(p_event_id,'')),''); v_inserted boolean; v_reclaimed boolean := false;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('status','error','reason','BAD_EVENT_ID'); END IF;
  INSERT INTO public.psp_webhook_event (id, event_type, livemode)
    VALUES (v_id, coalesce(p_event_type,'unknown'), coalesce(p_livemode,false))
    ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF NOT v_inserted THEN
    UPDATE public.psp_webhook_event
       SET received_at = now(), outcome = NULL
     WHERE id = v_id AND outcome LIKE 'error:%'
    RETURNING true INTO v_reclaimed;
    v_reclaimed := coalesce(v_reclaimed,false);
  END IF;
  RETURN jsonb_build_object('status','ok','duplicate', NOT (v_inserted OR v_reclaimed),
                            'reclaimed', v_reclaimed);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_webhook_begin(text,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_webhook_begin(text,text,boolean) TO service_role;
