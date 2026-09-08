-- PULSE-ECOM-P13-META-CONVERSION-TRACKING-001
-- Non-secret browser Pixel config resolver + conversion ledger summary.

CREATE OR REPLACE FUNCTION public.fn_meta_pixel_config(p_tenant uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_cfg   public.meta_tracking_config%ROWTYPE;
  v_track boolean;
BEGIN
  SELECT * INTO v_cfg FROM public.meta_tracking_config WHERE tenant_id = p_tenant;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('configured', false, 'reason', 'NO_TRACKING_CONFIG');
  END IF;
  SELECT behavioral_tracking INTO v_track FROM public.user_consent WHERE user_id = p_tenant;
  RETURN jsonb_build_object(
    'configured', true,
    'pixel_id', v_cfg.dataset_id,          -- unified dataset: same id for Pixel + CAPI
    'dataset_id', v_cfg.dataset_id,
    'graph_version', 'v26.0',
    'tenant_behavioral_tracking', COALESCE(v_track, false),
    'load_pixel_allowed', COALESCE(v_track, false),
    'supported_events', jsonb_build_array(
      'PageView','ViewContent','Search','AddToCart','InitiateCheckout','AddPaymentInfo','Purchase'),
    'event_id_contract', 'pulse_<uuid>; identical value used for browser Pixel eventID and server CAPI event_id',
    'server_emit_endpoint', 'edge:meta-capi-adapter?mode=emit',
    'notes', 'No access token is ever exposed to the browser. Purchase must originate from a verified order source.'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_meta_pixel_config(uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_conversion_ledger_summary(p_tenant uuid, p_provider text DEFAULT 'META')
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object(
    'tenant_id', p_tenant, 'provider', p_provider,
    'by_state', COALESCE((SELECT jsonb_object_agg(state, c)
      FROM (SELECT state, count(*) c FROM public.conversion_dispatch_ledger
            WHERE tenant_id = p_tenant AND provider = p_provider GROUP BY state) s), '{}'::jsonb),
    'accepted', (SELECT count(*) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED'),
    'accepted_non_test', (SELECT count(*) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED' AND is_test = false),
    'last_accepted_at', (SELECT max(last_attempt_at) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED')
  );
$$;
REVOKE ALL ON FUNCTION public.fn_conversion_ledger_summary(uuid, text) FROM PUBLIC, anon;
