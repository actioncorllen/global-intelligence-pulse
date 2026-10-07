-- mig_371b — Automatic research dispatch for eligible newly-discovered candidates
--
-- DURABLE CONTRACT: a newly discovered candidate that passed the existing
-- discovery qualification gate (hence is registered for its market in
-- monday_opportunity_registry) is automatically dispatched ONCE into the existing
-- research lifecycle, in a service context, without founder/Claude invoking
-- research per candidate.
--
-- BOUNDED / NOISE-SAFE: only candidates registered for the market enter research
-- (discovery noise that failed qualification is never registered and so is never
-- dispatched). Idempotency is inherited from the shared core (CACHE_REUSED /
-- CACHE_REUSED_IN_FLIGHT), so retries never create duplicate runs. Spend is
-- additionally governed by the existing controls honored inside fn_research_dispatch
-- (server_integration_config.research_executor_webhook and the
-- pulse.suppress_dispatch GUC); when suppression is on, no run is created and no
-- provider is fired.

CREATE OR REPLACE FUNCTION public.fn_auto_dispatch_candidate_research(
    p_user_id uuid, p_product_id uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_prod public.commerce_products%rowtype;
  v_registered boolean;
BEGIN
  IF p_user_id IS NULL OR p_product_id IS NULL OR v_mkt='' THEN
    RETURN jsonb_build_object('status','MISSING_ARGS');
  END IF;

  -- Existing cost control, reused: global dispatch suppression also halts
  -- auto-research (no run, no provider fire).
  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on' THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','product_id',p_product_id,'market',v_mkt,
      'note','pulse.suppress_dispatch=on; auto-research not started');
  END IF;

  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> p_user_id THEN RETURN jsonb_build_object('status','NOT_AUTHORIZED'); END IF;

  -- ELIGIBILITY GATE (reuses discovery qualification): only a candidate that was
  -- promoted + registered for this market enters expensive deep research. A
  -- keyword that failed fn_dataforseo_discovery_qualify is never registered here,
  -- so it is never researched.
  SELECT EXISTS(
    SELECT 1 FROM public.monday_opportunity_registry r
    WHERE r.tenant_id = p_user_id AND r.product_id = p_product_id AND r.active
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(r.markets) m WHERE upper(m->>'country') = v_mkt)
  ) INTO v_registered;
  IF NOT v_registered THEN
    RETURN jsonb_build_object('status','NOT_ELIGIBLE','product_id',p_product_id,'market',v_mkt,
      'reason','candidate_not_registered_for_market',
      'note','only discovery-qualified, registered candidates enter deep research');
  END IF;

  RETURN public.fn_research_request_core(p_user_id, p_product_id, v_mkt, 168, 'auto_fresh_discovery');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_auto_dispatch_candidate_research(uuid,uuid,text) TO service_role;
