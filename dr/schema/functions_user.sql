-- STRATELOQ DR: production public USER functions only (252; extension-owned pgvector C
-- functions excluded — those are provided by CREATE EXTENSION vector). NO secrets.
-- ORDER 3: user functions/procedures

CREATE OR REPLACE FUNCTION public.accept_invitation(p_token_hash text, p_auth_user_id uuid, p_email_verified boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_inv             public.invitation%ROWTYPE;
    v_auth_email      text;
    v_auth_confirmed  timestamptz;
    v_canon_auth      text;
    v_bound_email     text;
    v_member_by_auth       public.member%ROWTYPE;
    v_member_by_email_id   uuid;
    v_member_by_email_auth uuid;
    v_has_auth             boolean := false;
    v_has_email            boolean := false;
    v_member_id            uuid;
    v_ds_count             integer;
    v_email_count          integer;
BEGIN
    IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN jsonb_build_object('status', 'invalid_invitation', 'reason', 'not_found');
    END IF;
    SELECT * INTO v_inv FROM public.invitation WHERE token_hash = p_token_hash FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_invitation', 'reason', 'not_found');
    END IF;
    IF v_inv.superseded_by IS NOT NULL AND v_inv.status <> 'revoked' THEN
        RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'successor_revocation_conflict');
    END IF;
    -- application_ref may be NULL (open direct beta invite) or non-null (applicant).
    IF v_inv.status = 'revoked' THEN
        RETURN jsonb_build_object('status', 'invalid_invitation', 'reason', 'revoked');
    END IF;
    IF v_inv.status = 'expired' OR (v_inv.status = 'issued' AND v_inv.expires_at <= now()) THEN
        RETURN jsonb_build_object('status', 'invalid_invitation', 'reason', 'expired');
    END IF;
    SELECT u.email, u.email_confirmed_at INTO v_auth_email, v_auth_confirmed
    FROM auth.users u WHERE u.id = p_auth_user_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'authentication_failed'); END IF;
    v_canon_auth := lower(btrim(coalesce(v_auth_email, '')));
    IF v_canon_auth = '' THEN RETURN jsonb_build_object('status', 'authentication_failed'); END IF;
    IF (v_auth_confirmed IS NOT NULL) <> coalesce(p_email_verified, false) THEN
        RAISE EXCEPTION 'acceptance trusted-fact inconsistency' USING ERRCODE = 'P0001';
    END IF;
    IF v_auth_confirmed IS NULL THEN RETURN jsonb_build_object('status', 'authentication_failed'); END IF;
    v_bound_email := lower(btrim(coalesce(v_inv.bound_email, '')));
    IF v_bound_email = '' OR v_canon_auth <> v_bound_email THEN
        RETURN jsonb_build_object('status', 'authentication_failed');
    END IF;
    SELECT * INTO v_member_by_auth FROM public.member WHERE auth_user_id = p_auth_user_id;
    v_has_auth := FOUND;
    SELECT count(*), min(m.id::text)::uuid, min(m.auth_user_id::text)::uuid
      INTO v_email_count, v_member_by_email_id, v_member_by_email_auth
    FROM public.member AS m WHERE lower(btrim(m.email)) = v_canon_auth;
    IF v_email_count > 1 THEN RAISE EXCEPTION 'acceptance cardinality violation' USING ERRCODE = 'P0001'; END IF;
    v_has_email := (v_email_count = 1);
    IF v_has_auth AND lower(btrim(v_member_by_auth.email)) <> v_canon_auth THEN
        RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'bound_email_mismatch');
    END IF;
    IF v_has_auth THEN v_member_id := v_member_by_auth.id; END IF;
    IF v_has_auth AND v_inv.application_ref IS NOT NULL
       AND v_member_by_auth.application_ref IS DISTINCT FROM v_inv.application_ref THEN
        RAISE EXCEPTION 'acceptance application binding mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_inv.status = 'consumed' THEN
        IF v_has_auth THEN
            SELECT count(*) INTO v_ds_count FROM public.discovery_state WHERE member_id = v_member_id;
            IF v_ds_count = 1 THEN
                RETURN jsonb_build_object('status', 'accepted', 'provisioning', 'already_provisioned');
            ELSIF v_ds_count = 0 THEN
                RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'missing_discovery_state');
            ELSE RAISE EXCEPTION 'acceptance cardinality violation' USING ERRCODE = 'P0001'; END IF;
        ELSIF v_has_email THEN
            RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'auth_user_mismatch');
        ELSE RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'missing_member'); END IF;
    END IF;
    IF v_inv.status <> 'issued' THEN RAISE EXCEPTION 'acceptance unexpected lifecycle state' USING ERRCODE = 'P0001'; END IF;
    IF v_has_email AND v_member_by_email_auth <> p_auth_user_id THEN
        RETURN jsonb_build_object('status', 'integrity_conflict', 'reason', 'conflicting_member');
    END IF;
    IF NOT v_has_auth THEN
        INSERT INTO public.member
            (auth_user_id, email, display_name, business_name, email_verified, account_status, welcome_seen, application_ref)
        VALUES (p_auth_user_id, v_canon_auth, NULL, NULL, true, 'active', false, v_inv.application_ref)
        RETURNING id INTO v_member_id;
    END IF;
    SELECT count(*) INTO v_ds_count FROM public.discovery_state WHERE member_id = v_member_id;
    IF v_ds_count = 0 THEN
        INSERT INTO public.discovery_state (member_id, status) VALUES (v_member_id, 'not_started');
    ELSIF v_ds_count > 1 THEN RAISE EXCEPTION 'acceptance cardinality violation' USING ERRCODE = 'P0001'; END IF;
    UPDATE public.invitation SET status = 'consumed', consumed_at = now() WHERE id = v_inv.id;
    RETURN jsonb_build_object('status', 'accepted', 'provisioning', 'provisioned');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.acquire_commerce_candidates_from_trends(p_run_id uuid, p_limit integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid; v_niche text; v_industry text; v_ci jsonb;
  v_terms text[] := ARRAY[]::text[];
  c record; v_pid uuid; v_strength text; v_att text; v_dir text;
  v_matched int := 0; v_acq int := 0; v_rejected int := 0;
  v_gate jsonb;
BEGIN
  IF p_run_id IS NULL THEN RETURN jsonb_build_object('status','missing_run'); END IF;
  SELECT user_id, commerce_inputs INTO v_user, v_ci FROM public.discovery_runs WHERE id=p_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  SELECT dna_extended->'commerce'->>'niche' INTO v_niche
    FROM public.member_business_dna WHERE user_id=v_user AND source_run_id=p_run_id;
  SELECT industry INTO v_industry FROM public.business_profiles WHERE user_id=v_user LIMIT 1;

  IF v_ci IS NOT NULL AND jsonb_typeof(v_ci->'interests')='array' THEN
    SELECT array_agg(lower(btrim(x))) INTO v_terms
    FROM jsonb_array_elements_text(v_ci->'interests') x WHERE nullif(btrim(x),'') IS NOT NULL;
  END IF;
  IF v_ci ? 'niche' AND nullif(btrim(coalesce(v_ci->>'niche','')),'') IS NOT NULL THEN
    v_terms := v_terms || lower(btrim(v_ci->>'niche'));
  END IF;
  IF nullif(btrim(coalesce(v_niche,'')),'') IS NOT NULL THEN v_terms := v_terms || lower(btrim(v_niche)); END IF;
  IF nullif(btrim(coalesce(v_industry,'')),'') IS NOT NULL THEN v_terms := v_terms || lower(btrim(v_industry)); END IF;
  v_terms := (SELECT array_agg(DISTINCT e) FROM unnest(v_terms) e WHERE length(e) >= 3);

  IF v_terms IS NULL OR array_length(v_terms,1) IS NULL THEN
    RETURN jsonb_build_object('status','no_interests','acquired',0);
  END IF;

  FOR c IN
    SELECT tc.canonical_topic, tc.related_terms, tc.growth_pct, tc.source_count, tc.signals_count,
           tc.is_emerging, tc.top_regions, tc.why_trending, tc.created_at
    FROM public.trend_clusters tc
    WHERE EXISTS (
      SELECT 1 FROM unnest(v_terms) term
      WHERE tc.canonical_topic ILIKE '%'||term||'%'
         OR (jsonb_typeof(tc.related_terms)='array'
             AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(tc.related_terms) rt WHERE rt ILIKE '%'||term||'%'))
    )
    ORDER BY tc.source_count DESC NULLS LAST, tc.growth_pct DESC NULLS LAST, tc.created_at DESC NULLS LAST
    LIMIT greatest(1, least(p_limit, 25))
  LOOP
    v_matched := v_matched + 1;

    -- GUARD: only concrete sellable products may enter the commerce pipeline.
    -- Abstract macro-topics (the SM-004 defect) are filtered here.
    v_gate := public.fn_is_sellable_product_entity(c.canonical_topic);
    IF (v_gate->>'verdict') <> 'ACCEPT' THEN
      v_rejected := v_rejected + 1;
      CONTINUE;
    END IF;

    v_strength := CASE
      WHEN coalesce(c.source_count,0) >= 5 AND coalesce(c.growth_pct,0) >= 300 THEN 'STRONG'
      WHEN coalesce(c.source_count,0) >= 3 OR coalesce(c.growth_pct,0) >= 150 THEN 'MODERATE'
      ELSE 'LOW' END;
    v_att := v_strength;
    v_dir := CASE WHEN coalesce(c.is_emerging,false) THEN 'rising' ELSE 'flat' END;

    v_pid := (public.ingest_commerce_product(v_user, p_run_id,
      jsonb_build_object(
        'title', c.canonical_topic,
        'product_type', coalesce(v_niche, v_industry, v_terms[1]),
        'source_store', 'global_trend_collector',
        'provenance', 'INFERRED',
        'candidate_acquisition_method', 'trend_cluster',
        'product_family_key', v_gate->>'product_family_key',
        'source_family', 'multi_source_trends'),
      'INFERRED','candidate'))->>'product_id';
    IF v_pid IS NULL THEN CONTINUE; END IF;

    INSERT INTO public.commerce_signals
      (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
    VALUES (v_user, v_pid, p_run_id, 'market_attention_observed',
      jsonb_build_object('strength', v_att, 'source_platform', 'multi_source_trends',
        'source_count', c.source_count, 'signals_count', c.signals_count,
        'growth_pct', c.growth_pct, 'top_regions', c.top_regions),
      jsonb_build_array(jsonb_build_object(
        'claim', 'Observed trending across '||coalesce(c.source_count,0)||' sources ('||coalesce(c.signals_count,0)||' signals'||
                 CASE WHEN c.growth_pct IS NOT NULL THEN ', growth '||c.growth_pct||'%' ELSE '' END||')',
        'source_name', 'global_trend_collector', 'signal_type', 'trend_cluster', 'provenance', 'OBSERVED')),
      jsonb_build_object('signal','OBSERVED'), now(),
      'run:'||p_run_id::text||':'||v_pid::text||':market_attention_observed')
    ON CONFLICT (user_id, dedup_key) DO UPDATE SET
      product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence,
      provenance=excluded.provenance, observed_at=excluded.observed_at;

    INSERT INTO public.commerce_signals
      (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
    VALUES (v_user, v_pid, p_run_id, 'demand_evidence',
      jsonb_build_object('strength', v_strength, 'direction', v_dir, 'source_platform', 'global_trends',
        'has_summary', (c.why_trending IS NOT NULL)),
      jsonb_build_array(jsonb_build_object(
        'claim', 'Demand inferred from observed trend attention for "'||c.canonical_topic||'"',
        'source_name', 'global_trend_collector', 'signal_type', 'trend_cluster', 'provenance', 'RESEARCHED')),
      jsonb_build_object('signal','RESEARCHED'), now(),
      'run:'||p_run_id::text||':'||v_pid::text||':demand_evidence')
    ON CONFLICT (user_id, dedup_key) DO UPDATE SET
      product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence,
      provenance=excluded.provenance, observed_at=excluded.observed_at;

    v_acq := v_acq + 1;
  END LOOP;

  RETURN jsonb_build_object('status','ok','interests', to_jsonb(v_terms),
    'matched', v_matched, 'rejected_non_product', v_rejected, 'acquired', v_acq);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_marketing_campaign_draft(p_draft_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    d public.marketing_campaign_drafts%ROWTYPE;
    v_meta jsonb; v_now timestamptz; v_life jsonb; v_exec_id uuid;
    v_exec_ccy text; v_disp_ccy text; v_daily_minor numeric; v_disp_amt numeric; v_exec_amt numeric;
    v_fx jsonb; v_snapshot jsonb; v_max_test numeric; v_fp text; v_spendcap numeric;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    IF p_draft_id IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    SELECT * INTO d FROM public.marketing_campaign_drafts WHERE id = p_draft_id;
    IF NOT FOUND OR d.user_id IS DISTINCT FROM v_uid THEN RETURN jsonb_build_object('status','not_found'); END IF;

    SELECT e.id INTO v_exec_id FROM public.marketing_campaign_executions e
    WHERE e.draft_id = p_draft_id AND e.platform='meta' AND e.status='CREATED_PAUSED' LIMIT 1;
    IF v_exec_id IS NOT NULL THEN
        RETURN jsonb_build_object('status','already_executed','draft_id',p_draft_id,'execution_id',v_exec_id); END IF;

    IF d.status='APPROVED' AND coalesce(d.lifecycle->>'publishable','')='true'
       AND coalesce(d.lifecycle->'approval'->>'explicit_publish_approval','')='true' THEN
        RETURN jsonb_build_object('status','approved','draft_id',p_draft_id,'draft_status','APPROVED',
                                  'approved_at',d.lifecycle->'approval'->>'approved_at','idempotent',true); END IF;

    IF d.status='ARCHIVED' THEN RETURN jsonb_build_object('status','invalid_transition','draft_status',d.status); END IF;

    v_meta := d.platform_payloads->'meta';
    IF v_meta IS NULL OR jsonb_typeof(v_meta)<>'object'
       OR jsonb_typeof(v_meta->'campaigns')<>'array' OR jsonb_array_length(v_meta->'campaigns')=0 THEN
        RETURN jsonb_build_object('status','missing_meta_payload','draft_id',p_draft_id); END IF;

    SELECT currency INTO v_exec_ccy FROM public.meta_platform_config WHERE id=1;
    v_exec_ccy := upper(coalesce(v_exec_ccy,''));
    v_disp_ccy := upper(coalesce(nullif(v_meta->>'currency',''), nullif(d.canonical_campaign->>'currency',''), ''));
    -- Exact DAILY amount that will be submitted to Meta (minor units -> major).
    v_daily_minor := nullif(v_meta->'campaigns'->0->'ad_sets'->0->>'daily_budget','')::numeric;

    IF v_exec_ccy='' THEN RETURN jsonb_build_object('status','no_platform_config'); END IF;
    IF v_disp_ccy='' THEN RETURN jsonb_build_object('status','missing_campaign_currency'); END IF;
    IF v_daily_minor IS NULL OR v_daily_minor <= 0 THEN
        RETURN jsonb_build_object('status','missing_execution_budget','draft_id',p_draft_id,
          'detail','Meta ad set has no explicit daily_budget; set a concrete budget before approval.'); END IF;

    v_disp_amt := round(v_daily_minor/100.0, 2);
    v_spendcap := nullif(v_meta->'campaigns'->0->>'spend_cap','')::numeric;
    v_max_test := coalesce(
        nullif(d.review_payload->'authorization_states'->>'maximum_test_spend_usd','')::numeric,
        (v_spendcap/100.0));

    IF v_disp_ccy = v_exec_ccy THEN
        v_exec_amt := v_disp_amt;
        v_snapshot := jsonb_build_object('conversion_status','same_currency','fx_rate',1,'fx_rate_source','identity','fx_rate_timestamp',NULL);
    ELSE
        v_fx := public.get_fx_rate(v_disp_ccy, v_exec_ccy);
        IF NOT (v_fx->>'available')::boolean OR (v_fx->>'stale')::boolean THEN
            RETURN jsonb_build_object('status','fx_unavailable_for_budget','display_currency',v_disp_ccy,'execution_currency',v_exec_ccy); END IF;
        v_exec_amt := round(v_disp_amt * (v_fx->>'rate')::numeric, 2);
        v_snapshot := jsonb_build_object('conversion_status','converted','fx_rate',(v_fx->>'rate')::numeric,
                       'fx_rate_source',v_fx->>'source','fx_rate_timestamp',v_fx->>'fetched_at');
    END IF;

    v_snapshot := v_snapshot || jsonb_build_object(
        'period','daily',
        'display_currency',v_disp_ccy,'display_daily_amount',v_disp_amt,
        'execution_currency',v_exec_ccy,'execution_daily_amount',v_exec_amt,
        'spend_cap', CASE WHEN v_spendcap IS NOT NULL THEN
             jsonb_build_object('amount',round(v_spendcap/100.0,2),'minor',v_spendcap,'currency',v_exec_ccy,'scope','campaign_lifetime')
           ELSE NULL END,
        'maximum_test_spend_usd', v_max_test,
        'authorized_spend_usd', 0,
        'captured_at', to_jsonb(now()));

    v_fp := public.fn_meta_execution_fingerprint(p_draft_id);
    v_now := now();

    v_life := coalesce(d.lifecycle,'{}'::jsonb)
      || jsonb_build_object('status','APPROVED','publishable',true)
      || jsonb_build_object('approval',
           coalesce(d.lifecycle->'approval','{}'::jsonb) || jsonb_build_object(
             'explicit_publish_approval',true,'approved_at',to_jsonb(v_now),'approved_by',to_jsonb(v_uid),
             'budget_snapshot',v_snapshot,'execution_fingerprint',v_fp))
      || jsonb_build_object('authorizations', jsonb_build_object(
             'campaign_approval',true,
             'draft_creation_authorization',true,
             'activation_authorization',false,
             'spend_authorization_usd',0,
             'maximum_test_spend_usd',v_max_test));
    v_life := jsonb_set(v_life,'{history}',
        coalesce(v_life->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          'stage','APPROVED','at',to_jsonb(v_now),'by',to_jsonb(v_uid),
          'execution_daily_amount',v_exec_amt,'execution_currency',v_exec_ccy)));

    UPDATE public.marketing_campaign_drafts SET status='APPROVED', lifecycle=v_life, updated_at=v_now
     WHERE id=p_draft_id AND user_id=v_uid AND status<>'ARCHIVED';
    IF NOT FOUND THEN RETURN jsonb_build_object('status','invalid_transition'); END IF;

    RETURN jsonb_build_object('status','approved','draft_id',p_draft_id,'draft_status','APPROVED',
        'approved_at',to_jsonb(v_now),'budget_snapshot',v_snapshot,
        'authorizations', v_life->'authorizations');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_product_acquisition(p_acquisition_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_row public.product_acquisitions%ROWTYPE;
    v_at  timestamptz;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    IF p_acquisition_id IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    SELECT * INTO v_row FROM public.product_acquisitions WHERE id = p_acquisition_id;
    IF NOT FOUND OR v_row.user_id <> v_uid THEN
        RETURN jsonb_build_object('status','not_found'); END IF;

    IF v_row.state = 'APPROVED' THEN
        RETURN jsonb_build_object('status','approved','acquisition_id', p_acquisition_id,
                                  'state','APPROVED','approved_at', v_row.approved_at); END IF;

    IF v_row.state <> 'READY_FOR_REVIEW' THEN
        RETURN jsonb_build_object('status','invalid_transition','state', v_row.state); END IF;

    IF v_row.prepared_package IS NULL THEN
        RETURN jsonb_build_object('status','invalid_transition','state', v_row.state); END IF;

    UPDATE public.product_acquisitions
       SET state = 'APPROVED',
           state_reason = NULL,
           approved_at = now()
     WHERE id = p_acquisition_id AND user_id = v_uid AND state = 'READY_FOR_REVIEW'
    RETURNING approved_at INTO v_at;

    IF v_at IS NULL THEN
        RETURN jsonb_build_object('status','invalid_transition'); END IF;

    RETURN jsonb_build_object('status','approved','acquisition_id', p_acquisition_id,
                              'state','APPROVED','approved_at', v_at);
END; $function$
;

CREATE OR REPLACE FUNCTION public.begin_product_preparation(p_acquisition_id uuid, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_state text;
  v_run   uuid;
begin
  if p_acquisition_id is null or p_user_id is null then
    return jsonb_build_object('status', 'invalid');
  end if;

  select state, source_run_id
    into v_state, v_run
    from public.product_acquisitions
   where id = p_acquisition_id
     and user_id = p_user_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_state = 'PREPARING' then
    return jsonb_build_object('status', 'already_preparing', 'source_run_id', v_run);
  elsif v_state = 'READY_FOR_REVIEW' then
    return jsonb_build_object('status', 'already_ready', 'source_run_id', v_run);
  elsif v_state not in ('SELECTED', 'PREPARE_FAILED') then
    return jsonb_build_object('status', 'not_eligible', 'state', v_state);
  end if;

  update public.product_acquisitions
     set state = 'PREPARING',
         state_reason = null,
         updated_at = now()
   where id = p_acquisition_id
     and user_id = p_user_id
     and state in ('SELECTED', 'PREPARE_FAILED');

  if not found then
    return jsonb_build_object('status', 'not_eligible');
  end if;

  return jsonb_build_object('status', 'preparing', 'source_run_id', v_run);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_next_content_job()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_row public.member_generated_content%ROWTYPE;
BEGIN
    -- Claim the oldest job that is queued, or in-flight but abandoned by a dead
    -- worker (>15 min in 'processing'). SKIP LOCKED => two workers or two loop
    -- iterations never take the same row.
    SELECT * INTO v_row
      FROM public.member_generated_content
     WHERE status = 'queued'
        OR (status = 'processing' AND updated_at < now() - interval '15 minutes')
     ORDER BY created_at ASC
       FOR UPDATE SKIP LOCKED
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN '{}'::jsonb;  -- empty object => worker's IF guard ends the drain
    END IF;

    UPDATE public.member_generated_content
       SET status = 'processing', updated_at = now()
     WHERE id = v_row.id;

    RETURN jsonb_build_object(
        'id',                    v_row.id,
        'user_id',               v_row.user_id,
        'member_opportunity_id', v_row.member_opportunity_id,
        'source_run_id',         v_row.source_run_id,
        'rank',                  v_row.rank,
        'content_type',          v_row.content_type,
        'platform',              v_row.platform,
        'request',               v_row.request
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_product_acquisition(p_product_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid      uuid := auth.uid();
    v_ref      text;
    v_run      uuid;
    v_commerce jsonb;
    v_wpi      jsonb;
    v_cand     jsonb;
    v_srco     jsonb;
    v_spec     jsonb;
    v_state    text;
    v_existing uuid;
    v_id       uuid;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    v_ref := nullif(btrim(coalesce(p_product_ref,'')),'');
    IF v_ref IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;

    SELECT source_run_id, dna_extended->'commerce' INTO v_run, v_commerce
    FROM public.member_business_dna WHERE user_id = v_uid;
    IF v_run IS NULL OR v_commerce IS NULL
       OR (v_commerce->>'is_ecommerce') IS DISTINCT FROM 'true' THEN
        RETURN jsonb_build_object('status','not_ecommerce'); END IF;

    v_wpi := v_commerce->'winning_product_intelligence';
    IF v_wpi IS NULL OR (v_wpi->>'status') IS DISTINCT FROM 'available' THEN
        RETURN jsonb_build_object('status','no_winning_intelligence'); END IF;

    SELECT c INTO v_cand
    FROM jsonb_array_elements(coalesce(v_wpi->'candidates','[]'::jsonb)) c
    WHERE c->>'product_url' = v_ref OR c->>'product_title' = v_ref
    LIMIT 1;
    IF v_cand IS NULL THEN RETURN jsonb_build_object('status','candidate_not_found'); END IF;

    SELECT o INTO v_srco
    FROM jsonb_array_elements(
        coalesce(v_commerce->'supplier_sourcing_intelligence'->'sourcing_opportunities','[]'::jsonb)) o
    WHERE o->>'source_winning_product' = (v_cand->>'product_title')
    LIMIT 1;
    v_spec  := coalesce(v_srco, jsonb_build_object('supplier_options', '[]'::jsonb));
    v_state := CASE WHEN jsonb_array_length(coalesce(v_srco->'supplier_options','[]'::jsonb)) > 0
                    THEN 'SOURCED' ELSE 'DISCOVERED' END;

    -- Idempotency: return the existing active acquisition for this product+run.
    SELECT id INTO v_existing FROM public.product_acquisitions
    WHERE user_id = v_uid AND source_run_id = v_run AND state <> 'DISCARDED'
      AND coalesce(winning_product_snapshot->>'product_url', winning_product_snapshot->>'product_title')
        = coalesce(v_cand->>'product_url', v_cand->>'product_title')
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object('status','exists','acquisition_id', v_existing); END IF;

    INSERT INTO public.product_acquisitions
        (user_id, source_run_id, state, winning_product_snapshot, sourcing_spec_snapshot)
    VALUES (v_uid, v_run, v_state, v_cand, v_spec)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('status','created','acquisition_id', v_id, 'state', v_state);
END; $function$
;

CREATE OR REPLACE FUNCTION public.derive_commerce_competition(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user uuid; c record; v_count int; v_sources int; v_level text; v_n int := 0;
BEGIN
  SELECT user_id INTO v_user FROM public.discovery_runs WHERE id=p_source_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  FOR c IN
    SELECT DISTINCT lower(btrim(category)) AS cat FROM public.commerce_products
    WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_role='own' AND nullif(btrim(category),'') IS NOT NULL
  LOOP
    SELECT count(*), count(DISTINCT lower(btrim(coalesce(competitor_source,source_store,''))))
      INTO v_count, v_sources
      FROM public.commerce_products
      WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_role='competitor'
        AND lower(btrim(coalesce(category,''))) = c.cat;

    v_level := CASE WHEN v_count=0 THEN 'LOW_EVIDENCE' WHEN v_count<=2 THEN 'LOW' WHEN v_count<=5 THEN 'MODERATE' ELSE 'HIGH' END;

    INSERT INTO public.commerce_signals
      (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
    VALUES (v_user, NULL, p_source_run_id, 'competition_density',
      jsonb_build_object('category', c.cat, 'level', v_level, 'competitor_count', v_count, 'competitor_sources', v_sources),
      jsonb_build_array(jsonb_build_object('claim','Proxy: '||v_count||' competitor products observed in category',
        'signal_type','competition','provenance','INFERRED')),
      jsonb_build_object('signal','INFERRED'),  -- explicitly a proxy, never OBSERVED fact
      now(), 'run:'||p_source_run_id::text||':competition_density:'||c.cat)
    ON CONFLICT (user_id, dedup_key) DO UPDATE SET value=excluded.value, evidence=excluded.evidence, observed_at=excluded.observed_at;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('status','ok','categories', v_n);
END; $function$
;

CREATE OR REPLACE FUNCTION public.derive_commerce_gaps(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user uuid; p record; v_demand text; v_comp text; v_n int := 0;
BEGIN
  SELECT user_id INTO v_user FROM public.discovery_runs WHERE id=p_source_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  FOR p IN SELECT * FROM public.commerce_products WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_role='own' LOOP
    SELECT value->>'strength' INTO v_demand FROM public.commerce_signals
      WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_id=p.id AND signal_type='demand_evidence' LIMIT 1;
    SELECT value->>'level' INTO v_comp FROM public.commerce_signals
      WHERE user_id=v_user AND source_run_id=p_source_run_id AND signal_type='competition_density' AND lower(value->>'category')=lower(coalesce(p.category,'')) LIMIT 1;

    -- conservative: gap only when demand is at least MODERATE AND observed competition is LOW (evidence-backed)
    IF v_demand IN ('MODERATE','STRONG') AND v_comp = 'LOW' THEN
      INSERT INTO public.commerce_signals (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
      VALUES (v_user, p.id, p_source_run_id, 'differentiation_gap',
        jsonb_build_object('gap_type','demand_with_low_competition','subject', p.category, 'demand', v_demand, 'competition', v_comp),
        jsonb_build_array(jsonb_build_object('claim','Demand ('||v_demand||') co-occurs with low observed competition','signal_type','gap','provenance','INFERRED')),
        jsonb_build_object('signal','INFERRED'), now(), 'run:'||p_source_run_id::text||':'||p.product_identity||':differentiation_gap')
      ON CONFLICT (user_id, dedup_key) DO UPDATE SET value=excluded.value, evidence=excluded.evidence, observed_at=excluded.observed_at;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('status','ok','gap_signals', v_n);
END; $function$
;

CREATE OR REPLACE FUNCTION public.derive_commerce_momentum(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user uuid; p record; v_prices numeric[]; v_avail text[]; v_last timestamptz; v_type text; v_n int := 0; v_from numeric; v_to numeric;
BEGIN
  SELECT user_id INTO v_user FROM public.discovery_runs WHERE id=p_source_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  FOR p IN SELECT * FROM public.commerce_products WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_role='own' LOOP
    -- gather cross-run price history for this product identity (temporal evidence)
    SELECT array_agg((s.value->>'price')::numeric ORDER BY s.observed_at), max(s.observed_at)
      INTO v_prices, v_last
      FROM public.commerce_signals s JOIN public.commerce_products cp ON cp.id=s.product_id
      WHERE cp.user_id=v_user AND cp.product_identity=p.product_identity
        AND s.signal_type='price_observed' AND (s.value ? 'price') AND (s.value->>'price') ~ '^[0-9]+(\.[0-9]+)?$';

    IF v_prices IS NOT NULL AND array_length(v_prices,1) >= 2 THEN
      v_from := v_prices[array_length(v_prices,1)-1]; v_to := v_prices[array_length(v_prices,1)];
      IF v_to < v_from THEN v_type := 'price_down'; ELSIF v_to > v_from THEN v_type := 'price_up'; ELSE v_type := NULL; END IF;
      IF v_type IS NOT NULL THEN
        INSERT INTO public.commerce_signals (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, source_event_at, dedup_key)
        VALUES (v_user, p.id, p_source_run_id, v_type, jsonb_build_object('from',v_from,'to',v_to),
          jsonb_build_array(jsonb_build_object('claim','Derived from '||array_length(v_prices,1)||' price observations over time','signal_type','momentum','provenance','OBSERVED')),
          jsonb_build_object('signal','OBSERVED'), now(), v_last, 'run:'||p_source_run_id::text||':'||p.product_identity||':'||v_type)
        ON CONFLICT (user_id, dedup_key) DO UPDATE SET value=excluded.value, evidence=excluded.evidence, source_event_at=excluded.source_event_at, observed_at=excluded.observed_at;
        v_n := v_n + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('status','ok','momentum_signals', v_n);
END; $function$
;

CREATE OR REPLACE FUNCTION public.discard_product_acquisition(p_acquisition_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_row public.product_acquisitions%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT * INTO v_row FROM public.product_acquisitions WHERE id = p_acquisition_id;
    IF NOT FOUND OR v_row.user_id <> v_uid THEN
        RETURN jsonb_build_object('status','not_found'); END IF;
    IF v_row.state = 'DISCARDED' THEN
        RETURN jsonb_build_object('status','discarded','acquisition_id', p_acquisition_id); END IF;
    UPDATE public.product_acquisitions
       SET state='DISCARDED',
           state_reason = left(regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]',' ','g'),500)
     WHERE id = p_acquisition_id AND user_id = v_uid;
    RETURN jsonb_build_object('status','discarded','acquisition_id', p_acquisition_id);
END; $function$
;

CREATE OR REPLACE FUNCTION public.evaluate_product_v2(p_product_id uuid, p_target_market text, p_selling_price numeric, p_display_currency text, p_fees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := coalesce(auth.uid(), public.fn_global_intelligence_uid());
  v_gid uuid := public.fn_global_intelligence_uid(); v_is_global boolean;
  v_owner uuid; v_vis text; v_built jsonb; v_dec jsonb; v_evver text; v_mkt text := upper(btrim(coalesce(p_target_market,'')));
  v_snap_id uuid; v_idem boolean := false; v_up jsonb;
BEGIN
  IF v_mkt IS NULL THEN RETURN jsonb_build_object('status','target_market_required'); END IF;
  SELECT user_id, visibility INTO v_owner, v_vis FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF NOT ((v_owner = v_gid AND v_vis = 'GLOBAL_SAFE') OR v_owner = v_uid) THEN
    RETURN jsonb_build_object('status','forbidden_reference'); END IF;
  v_is_global := (v_uid = v_gid);

  v_built := public.fn_build_evidence_profile_v2(p_product_id, v_mkt);
  IF v_built->>'status' <> 'ok' THEN RETURN v_built; END IF;
  v_evver := v_built->>'evidence_version';

  v_dec := public.fn_canonical_product_decision_v2(v_built->'profile', v_built->'product', v_built->'supplier',
    v_built->'reviews', NULL, v_built->'market_advantage', p_fees, v_built->'cx_signals', v_mkt, p_selling_price, p_display_currency);

  -- tenant evaluation (skip for GLOBAL baseline caller)
  IF NOT v_is_global THEN
    v_up := public.upsert_tenant_product_evaluation_v2(p_product_id, v_mkt, v_dec,
      nullif(v_dec->>'opportunity_score','')::int, v_dec->>'classification', v_dec->>'recommendation');
  END IF;

  -- idempotent prediction snapshot (immutable per evidence_version)
  INSERT INTO public.commerce_prediction_snapshots(user_id, product_id, target_market, evidence_version,
    opportunity_score, market_advantage_score, customer_experience_score, evidence_confidence,
    classification, recommendation, market_timing, break_even_cpa, economics_state,
    supply_confidence, product_trust_gate, cx_gate, risks, unknowns, blocked_sources, decision, provenance, visibility)
  VALUES (v_uid, p_product_id, v_mkt, v_evver,
    nullif(v_dec->>'opportunity_score','')::int, nullif(v_dec->>'market_advantage_score','')::int,
    nullif(v_dec->>'customer_experience_score','')::int, nullif(v_dec->>'evidence_confidence','')::int,
    v_dec->>'classification', v_dec->>'recommendation', v_dec->>'market_timing', nullif(v_dec->>'break_even_cpa','')::numeric,
    v_dec->'economics'->>'economics_state', v_dec->>'supply_confidence', v_dec->'product_trust'->>'gate', v_dec->>'cx_gate',
    coalesce(v_dec->'reasons_against','[]'::jsonb), coalesce(v_dec->'unknowns','[]'::jsonb), coalesce(v_dec->'blocked_sources','[]'::jsonb),
    v_dec, jsonb_build_object('engine','wps_v2','pipeline','evidence_ingestion_wiring'),
    CASE WHEN v_is_global THEN 'GLOBAL_SAFE' ELSE 'TENANT_PRIVATE' END)
  ON CONFLICT (user_id, product_id, target_market, evidence_version) DO NOTHING
  RETURNING id INTO v_snap_id;
  IF v_snap_id IS NULL THEN
    v_idem := true;
    SELECT id INTO v_snap_id FROM public.commerce_prediction_snapshots
      WHERE user_id=v_uid AND product_id=p_product_id AND target_market=v_mkt AND evidence_version=v_evver;
  END IF;

  RETURN jsonb_build_object('status','ok','target_market',v_mkt,'is_global_baseline',v_is_global,
    'evidence_version',v_evver,'snapshot_id',v_snap_id,'idempotent_hit',v_idem,'has_cj_match',v_built->'has_cj_match',
    'classification',v_dec->>'classification','recommendation',v_dec->>'recommendation',
    'opportunity_score',v_dec->>'opportunity_score','market_advantage_score',v_dec->>'market_advantage_score',
    'customer_experience_score',v_dec->>'customer_experience_score','evidence_confidence',v_dec->>'evidence_confidence',
    'supply_confidence',v_dec->>'supply_confidence','economics_state',v_dec->'economics'->>'economics_state',
    'market_timing',v_dec->>'market_timing','recommended_next_action',v_dec->>'recommended_next_action',
    'blocked_sources',v_dec->'blocked_sources','independent_evidence_categories',v_dec->>'independent_evidence_categories',
    'tenant_eval', v_up, 'decision', v_dec);
END; $function$
;

CREATE OR REPLACE FUNCTION public.finalize_commerce_from_run(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_norm jsonb; v_sig int := 0; v_n int; v_score jsonb; v_acq jsonb := NULL; v_entry text;
BEGIN
  IF p_run_id IS NULL THEN RETURN jsonb_build_object('status','missing_run'); END IF;

  SELECT entry_mode INTO v_entry FROM public.discovery_runs WHERE id=p_run_id;

  -- (0) opportunity-first acquisition for users with no store (ECOM-005C).
  IF v_entry = 'no_store_yet' THEN
    v_acq := public.acquire_commerce_candidates_from_trends(p_run_id);
  END IF;

  -- (a) products from an existing store's DNA catalogue (no-op for no_store_yet). Idempotent.
  v_norm := public.normalize_commerce_products_from_run(p_run_id);

  -- (b) deterministic base signals from observed products. Idempotent via dedup_key.
  INSERT INTO public.commerce_signals
    (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
  SELECT cp.user_id, cp.id, cp.source_run_id, 'product_discovered',
         jsonb_build_object('identity', cp.product_identity, 'title', cp.title),
         jsonb_build_array(jsonb_build_object(
           'claim','Product observed in source catalogue',
           'source_url', cp.product_url, 'source_name', cp.source_store,
           'signal_type','catalogue', 'provenance', coalesce(cp.provenance->>'product','OBSERVED'))),
         jsonb_build_object('signal', coalesce(cp.provenance->>'product','OBSERVED')),
         now(), 'run:'||cp.source_run_id::text||':'||cp.product_identity||':product_discovered'
  FROM public.commerce_products cp
  WHERE cp.source_run_id = p_run_id
  ON CONFLICT (user_id, dedup_key) DO UPDATE SET
    product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence,
    provenance=excluded.provenance, observed_at=excluded.observed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_sig := v_sig + v_n;

  INSERT INTO public.commerce_signals
    (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
  SELECT cp.user_id, cp.id, cp.source_run_id, 'price_observed',
         jsonb_build_object('price', cp.observed_price, 'currency', cp.price_currency),
         jsonb_build_array(jsonb_build_object(
           'claim', 'Price observed: '||cp.observed_price::text||coalesce(' '||cp.price_currency,''),
           'source_url', cp.product_url, 'source_name', cp.source_store,
           'signal_type','price', 'provenance', coalesce(cp.provenance->>'product','OBSERVED'))),
         jsonb_build_object('signal', coalesce(cp.provenance->>'product','OBSERVED')),
         now(), 'run:'||cp.source_run_id::text||':'||cp.product_identity||':price_observed'
  FROM public.commerce_products cp
  WHERE cp.source_run_id = p_run_id AND cp.observed_price IS NOT NULL
  ON CONFLICT (user_id, dedup_key) DO UPDATE SET
    product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence,
    provenance=excluded.provenance, observed_at=excluded.observed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_sig := v_sig + v_n;

  INSERT INTO public.commerce_signals
    (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
  SELECT cp.user_id, cp.id, cp.source_run_id, 'availability_observed',
         jsonb_build_object('availability', cp.availability),
         jsonb_build_array(jsonb_build_object(
           'claim', 'Availability observed: '||cp.availability,
           'source_url', cp.product_url, 'source_name', cp.source_store,
           'signal_type','availability', 'provenance', coalesce(cp.provenance->>'product','OBSERVED'))),
         jsonb_build_object('signal', coalesce(cp.provenance->>'product','OBSERVED')),
         now(), 'run:'||cp.source_run_id::text||':'||cp.product_identity||':availability_observed'
  FROM public.commerce_products cp
  WHERE cp.source_run_id = p_run_id AND cp.availability IS NOT NULL
  ON CONFLICT (user_id, dedup_key) DO UPDATE SET
    product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence,
    provenance=excluded.provenance, observed_at=excluded.observed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_sig := v_sig + v_n;

  -- (c) full deterministic opportunity chain + persist + rank.
  v_score := public.score_commerce_products(p_run_id);

  RETURN jsonb_build_object('status','ok','entry_mode', v_entry, 'acquisition', v_acq,
                            'products', v_norm, 'signals_upserted', v_sig, 'scoring', v_score);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn__own_tenant()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_count int; v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN NULL; END IF;
  SELECT count(*), min(m.application_ref::text)::uuid INTO v_count, v_app
  FROM public.member AS m WHERE m.auth_user_id = v_uid;
  IF v_count <> 1 THEN RETURN NULL; END IF;   -- 0 = no member, >1 = ambiguous → fail closed
  RETURN v_app;                                -- may be NULL if member has no application yet
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_days_active(p_start timestamp with time zone, p_stop timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_start IS NULL THEN jsonb_build_object('days_observed_active', NULL, 'status','unsupported',
      'note','no start date returned')
    ELSE jsonb_build_object(
      'days_observed_active', floor(extract(epoch FROM (coalesce(p_stop, now()) - p_start))/86400)::int,
      'status', CASE WHEN p_stop IS NULL THEN 'active' ELSE 'inactive' END,
      'note','longevity is advertiser commitment only — NOT sales/ROAS/profit')
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_saturation(p_active_ads integer, p_advertisers integer)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object('class', CASE
    WHEN p_active_ads IS NULL THEN 'UNKNOWN'
    WHEN p_active_ads >= 30 OR coalesce(p_advertisers,0) >= 15 THEN 'VERY_HIGH'
    WHEN p_active_ads >= 12 OR coalesce(p_advertisers,0) >= 7 THEN 'HIGH'
    WHEN p_active_ads >= 4  OR coalesce(p_advertisers,0) >= 3 THEN 'MODERATE'
    WHEN p_active_ads >= 1 THEN 'LOW'
    ELSE 'UNKNOWN' END,
    'inferred', true,
    'note','high ad volume may indicate demand, competition, or saturation — not demand alone');
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_add_offer(p_brief_id uuid, p_element text, p_value jsonb, p_tier text, p_evidence_state text DEFAULT 'UNKNOWN'::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_t uuid; v_id uuid;
BEGIN
  SELECT tenant_id INTO v_t FROM public.ad_studio_briefs WHERE id=p_brief_id;
  IF v_t IS NULL THEN RAISE EXCEPTION 'brief_not_found'; END IF;
  IF p_tier NOT IN ('RECOMMENDED_OFFER','AUTHORIZED_OFFER','EXECUTABLE_OFFER') THEN RAISE EXCEPTION 'bad_tier'; END IF;
  INSERT INTO public.ad_studio_offers(brief_id,tenant_id,element,value,tier,evidence_state,note)
  VALUES (p_brief_id,v_t,p_element,coalesce(p_value,'{}'::jsonb),p_tier,coalesce(p_evidence_state,'UNKNOWN'),p_note)
  RETURNING id INTO v_id; RETURN v_id;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_approve_angle(p_angle_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF jsonb_array_length(a.claim_violations) > 0 THEN
    RETURN jsonb_build_object('status','blocked_claim_safety','violations',a.claim_violations);
  END IF;
  UPDATE public.ad_studio_angles
    SET review_state='APPROVED', approved_fingerprint=content_fingerprint, approved_at=now(), updated_at=now()
    WHERE id=p_angle_id;
  RETURN jsonb_build_object('status','APPROVED','angle_id',p_angle_id,'approved_fingerprint',a.content_fingerprint,
    'note','CREATIVE approval only — NOT campaign activation, NOT spend authorization');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_build_brief(p_tenant uuid, p_input jsonb, p_is_fixture boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_id uuid; v_comp jsonb := '{}'::jsonb;
  fields text[] := ARRAY['product_name','product_description','problem_solved','market','market_currency',
                         'audience','buyer_intent','keyword_intelligence','competitor_intelligence',
                         'advertising_evidence','market_price','offer','destination_url'];
  f text;
BEGIN
  IF p_tenant IS NULL THEN RAISE EXCEPTION 'tenant_required'; END IF;
  FOREACH f IN ARRAY fields LOOP
    v_comp := v_comp || jsonb_build_object(f,
      CASE WHEN (p_input->f) IS NULL OR p_input->>f IS NULL OR btrim(coalesce(p_input->>f,''))=''
                OR (jsonb_typeof(p_input->f) IN ('object','array') AND (p_input->f) IN ('{}'::jsonb,'[]'::jsonb))
           THEN 'UNKNOWN' ELSE 'PRESENT' END);
  END LOOP;

  INSERT INTO public.ad_studio_briefs(
    tenant_id,business_id,product_id,opportunity_id,decision_id,evidence_refs,supplier_refs,
    market,market_currency,campaign_target_market,product_name,product_description,product_features,
    problem_solved,audience,buyer_intent,keyword_intelligence,competitor_intelligence,advertising_evidence,
    market_price,offer,product_assets,destination_url,platform_targets,evidence_completeness,is_fixture,status)
  VALUES (
    p_tenant,
    nullif(p_input->>'business_id','')::uuid, nullif(p_input->>'product_id','')::uuid,
    nullif(p_input->>'opportunity_id','')::uuid, nullif(p_input->>'decision_id','')::uuid,
    coalesce(p_input->'evidence_refs','[]'::jsonb), coalesce(p_input->'supplier_refs','[]'::jsonb),
    p_input->>'market', p_input->>'market_currency', NULL,   -- campaign_target_market stays NULL (no campaign)
    p_input->>'product_name', p_input->>'product_description', coalesce(p_input->'product_features','[]'::jsonb),
    p_input->>'problem_solved', coalesce(p_input->'audience','{}'::jsonb), coalesce(p_input->'buyer_intent','{}'::jsonb),
    coalesce(p_input->'keyword_intelligence','{}'::jsonb), coalesce(p_input->'competitor_intelligence','{}'::jsonb),
    coalesce(p_input->'advertising_evidence','{}'::jsonb), coalesce(p_input->'market_price','{}'::jsonb),
    coalesce(p_input->'offer','{}'::jsonb), coalesce(p_input->'product_assets','[]'::jsonb),
    p_input->>'destination_url', coalesce(p_input->'platform_targets','["META","TIKTOK"]'::jsonb),
    v_comp, coalesce(p_is_fixture,false), 'DRAFT')
  RETURNING id INTO v_id;
  RETURN v_id;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_campaign_handoff(p_brief_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE b public.ad_studio_briefs%rowtype; v_angles jsonb; v_offers jsonb; v_handoff jsonb; v_draft uuid; v_has_auth boolean;
BEGIN
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=p_brief_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'angle_id',a.id,'angle_name',a.angle_name,'headline',a.headline,'hook',a.hook,'primary_copy',a.primary_copy,
      'cta',a.cta,'approved_fingerprint',a.approved_fingerprint,'evidence_refs',a.evidence_refs,
      'variants',(SELECT coalesce(jsonb_agg(jsonb_build_object('platform',pv.platform,'placement',pv.placement,
                    'hook',pv.hook,'primary_copy',pv.primary_copy,'cta',pv.cta,'aspect_ratio',pv.aspect_ratio)),'[]'::jsonb)
                  FROM public.ad_studio_platform_variants pv WHERE pv.angle_id=a.id)
    )),'[]'::jsonb) INTO v_angles
  FROM public.ad_studio_angles a WHERE a.brief_id=p_brief_id AND a.review_state='APPROVED';

  IF jsonb_array_length(v_angles)=0 THEN
    RETURN jsonb_build_object('status','no_approved_creative','note','handoff requires at least one APPROVED angle');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('element',element,'value',value,'tier',tier,'evidence_state',evidence_state)),'[]'::jsonb)
    INTO v_offers FROM public.ad_studio_offers
    WHERE brief_id=p_brief_id AND tier IN ('AUTHORIZED_OFFER','EXECUTABLE_OFFER');

  v_handoff := jsonb_build_object(
    'handoff_type','CAMPAIGN_BUILDER_HANDOFF','provider','PROVIDER_INDEPENDENT',
    'tenant_id',b.tenant_id,'brief_id',b.id,
    'provenance',jsonb_build_object('opportunity_id',b.opportunity_id,'decision_id',b.decision_id,
        'product_id',b.product_id,'evidence_refs',b.evidence_refs,'supplier_refs',b.supplier_refs),
    'market',b.market,'market_currency',b.market_currency,'campaign_target_market',b.campaign_target_market,
    'audience',b.audience,'destination_url',b.destination_url,
    'tracking_identity',jsonb_build_object('utm_source','pulse','utm_campaign','brief_'||b.id),
    'approved_creatives',v_angles,'authorized_offers',v_offers,
    'creative_approval_state','APPROVED','campaign_status','PAUSED','spend_authorization',0,'activation','NOT_AUTHORIZED',
    'note','Creative approved for build only. Campaign activation and spend are separate authorities and are NOT granted here.');

  -- convenience persistence into existing draft table only for real auth tenants (FK -> auth.users)
  SELECT EXISTS(SELECT 1 FROM auth.users WHERE id=b.tenant_id) INTO v_has_auth;
  IF v_has_auth THEN
    INSERT INTO public.marketing_campaign_drafts(user_id,business_context,report,canonical_campaign,platform_payloads,creative_specs,review_payload,lifecycle,status)
    VALUES (b.tenant_id, jsonb_build_object('market',b.market,'source','ad_studio_v1','is_fixture',b.is_fixture),
      jsonb_build_object('ad_studio_brief',b.id), v_handoff, jsonb_build_object('platform_variants',v_angles),
      jsonb_build_object('static_creative_contract','ad_studio_static_creatives'),
      jsonb_build_object('creative_approval','APPROVED'),
      jsonb_build_object('creative_approval','APPROVED','campaign_status','PAUSED','spend_authorization',0,'activation','NOT_AUTHORIZED','creative_approved',true),
      'APPROVED')
    RETURNING id INTO v_draft;
  END IF;

  RETURN jsonb_build_object('status','ok','draft_id',v_draft,
    'draft_persisted', v_has_auth,
    'draft_note', CASE WHEN v_has_auth THEN 'persisted to marketing_campaign_drafts' ELSE 'fixture/non-auth tenant: handoff returned, draft not persisted (FK auth.users)' END,
    'handoff',v_handoff);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_claim_scan(p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  t text := lower(coalesce(p_text,''));
  v jsonb := '[]'::jsonb;
  pats text[][] := ARRAY[
    ARRAY['SALES_CLAIM','(\msold\M|units sold|best[ -]?seller|best[ -]?selling|top[ -]?selling|#1|\mnumber one\M)'],
    ARRAY['SOCIAL_PROOF','(\mreviews?\M|\mrated\M|\mratings?\M|[0-9][ -]?star|five[ -]?star|testimonials?|loved by|customers love)'],
    ARRAY['SCARCITY','(only [0-9]+ left|limited stock|selling fast|almost gone|while stocks last|last chance|hurry)'],
    ARRAY['DISCOUNT','([0-9]+% off|\msale\M|\mdiscount\M|save [0-9]|now only|clearance|\bwas \W?[0-9])'],
    ARRAY['FREE_SHIPPING','(free shipping|free delivery)'],
    ARRAY['DELIVERY','(next[ -]day|guaranteed delivery|delivered in [0-9]|fast shipping|[0-9]+[ -]day delivery)'],
    ARRAY['CERTIFICATION','(\mcertified\M|ce approved|\mfda\M|clinically|dermatologist)'],
    ARRAY['PERFORMANCE_MEDICAL','(\mcures?\M|\mtreats?\M|\mheals?\M|clinically proven|guaranteed results|proven to|guarantee[ds]?)'],
    ARRAY['METRICS','(\mroas\M|conversion rate|[0-9]+x return)'],
    ARRAY['WINNER','(winning product|\mwinner\M|viral product)']
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(pats,1) LOOP
    IF t ~ pats[i][2] THEN
      v := v || jsonb_build_object('category',pats[i][1],'pattern',pats[i][2],
             'matched', (regexp_match(t, pats[i][2]))[1]);
    END IF;
  END LOOP;
  RETURN v;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_edit_angle(p_angle_id uuid, p_tenant uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; v_content jsonb; v_fp text; v_scan jsonb; v_invalidated boolean := false; b public.ad_studio_briefs%rowtype;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;

  UPDATE public.ad_studio_angles SET
    hook=coalesce(p_patch->>'hook',hook),
    headline=coalesce(p_patch->>'headline',headline),
    primary_copy=coalesce(p_patch->>'primary_copy',primary_copy),
    supporting_copy=coalesce(p_patch->>'supporting_copy',supporting_copy),
    cta=coalesce(p_patch->>'cta',cta),
    updated_at=now()
  WHERE id=p_angle_id;

  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  v_content := jsonb_build_object('hook',a.hook,'headline',a.headline,'primary_copy',a.primary_copy,
    'supporting_copy',a.supporting_copy,'cta',a.cta,'offer',coalesce(b.offer->>'executable_summary',''),'destination_url',coalesce(b.destination_url,''));
  v_fp := public.fn_ad_studio_fingerprint(v_content);
  v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ',a.hook,a.headline,a.primary_copy,a.supporting_copy,a.cta));

  IF a.review_state='APPROVED' AND v_fp <> coalesce(a.approved_fingerprint,'') THEN v_invalidated := true; END IF;

  UPDATE public.ad_studio_angles SET
    content_fingerprint=v_fp,
    claim_violations=v_scan,
    claim_risk=CASE WHEN jsonb_array_length(v_scan)=0 THEN 'LOW' ELSE 'FLAGGED' END,
    review_state=CASE WHEN v_invalidated THEN 'REVIEW_REQUIRED' ELSE review_state END,
    approved_fingerprint=CASE WHEN v_invalidated THEN NULL ELSE approved_fingerprint END,
    approved_at=CASE WHEN v_invalidated THEN NULL ELSE approved_at END
  WHERE id=p_angle_id;

  RETURN jsonb_build_object('status','ok','content_fingerprint',v_fp,'approval_invalidated',v_invalidated,
    'review_state',(SELECT review_state FROM public.ad_studio_angles WHERE id=p_angle_id),
    'claim_violations',v_scan);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_fingerprint(p jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT md5(concat_ws('|',
    coalesce(p->>'hook',''), coalesce(p->>'headline',''), coalesce(p->>'primary_copy',''),
    coalesce(p->>'supporting_copy',''), coalesce(p->>'cta',''),
    coalesce(p->>'offer',''), coalesce(p->>'destination_url','')));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_generate_angles(p_brief_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  b public.ad_studio_briefs%rowtype;
  v_types text[]; v_type text; v_idx int := 0;
  v_name text; v_problem text; v_outcome text; v_feat text; v_aud jsonb;
  v_hook text; v_headline text; v_primary text; v_support text; v_cta text; v_visual text; v_vhook text; v_vscript text;
  v_scan jsonb; v_content jsonb; v_fp text; v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=p_brief_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','brief_not_found'); END IF;

  v_name := coalesce(nullif(btrim(b.product_name),''),'this product');
  v_problem := nullif(btrim(coalesce(b.problem_solved,'')),'');
  v_outcome := coalesce(v_problem, 'get it done more easily');
  v_feat := coalesce(nullif(btrim(b.product_features->>0),''), (SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(b.product_features) x LIMIT 3) s));
  v_aud := coalesce(b.audience,'{}'::jsonb);

  v_types := ARRAY['PROBLEM_SOLUTION','BENEFIT_OUTCOME'];
  IF b.competitor_intelligence <> '{}'::jsonb THEN v_types := array_append(v_types,'COMPARISON_GAP');
  ELSIF b.product_features <> '[]'::jsonb THEN v_types := array_append(v_types,'DEMONSTRATION');
  ELSE v_types := array_append(v_types,'USE_CASE'); END IF;

  DELETE FROM public.ad_studio_angles WHERE brief_id=p_brief_id;

  FOREACH v_type IN ARRAY v_types LOOP
    v_idx := v_idx + 1;
    IF v_type='PROBLEM_SOLUTION' THEN
      v_hook := coalesce('Still dealing with '||v_problem||'?', 'Looking for a simpler way?');
      v_headline := v_name||' helps you '||v_outcome;
      v_primary := 'If '||coalesce(v_problem,'everyday hassle')||' keeps getting in the way, '||v_name||' is designed to help. See how it works and decide for yourself.';
      v_support := coalesce('Made for people who want to '||v_outcome||'.','');
      v_cta := 'Learn more';
      v_visual := 'Show the problem moment, then '||v_name||' resolving it in the same scene.';
      v_vhook := 'Ever struggle with '||coalesce(v_problem,'this')||'?';
      v_vscript := 'Open on the problem. Introduce '||v_name||'. Show it in use. End on the calmer outcome. Text CTA: Learn more.';
    ELSIF v_type='BENEFIT_OUTCOME' THEN
      v_hook := 'Imagine '||v_outcome||' — without the usual hassle.';
      v_headline := v_name||': built for '||v_outcome;
      v_primary := v_name||' focuses on one thing: helping you '||v_outcome||'. Take a closer look at what it does.';
      v_support := coalesce('Key features: '||v_feat,'');
      v_cta := 'Shop now';
      v_visual := 'Lifestyle shot of the desired outcome with '||v_name||' present and in use.';
      v_vhook := 'Here''s an easier way to '||v_outcome||'.';
      v_vscript := 'Open on the desired outcome. Reveal '||v_name||'. Demonstrate the benefit. Text CTA: Shop now.';
    ELSIF v_type='COMPARISON_GAP' THEN
      v_hook := 'Not all options are the same.';
      v_headline := 'What to look for in '||v_name;
      v_primary := 'There are many ways to approach '||coalesce(v_problem,'this')||'. Here is what '||v_name||' does and how to judge whether it fits your needs.';
      v_support := coalesce('Consider: '||v_feat,'');
      v_cta := 'See details';
      v_visual := 'Side-by-side of a generic approach vs using '||v_name||' (own footage only; no competitor branding).';
      v_vhook := 'Before you choose, watch this.';
      v_vscript := 'Frame the decision. Show '||v_name||' attributes. Let the viewer compare. Text CTA: See details.';
    ELSE
      v_hook := 'Watch '||v_name||' in action.';
      v_headline := v_name||' in everyday use';
      v_primary := 'A quick look at how '||v_name||' works in a real situation. Judge it for yourself.';
      v_support := coalesce('Highlights: '||v_feat,'');
      v_cta := 'Watch how it works';
      v_visual := 'Close, well-lit demonstration of '||v_name||' being used step by step.';
      v_vhook := 'Does '||v_name||' actually work? Let''s see.';
      v_vscript := 'Show setup. Show use. Show the result of the task. Text CTA: Watch how it works.';
    END IF;

    v_content := jsonb_build_object('hook',v_hook,'headline',v_headline,'primary_copy',v_primary,
      'supporting_copy',v_support,'cta',v_cta,'offer',coalesce(b.offer->>'executable_summary',''),'destination_url',coalesce(b.destination_url,''));
    v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ',v_hook,v_headline,v_primary,v_support,v_cta));
    v_fp := public.fn_ad_studio_fingerprint(v_content);

    INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_name,angle_type,customer_problem,
      desired_outcome,evidence_basis,evidence_refs,audience_segment,hook,headline,primary_copy,supporting_copy,cta,
      visual_concept,static_creative_brief,video_hook,video_script,storyboard,platform_notes,claim_risk,claim_violations,
      review_state,content_fingerprint)
    VALUES (p_brief_id,b.tenant_id,v_idx,initcap(replace(v_type,'_',' ')),v_type,v_problem,
      v_outcome, jsonb_build_object('used', b.evidence_completeness, 'note','angle copy derived only from provided product facts; missing facts left UNKNOWN'),
      b.evidence_refs, v_aud, v_hook, v_headline, v_primary, v_support, v_cta,
      v_visual, v_visual, v_vhook, v_vscript, '[]'::jsonb, '{}'::jsonb,
      CASE WHEN jsonb_array_length(v_scan)=0 THEN 'LOW' ELSE 'FLAGGED' END, v_scan,
      'REVIEW_REQUIRED', v_fp);
    v_out := v_out || jsonb_build_object('angle_index',v_idx,'angle_type',v_type,'claim_risk',
      CASE WHEN jsonb_array_length(v_scan)=0 THEN 'LOW' ELSE 'FLAGGED' END);
  END LOOP;

  UPDATE public.ad_studio_briefs SET status='REVIEW_REQUIRED', updated_at=now() WHERE id=p_brief_id;
  RETURN jsonb_build_object('status','ok','brief_id',p_brief_id,'angles',v_out);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_handoff(p_decision jsonb, p_context jsonb, p_landing_page_url text, p_store_provider text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'handoff_type','AD_STUDIO','product_id', p_context->>'product_id','market', p_decision->>'target_market',
    'landing_page_url', p_landing_page_url,'store_provider', p_store_provider,
    'positioning', p_context->>'positioning','offer', p_context->'competitive_price_anchor',
    'selling_price', p_context->>'selling_price','currency', p_context->>'display_currency',
    'audience', p_context->'audience_evidence','buyer_intent_themes', p_context->'buyer_intent',
    'assets', p_context->'product_assets','brand', p_context->>'brand_name','cta','REQUIRES_GENERATION',
    'provenance', jsonb_build_object('source','pulse_decision','buyer_intent','GOOGLE_ADS_via_DATAFORSEO'),
    'lifecycle','DRAFT_FIRST_PAUSED','note','feeds marketing_campaign_drafts; PAUSED-first; explicit approval to launch');
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ad_studio_platform_variants(p_angle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  targets jsonb; plc text; plat text; placements text[]; v_hook text; v_copy text; v_cta text;
  v_aspect text; v_comp text; v_pace text; v_open text; v_cap text; v_scan jsonb; out jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','angle_not_found'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  targets := coalesce(b.platform_targets,'["META","TIKTOK"]'::jsonb);
  DELETE FROM public.ad_studio_platform_variants WHERE angle_id=p_angle_id;

  IF targets ? 'META' THEN placements := ARRAY['FB_FEED','IG_FEED','IG_STORY_REEL']; ELSE placements := ARRAY[]::text[]; END IF;

  FOREACH plc IN ARRAY placements LOOP
    plat := 'META';
    IF plc='IG_STORY_REEL' THEN
      v_hook := left(a.hook, 60); v_copy := left(a.primary_copy, 125); v_cta := a.cta;
      v_aspect := '9:16'; v_comp := 'Full-bleed vertical; product centered in safe area; minimal on-screen text.';
      v_pace := 'Fast; 3-5 scenes'; v_open := 'Hook visible in first 1s (text + motion).'; v_cap := 'Very short caption; 1 line + CTA sticker.';
    ELSE
      v_hook := a.hook; v_copy := a.primary_copy; v_cta := a.cta;
      v_aspect := CASE WHEN plc='IG_FEED' THEN '4:5' ELSE '1:1' END;
      v_comp := 'Product hero with clear focal point; headline overlay; 20% margin for platform UI.';
      v_pace := 'N/A (static or 15-30s)'; v_open := 'Headline + product visible immediately.';
      v_cap := 'Feed caption: hook line, 1-2 benefit lines, CTA.';
    END IF;
    v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ',v_hook,v_copy,v_cta));
    INSERT INTO public.ad_studio_platform_variants(angle_id,tenant_id,platform,placement,hook,copy_structure,primary_copy,cta,aspect_ratio,visual_composition,script_pacing,opening_seconds,caption_approach,claim_violations)
    VALUES (p_angle_id,a.tenant_id,plat,plc,v_hook,
      jsonb_build_object('headline',a.headline,'body',v_copy,'cta',v_cta),v_copy,v_cta,v_aspect,v_comp,v_pace,v_open,v_cap,v_scan);
    out := out || jsonb_build_object('platform',plat,'placement',plc,'aspect_ratio',v_aspect);
  END LOOP;

  IF targets ? 'TIKTOK' THEN
    plat := 'TIKTOK'; plc := 'TIKTOK_FEED';
    v_hook := left(coalesce(a.video_hook,a.hook),50);
    v_copy := left(coalesce(a.video_script,a.primary_copy),150);
    v_cta := a.cta; v_aspect := '9:16';
    v_comp := 'Native, hand-held feel; real use in real setting; on-screen captions; avoid polished ad look.';
    v_pace := 'Very fast; cut every 1-2s; 15-30s total.';
    v_open := 'Native hook + payoff tease in first 3 seconds; no logo intro.';
    v_cap := 'Casual first-person caption; 1-2 short sentences; no copyrighted competitor audio.';
    v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ',v_hook,v_copy,v_cta));
    INSERT INTO public.ad_studio_platform_variants(angle_id,tenant_id,platform,placement,hook,copy_structure,primary_copy,cta,aspect_ratio,visual_composition,script_pacing,opening_seconds,caption_approach,claim_violations)
    VALUES (p_angle_id,a.tenant_id,plat,plc,v_hook,
      jsonb_build_object('script',v_copy,'cta',v_cta),v_copy,v_cta,v_aspect,v_comp,v_pace,v_open,v_cap,v_scan);
    out := out || jsonb_build_object('platform',plat,'placement',plc,'aspect_ratio',v_aspect);
  END IF;

  DELETE FROM public.ad_studio_static_creatives WHERE angle_id=p_angle_id;
  INSERT INTO public.ad_studio_static_creatives(angle_id,tenant_id,platform,product_asset_refs,headline,supporting_text,cta,visual_hierarchy,layout,aspect_ratio,safe_area,brand_context,generation_provider,generation_status,provenance)
  SELECT p_angle_id,a.tenant_id,'META',b.product_assets,a.headline,a.supporting_copy,a.cta,
    jsonb_build_array('product','headline','cta'),'hero-top headline, product-center, CTA-bottom','1:1','platform UI margins 20%',
    jsonb_build_object('market',b.market),NULL,'PENDING',
    jsonb_build_object('angle_id',p_angle_id,'brief_id',b.id,'note','no image provider configured; awaits provider or mock fixture');
  RETURN jsonb_build_object('status','ok','variants',out);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_apply_product_supply_confidence(p_provisional_class text, p_product_trust_gate text, p_supply_confidence text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_final text := p_provisional_class; v_reason text := 'unchanged';
BEGIN
  IF p_product_trust_gate = 'PRODUCT_TRUST_BLOCKED' THEN
    v_final := 'AVOID'; v_reason := 'product_trust_blocked_authenticity';
  ELSIF upper(coalesce(p_provisional_class,'')) = 'HIGH_CONFIDENCE_TEST' THEN
    IF p_supply_confidence = 'FULLY_VERIFIED' AND p_product_trust_gate = 'PRODUCT_TRUST_PASS' THEN
      v_final := 'HIGH_CONFIDENCE_TEST'; v_reason := 'fully_verified_supply_and_product_trust';
    ELSIF p_supply_confidence = 'BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED'
          AND p_product_trust_gate IN ('PRODUCT_TRUST_PASS','PRODUCT_TRUST_ACCEPTABLE') THEN
      v_final := 'STRONG_TEST'; v_reason := 'beta_acceptable_reliability_unobserved_capped_from_high_confidence';
    ELSE
      v_final := 'WATCH'; v_reason := 'supply_or_product_trust_not_sufficient_for_high_confidence';
    END IF;
  END IF;
  RETURN jsonb_build_object('final_class', v_final, 'provisional_class', p_provisional_class,
    'product_trust_gate', p_product_trust_gate, 'supply_confidence', p_supply_confidence, 'reason', v_reason,
    'distinction_note','STRONG_TEST != HIGH_CONFIDENCE_TEST: reliability unobserved, not verified');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_apply_supplier_hard_gate(p_provisional_class text, p_supplier_gate text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_final text := p_provisional_class; v_reason text := 'unchanged';
BEGIN
  IF upper(coalesce(p_provisional_class,'')) = 'HIGH_CONFIDENCE_TEST' AND coalesce(p_supplier_gate,'') <> 'PASS' THEN
    v_final := CASE p_supplier_gate
                 WHEN 'FAIL' THEN 'AVOID'
                 WHEN 'INSUFFICIENT_EVIDENCE' THEN 'WATCH'
                 WHEN 'WATCH' THEN 'WATCH'
                 ELSE 'WATCH' END;
    v_reason := 'supplier_hard_gate_'||coalesce(p_supplier_gate,'MISSING')||'_blocks_high_confidence_test';
  END IF;
  RETURN jsonb_build_object('final_class', v_final, 'supplier_gate', p_supplier_gate, 'reason', v_reason);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_approve_spend_authority(p_actor uuid, p_authority_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.marketing_spend_authority;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  SELECT * INTO a FROM public.marketing_spend_authority WHERE id=p_authority_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF a.status IN ('REVOKED','EXPIRED') THEN RETURN jsonb_build_object('status','invalid_transition','authority_status',a.status); END IF;
  UPDATE public.marketing_spend_authority
    SET status='ACTIVE', approved_by=p_actor, approved_at=now(), authority_fingerprint=public.fn_spend_authority_fingerprint(a)
    WHERE id=p_authority_id;
  PERFORM public.fn_authority_audit(a.tenant_id,'AUTHORITY_APPROVED',p_actor,p_authority_id,NULL,to_jsonb(a),NULL,NULL,NULL);
  RETURN jsonb_build_object('status','ACTIVE','authority_id',p_authority_id,'executable',a.executable);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_assemble_real_product_market(p_candidate uuid, p_country text, p_currency text, p_price_query text, p_supplier uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  cand record; tenant uuid; price record; sup record; fr jsonb;
  community_conf numeric; mkt_signals int;
  dm numeric; mv numeric; ssub numeric;
  landed numeric; ref_landed numeric; landed_ccy text; fulfil text; econ jsonb; ref_econ jsonb; evidence jsonb;
  pme_id uuid; pme_dec text; comp_arr jsonb := '[]'::jsonb; n_pts int; lst record; k int;
  freight_cost numeric; freight_days text; sup_ident jsonb; sup_class text; is_exact boolean;
BEGIN
  SELECT * INTO cand FROM public.commerce_products WHERE id=p_candidate;
  IF cand.id IS NULL THEN RETURN jsonb_build_object('error','CANDIDATE_NOT_FOUND'); END IF;
  tenant := cand.user_id;
  SELECT * INTO price FROM public.market_price_observations
   WHERE product_query=p_price_query AND market=p_country AND currency=p_currency AND source='EBAY_BROWSE'
   ORDER BY observed_at DESC LIMIT 1;
  IF p_supplier IS NOT NULL THEN SELECT * INTO sup FROM public.commerce_supplier_products WHERE id=p_supplier;
  ELSE SELECT * INTO sup FROM public.commerce_supplier_products
       WHERE source='cjdropshipping' AND category=cand.category ORDER BY supplier_cost NULLS LAST LIMIT 1; END IF;

  -- ── supplier product IDENTITY resolution (category match never certifies TEST economics) ──
  sup_ident := public.fn_resolve_supplier_identity(cand.title, cand.category, cand.product_identity,
                 sup.title, sup.category, sup.source_product_id, false);  -- no shared identifier link -> not EXACT
  sup_class := coalesce(sup_ident->>'match_class','UNKNOWN');
  is_exact := (sup_class = 'EXACT_PRODUCT');

  SELECT max(confidence) INTO community_conf FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='COMMUNITY_ATTENTION';
  SELECT count(*) INTO mkt_signals FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='MARKETPLACE_ACTIVITY';
  dm := CASE WHEN community_conf IS NOT NULL THEN round(community_conf*100,0) ELSE NULL END;
  mv := CASE WHEN mkt_signals>0 OR price.id IS NOT NULL THEN least(100, 50 + coalesce(mkt_signals,0)*3) ELSE NULL END;
  ssub := CASE WHEN sup.id IS NULL OR sup_class IN ('UNRELATED','UNKNOWN') THEN NULL
               WHEN is_exact THEN 60 WHEN sup_class='CLOSE_COMPARABLE' THEN 40 ELSE 25 END;

  fr := sup.supplier_enrichment->'freight'->p_country->'representative';
  freight_cost := nullif(fr->>'shipping_cost','')::numeric;
  freight_days := CASE WHEN fr ? 'est_min_days' THEN (fr->>'est_min_days')||'-'||(fr->>'est_max_days')||' days' ELSE NULL END;
  landed_ccy := coalesce(sup.cost_currency,'USD');
  IF sup.supplier_cost IS NOT NULL AND freight_cost IS NOT NULL THEN ref_landed := sup.supplier_cost + freight_cost; END IF;
  -- CERTIFIED landed cost only for EXACT_PRODUCT identity; otherwise landed stays NULL (economics UNKNOWN -> WATCH)
  IF is_exact AND ref_landed IS NOT NULL THEN landed := ref_landed; fulfil := 'true'; ELSE landed := NULL; fulfil := NULL; END IF;

  -- reference economics (display only; never feeds the gate) when a comparable landed cost exists
  ref_econ := CASE WHEN price.id IS NOT NULL AND ref_landed IS NOT NULL
    THEN public.fn_economics_breakeven(price.price_median, ref_landed, landed_ccy, p_currency, jsonb_build_object('payment_fee_pct',0.03))
         || jsonb_build_object('basis','REFERENCE_COMPARABLE_SUPPLIER','supplier_match_class',sup_class)
    ELSE NULL END;

  evidence := jsonb_build_object(
    'buyer_search_intent', '{}'::jsonb,
    'demand_momentum', CASE WHEN dm IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',dm::text,'source','reddit','source_class','OBSERVED') END,
    'marketplace_validation', CASE WHEN mv IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',mv::text,'source','EBAY_BROWSE','source_class','PLATFORM_REPORTED') END,
    'advertising_activity', '{}'::jsonb,
    'supplier_availability_stock', CASE WHEN ssub IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',ssub::text,'source','cjdropshipping') END,
    'supplier_identity', sup_ident || jsonb_build_object('supplier_title',sup.title,'supplier_source_product_id',sup.source_product_id),
    'reference_economics', coalesce(ref_econ,'{}'::jsonb),
    'stock_state','UNKNOWN','compliance_risk','UNKNOWN','fulfilment_usable', fulfil,
    'observed_market_price', CASE WHEN price.id IS NOT NULL
       THEN jsonb_build_object('source_class','PLATFORM_REPORTED','amount',price.price_median,'currency',price.currency,
             'range',jsonb_build_array(price.price_min,price.price_max),'sample',price.sample_size,'total_listings',price.total_listings,
             'source','EBAY_BROWSE','observed_at',price.observed_at)
       ELSE jsonb_build_object('source_class','UNKNOWN') END,
    'delivery_evidence', CASE WHEN freight_days IS NOT NULL THEN jsonb_build_object('estimate',freight_days,'source','CJ_FREIGHT_CALCULATE') ELSE '{}'::jsonb END,
    'risk_flags', CASE WHEN NOT is_exact THEN jsonb_build_array('SUPPLIER_IDENTITY_NOT_EXACT_ECONOMICS_REFERENCE_ONLY') ELSE jsonb_build_array() END);

  econ := CASE WHEN price.id IS NOT NULL AND landed IS NOT NULL
    THEN jsonb_build_object('selling_price',price.price_median::text,'selling_price_source_class','PLATFORM_REPORTED',
           'landed_cost',landed::text,'landed_currency',landed_ccy,'fees',jsonb_build_object('payment_fee_pct','0.03'))
    WHEN price.id IS NOT NULL
    THEN jsonb_build_object('selling_price',price.price_median::text,'selling_price_source_class','PLATFORM_REPORTED')  -- landed withheld (identity not exact) -> economics UNKNOWN
    ELSE NULL END;

  PERFORM public.fn_evaluate_product_market(tenant, p_candidate, p_country, p_currency, evidence, econ, '{}'::jsonb, false, p_persist);
  SELECT id, market_decision INTO pme_id, pme_dec FROM public.product_market_evaluations
    WHERE tenant_id=tenant AND product_id=p_candidate AND country_code=p_country;

  FOR lst IN SELECT (value->>'price')::numeric px, value->>'currency' ccy
             FROM public.commerce_signals
             WHERE product_id=p_candidate AND signal_type='MARKETPLACE_ACTIVITY'
               AND value->>'market'=p_country AND value->>'currency'=p_currency AND value->>'price' IS NOT NULL LOOP
    comp_arr := comp_arr || jsonb_build_array(jsonb_build_object(
      'match_class','CLOSE_COMPARABLE','competitor_kind','MARKETPLACE_LISTING','competitor_identity',NULL,
      'platform','EBAY','source','EBAY_BROWSE','evidence_class','OBSERVED','confidence','MEDIUM',
      'match_evidence',jsonb_build_object('basis','ebay_token_overlap_match','note','close comparable, not exact-product'),
      'price',jsonb_build_object('amount',lst.px,'currency',lst.ccy,'source_class','OBSERVED','country',p_country)));
  END LOOP;
  IF jsonb_array_length(comp_arr)=0 AND price.id IS NOT NULL THEN
    n_pts := CASE WHEN price.total_listings>=1000 THEN 6 WHEN price.total_listings>=500 THEN 5
                  WHEN price.total_listings>=200 THEN 4 WHEN price.total_listings>=50 THEN 3 ELSE 2 END;
    FOR k IN 1..n_pts LOOP
      comp_arr := comp_arr || jsonb_build_array(jsonb_build_object(
        'match_class','CLOSE_COMPARABLE','competitor_kind','MARKETPLACE_LISTING','competitor_identity',NULL,
        'platform','EBAY','source','EBAY_BROWSE','evidence_class','OBSERVED','confidence','MEDIUM',
        'price',jsonb_build_object('amount',CASE k WHEN 1 THEN price.price_min WHEN 2 THEN price.price_max ELSE price.price_median END,
          'currency',price.currency,'source_class','OBSERVED','country',p_country)));
    END LOOP;
  END IF;
  IF jsonb_array_length(comp_arr)>0 THEN
    DELETE FROM public.product_market_competitors WHERE tenant_id=tenant AND product_id=p_candidate AND country_code=p_country AND is_fixture=false;
    PERFORM public.fn_pmc_evaluate(tenant, p_candidate, p_country, p_currency, comp_arr, pme_id, '{}'::jsonb, false, p_persist);
  END IF;

  RETURN jsonb_build_object('tenant',tenant,'product',p_candidate,'country',p_country,'currency',p_currency,
    'price_median',price.price_median,'total_listings',price.total_listings,
    'supplier',sup.title,'supplier_match_class',sup_class,'supplier_cost',sup.supplier_cost,
    'freight_to_dest',freight_cost,'freight_days',freight_days,
    'certified_landed',landed,'reference_landed',ref_landed,
    'reference_contribution_after_reserve', ref_econ->>'contribution_after_reserve',
    'pme_id',pme_id,'market_decision',pme_dec,'competitor_entries',jsonb_array_length(comp_arr),
    'economics_certified', is_exact, 'contract','pulse_real_assembler_v2');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_authenticity_contract(p_classification text, p_auth_evidence jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_authorized boolean := (p_auth_evidence->>'authorized')::boolean;
  v_etype text := lower(coalesce(p_auth_evidence->>'evidence_type',''));
  v_strong boolean := coalesce(v_authorized,false) AND v_etype IN ('brand_authorization','license','distribution_agreement','certificate');
BEGIN
  IF p_classification = 'GENERIC_UNBRANDED' THEN
    RETURN jsonb_build_object('requirement','AUTHENTICITY_NOT_APPLICABLE','state','AUTHENTICITY_NOT_APPLICABLE',
      'satisfied',true,'gating',false,'note','no protected brand/IP identity represented');
  ELSIF p_classification = 'BRANDED' THEN
    IF coalesce(v_authorized,false) AND v_etype <> '' THEN
      RETURN jsonb_build_object('requirement','AUTHENTICITY_REQUIRED','state','AUTHENTICITY_VERIFIED','satisfied',true,'gating',true,'evidence_type',v_etype);
    ELSE
      RETURN jsonb_build_object('requirement','AUTHENTICITY_REQUIRED','state','AUTHENTICITY_MISSING','satisfied',false,'gating',true,'note','branded product without authorization/authenticity evidence');
    END IF;
  ELSIF p_classification = 'LICENSED_OR_IP_SENSITIVE' THEN
    IF v_strong THEN
      RETURN jsonb_build_object('requirement','AUTHENTICITY_REQUIRED_STRICT','state','AUTHENTICITY_VERIFIED_STRICT','satisfied',true,'gating',true,'evidence_type',v_etype);
    ELSE
      RETURN jsonb_build_object('requirement','AUTHENTICITY_REQUIRED_STRICT','state','AUTHENTICITY_MISSING_STRICT','satisfied',false,'gating',true,'note','licensed/IP-sensitive without strict authorization');
    END IF;
  ELSE -- UNKNOWN
    RETURN jsonb_build_object('requirement','AUTHENTICITY_UNRESOLVED','state','AUTHENTICITY_UNRESOLVED','satisfied',false,'gating',true,'note','brand status unresolved; authenticity cannot be waived');
  END IF;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_authority_audit(p_tenant uuid, p_event text, p_actor uuid, p_auth uuid, p_campaign uuid, p_before jsonb, p_after jsonb, p_reason text, p_corr text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  INSERT INTO public.marketing_authority_audit(tenant_id,event,actor,authority_id,campaign_id,before_state,after_state,reason,correlation_key)
  VALUES (p_tenant,p_event,p_actor,p_auth,p_campaign,p_before,p_after,p_reason,p_corr);
$function$
;

CREATE OR REPLACE FUNCTION public.fn_beta_supply_decision(p_product jsonb, p_supplier jsonb, p_reviews jsonb, p_auth_evidence jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_cls jsonb := public.fn_product_trust_classification(p_product);
  v_auth jsonb := public.fn_authenticity_contract(v_cls->>'classification', p_auth_evidence);
  v_qual jsonb := public.fn_product_quality_state(p_reviews);
  v_ptg jsonb := public.fn_product_trust_gate(v_cls, v_auth, v_qual);
  v_seg jsonb := public.fn_supplier_execution_gate(p_supplier, p_target_market, p_selling_price, p_display_currency);
  v_pt text := v_ptg->>'product_trust_gate';
  v_se text := v_seg->>'supplier_execution_gate';
  v_rel text := v_seg->>'reliability_state';
  v_class text := v_cls->>'classification';
  v_supply_conf text; v_decision text;
BEGIN
  -- supply confidence
  IF v_rel = 'RELIABILITY_OBSERVED' AND v_se='SUPPLIER_EXECUTION_PASS' AND v_pt='PRODUCT_TRUST_PASS' THEN
    v_supply_conf := 'FULLY_VERIFIED';
  ELSIF v_rel = 'RELIABILITY_NOT_OBSERVABLE_FROM_SOURCE' AND v_se='SUPPLIER_EXECUTION_PASS'
        AND v_pt IN ('PRODUCT_TRUST_PASS','PRODUCT_TRUST_ACCEPTABLE') AND v_class='GENERIC_UNBRANDED' THEN
    v_supply_conf := 'BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED';
  ELSE
    v_supply_conf := 'NOT_ACCEPTABLE';
  END IF;

  -- decision
  IF v_pt = 'PRODUCT_TRUST_BLOCKED' THEN v_decision := 'BLOCKED_PRODUCT_TRUST';
  ELSIF v_se = 'SUPPLIER_EXECUTION_FAIL' THEN v_decision := 'FAIL_SUPPLIER_EXECUTION';
  ELSIF v_se = 'SUPPLIER_EXECUTION_INSUFFICIENT' THEN v_decision := 'INSUFFICIENT_EVIDENCE';
  ELSIF v_supply_conf = 'FULLY_VERIFIED' THEN v_decision := 'FULLY_VERIFIED_SUPPLY';
  ELSIF v_supply_conf = 'BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED' THEN v_decision := 'BETA_SUPPLY_ACCEPTABLE_WITH_RELIABILITY_UNOBSERVED';
  ELSE v_decision := 'WATCH';
  END IF;

  RETURN jsonb_build_object(
    'decision', v_decision, 'supply_confidence', v_supply_conf,
    'product_trust', jsonb_build_object('gate',v_pt,'classification',v_cls,'authenticity',v_auth,'quality',v_qual,'detail',v_ptg),
    'supplier_execution', v_seg,
    'honest_labeling', jsonb_build_object(
      'reliability_state', v_rel,
      'is_verified_reliable_supplier', (v_rel='RELIABILITY_OBSERVED'),
      'note', CASE WHEN v_supply_conf='BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED'
                   THEN 'Beta-acceptable supply; supplier reliability NOT observed from source. NOT a verified reliable supplier.'
                   ELSE 'See supply_confidence.' END),
    'provenance', jsonb_build_object('product_trust','PRODUCT_LEVEL','supplier_execution','GLOBAL_SUPPLY + TENANT_ECONOMICS'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_build_evidence_profile_v2(p_product_id uuid, p_target_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_prod public.commerce_products%rowtype; v_cj_pid text; v_sup public.commerce_supplier_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_target_market,''))); v_freight jsonb; v_rep jsonb;
  v_comm_posts int; v_comm_last timestamptz; v_comm_markets text[]; v_comm_state text; v_comm_score numeric; v_fresh text; v_align text;
  v_reviews jsonb; v_supplier jsonb; v_product jsonb; v_profile jsonb; v_evver text;
  v_adv_count int; v_adv_last timestamptz; v_adv jsonb;
  v_mkt_count int; v_mkt_last timestamptz; v_mkt_pmin numeric; v_mkt_pmax numeric; v_mkt_cur text; v_mktp jsonb;
  v_sd_count int; v_sd_last timestamptz; v_sd_val jsonb; v_search jsonb;
  v_search_rt text; v_mkt_rt text; v_adv_rt text;
BEGIN
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_cj_pid := v_prod.extended->>'cj_source_product_id';
  IF v_cj_pid IS NOT NULL THEN SELECT * INTO v_sup FROM public.commerce_supplier_products WHERE source_product_id = v_cj_pid; END IF;

  SELECT count(DISTINCT coalesce(dedup_key, id::text)), max(coalesce(source_event_at, observed_at)),
         array_agg(DISTINCT upper(coalesce(value->>'market', evidence->>'market','UNKNOWN')))
    INTO v_comm_posts, v_comm_last, v_comm_markets
    FROM public.commerce_signals WHERE product_id = p_product_id AND signal_type = 'COMMUNITY_ATTENTION';
  v_comm_posts := coalesce(v_comm_posts,0);
  IF v_comm_posts > 0 THEN
    v_comm_state := 'OBSERVED'; v_comm_score := least(85, 45 + v_comm_posts*8);
    v_fresh := CASE WHEN v_comm_last >= now()-interval '30 days' THEN 'FRESH' WHEN v_comm_last >= now()-interval '90 days' THEN 'AGING' ELSE 'STALE' END;
    v_align := CASE WHEN v_mkt = ANY(v_comm_markets) THEN 'SAME_MARKET' WHEN 'UNKNOWN' = ANY(v_comm_markets) THEN 'GLOBAL_CONTEXT' ELSE 'CROSS_MARKET' END;
  ELSE v_comm_state := 'NOT_OBSERVED'; v_comm_score := NULL; v_fresh := 'UNKNOWN'; v_align := 'UNKNOWN_MARKET'; END IF;

  SELECT count(DISTINCT coalesce(dedup_key, id::text)), max(coalesce(source_event_at, observed_at)) INTO v_adv_count, v_adv_last
    FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='ADVERTISING_ACTIVITY'
      AND upper(coalesce(value->>'market', evidence->>'market','')) = v_mkt;
  v_adv_count := coalesce(v_adv_count,0);
  v_adv_rt := public.fn_category_market_state('ADVERTISING', v_mkt);
  IF v_adv_count > 0 THEN
    v_adv := jsonb_build_object('state','OBSERVED','score', least(80, 40 + v_adv_count*6),'distinct_ads', v_adv_count,
      'source','META_AD_LIBRARY','provenance','PLATFORM_REPORTED','observed_at', v_adv_last,'note','ad presence != sales/profit');
  ELSE
    v_adv := jsonb_build_object('state', CASE WHEN v_adv_rt IN ('AVAILABLE','PARTIAL','UNKNOWN') THEN 'NOT_OBSERVED' ELSE v_adv_rt END,
      'router_state', v_adv_rt, 'source_routing', public.fn_route_evidence('ADVERTISING', v_mkt));
  END IF;

  -- SEARCH_DEMAND (routed + real buyer-intent signal)
  v_search_rt := public.fn_category_market_state('SEARCH_DEMAND', v_mkt);
  SELECT count(*), max(coalesce(source_event_at,observed_at)), (array_agg(value ORDER BY observed_at DESC))[1]
    INTO v_sd_count, v_sd_last, v_sd_val
    FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='SEARCH_DEMAND'
      AND upper(coalesce(value->>'market',''))=v_mkt;
  v_sd_count := coalesce(v_sd_count,0);
  IF v_sd_count > 0 THEN
    v_search := jsonb_build_object('state','OBSERVED','score', nullif(v_sd_val->>'buyer_intent_score','')::numeric,
      'band', v_sd_val->>'buyer_intent_band','subscores', v_sd_val->'subscores','headline_query', v_sd_val->>'headline_query',
      'source', v_sd_val->>'source_platform','provenance','PLATFORM_REPORTED','observed_at', v_sd_last,
      'note','search interest ESTIMATED; intent INFERRED; NOT sales/conversion','router_state', v_search_rt);
  ELSE
    v_search := jsonb_build_object('state', CASE WHEN v_search_rt IN ('AVAILABLE','PARTIAL','UNKNOWN') THEN 'NOT_OBSERVED' ELSE v_search_rt END,
      'router_state', v_search_rt, 'source_routing', public.fn_route_evidence('SEARCH_DEMAND', v_mkt));
  END IF;

  v_mkt_rt := public.fn_category_market_state('MARKETPLACE', v_mkt);
  SELECT count(DISTINCT coalesce(dedup_key, id::text)), max(coalesce(source_event_at, observed_at)),
         min((value->>'price')::numeric), max((value->>'price')::numeric), min(value->>'currency')
    INTO v_mkt_count, v_mkt_last, v_mkt_pmin, v_mkt_pmax, v_mkt_cur
    FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='MARKETPLACE_ACTIVITY'
      AND upper(coalesce(value->>'market', evidence->>'market','')) = v_mkt;
  v_mkt_count := coalesce(v_mkt_count,0);
  IF v_mkt_count > 0 THEN
    v_mktp := jsonb_build_object('state','OBSERVED','score', 60, 'matched_listings', v_mkt_count, 'source','EBAY_BROWSE_API',
      'provenance','PLATFORM_REPORTED','observed_at', v_mkt_last, 'price_min', v_mkt_pmin, 'price_max', v_mkt_pmax, 'currency', v_mkt_cur,
      'competition_signal', CASE WHEN v_mkt_count >= 20 THEN 'HIGH_PRESENCE' WHEN v_mkt_count >= 5 THEN 'MODERATE_PRESENCE' ELSE 'LOW_PRESENCE' END,
      'note','active listings = real marketplace presence + competition/saturation; NOT demand/sales/orders/revenue/conversion/winner',
      'router_state', v_mkt_rt);
  ELSE
    v_mktp := jsonb_build_object('state', CASE WHEN v_mkt_rt IN ('AVAILABLE','PARTIAL','UNKNOWN') THEN 'NOT_OBSERVED' ELSE v_mkt_rt END,
      'router_state', v_mkt_rt, 'source_routing', public.fn_route_evidence('MARKETPLACE', v_mkt));
  END IF;

  IF v_sup.id IS NOT NULL THEN
    v_freight := v_sup.supplier_enrichment->'freight'->v_mkt; v_rep := v_freight->'representative';
    v_supplier := jsonb_build_object('source', v_sup.source, 'supplier_id', v_sup.supplier_id,
      'supplier_cost', v_sup.supplier_cost, 'cost_currency', v_sup.cost_currency, 'is_free_shipping', v_sup.is_free_shipping,
      'shipping_cost', nullif(v_rep->>'shipping_cost','')::numeric, 'shipping_country_codes', v_sup.shipping_country_codes,
      'sale_status', v_sup.sale_status, 'delivery_estimate', v_rep, 'stock', v_sup.supplier_enrichment->'stock');
    v_reviews := jsonb_build_object('total', coalesce((v_sup.supplier_enrichment->'product_comments'->>'total')::int, 0),
      'source','CJ_PRODUCT_COMMENTS','observed_at', v_sup.supplier_enrichment->'product_comments'->>'observed_at');
  ELSE v_supplier := jsonb_build_object('source','none'); v_reviews := jsonb_build_object('total',0,'source','none'); END IF;

  v_product := jsonb_build_object('title', v_prod.title, 'category', v_prod.category,
    'description', coalesce(v_prod.description,''), 'brand', v_prod.extended->>'brand', 'material', v_prod.extended->>'material');

  v_profile := jsonb_build_object(
    'SEARCH_DEMAND', v_search,
    'TREND', jsonb_build_object('state','NOT_OBSERVED'),
    'SOCIAL_ATTENTION', jsonb_build_object('state','NOT_OBSERVED'),
    'COMMUNITY_ATTENTION', jsonb_build_object('state', v_comm_state, 'score', v_comm_score, 'distinct_posts', v_comm_posts,
        'freshness', v_fresh, 'market_alignment', v_align, 'provenance','PLATFORM_REPORTED','note','one independent category regardless of post count'),
    'MARKETPLACE_ACTIVITY', v_mktp,
    'ADVERTISING_ACTIVITY', v_adv,
    'COMPETITION_SATURATION', jsonb_build_object('state','NOT_OBSERVED','note','not scored from a capped Browse sample; see MARKETPLACE_ACTIVITY.competition_signal'),
    '_meta', jsonb_build_object('freshness', v_fresh, 'conflicts', false));

  v_evver := md5(coalesce(v_sup.supplier_enrichment->>'observed_at','')||'|'||coalesce(v_comm_last::text,'')||'|'||v_mkt||'|'||v_comm_posts::text||'|adv'||v_adv_count::text||'|mkt'||v_mkt_count::text||'|sd'||v_sd_count::text);

  RETURN jsonb_build_object('status','ok','profile', v_profile, 'product', v_product, 'supplier', v_supplier,
    'reviews', v_reviews, 'market_advantage', NULL, 'cx_signals', '{}'::jsonb,
    'evidence_version', v_evver, 'market_alignment', v_align, 'community_posts', v_comm_posts,
    'pulse_market_supported', public.fn_is_supported_market(v_mkt),
    'display_currency', public.fn_currency_for_country(v_mkt),
    'has_cj_match', (v_sup.id IS NOT NULL),
    'provenance', jsonb_build_object('routing','global_evidence_router','supply','CJ market-specific'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_build_product_page_model(p_decision jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text := coalesce(p_context->>'product_title','Product');
  v_pos text := coalesce(p_context->>'positioning', v_title);
  v_cur text := coalesce(p_context->>'display_currency','USD');
  v_deliv jsonb := coalesce(p_decision->'supplier_execution'->'delivery','{}'::jsonb);
BEGIN
  RETURN jsonb_build_object(
    'model_version','pulse_product_page_v1','editable',true,'draft_first',true,
    'brand', jsonb_build_object('name', p_context->>'brand_name','requires_generation',(p_context->>'brand_name') IS NULL),
    'hero', jsonb_build_object('headline', v_pos,'subheadline','REQUIRES_GENERATION','editable',true),
    'product_title', v_title,
    'positioning', v_pos,
    'assets', jsonb_build_object('primary_image', NULL,'gallery','[]'::jsonb,'requires_merchant_verification',true,
       'note','product images not auto-collected; merchant uploads/verifies (no fabricated assets)'),
    'price', jsonb_build_object('selling_price', p_context->>'selling_price','currency', v_cur,
       'source_currency', p_decision->'economics'->>'landed_cost_currency',
       'landed_cost_display', p_decision->'economics'->>'landed_cost_display'),
    'offer', jsonb_build_object('competitive_price_anchor', p_context->'competitive_price_anchor','value_prop','REQUIRES_GENERATION','editable',true),
    'benefits', jsonb_build_array('REQUIRES_GENERATION'),
    'problem_solution', jsonb_build_object('problem','REQUIRES_GENERATION','solution','REQUIRES_GENERATION'),
    'how_it_works', jsonb_build_array('REQUIRES_GENERATION'),
    'details', jsonb_build_object('positioning', v_pos,'buyer_intent_band', p_context->'buyer_intent'->>'band'),
    'shipping', jsonb_build_object('est_min_days', v_deliv->>'est_min_days','est_max_days', v_deliv->>'est_max_days',
       'method', v_deliv->>'method','note','carrier estimate; not guaranteed'),
    'trust', jsonb_build_object('authenticity_state', p_decision->'product_trust'->>'gate',
       'supply_confidence', p_decision->>'supply_confidence',
       'disclaimers', jsonb_build_array('search interest and marketplace/ad presence are demand signals, not guarantees of sales')),
    'faq', jsonb_build_array('REQUIRES_GENERATION'),
    'cta', jsonb_build_object('label','REQUIRES_GENERATION','checkout_boundary','CHECKOUT_HANDLED_BY_DESTINATION_STORE'),
    'seo', jsonb_build_object('title', v_title,'meta_description','REQUIRES_GENERATION','keywords', p_context->'seo_keywords'),
    'provenance', jsonb_build_object('engine','pulse_page_model_v1','decision_classification', p_decision->>'classification',
       'note','deterministic scaffold; AI copy generation is a separate worker (REQUIRES_GENERATION markers)'),
    'claim_safety', jsonb_build_object('no_unverified_superlatives',true,'presence_not_sales',true,'winner_post_spend_only',true));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_build_tracking_identity(p_tenant uuid, p_cb_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts; v_tid text; v_dec text; v_ident jsonb; v_id uuid; v_utm jsonb;
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_campaign_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  v_tid := 'pt_' || replace(p_cb_campaign_id::text,'-','');
  v_utm := jsonb_build_object('source','pulse','medium','paid_social','campaign',v_tid);
  v_dec := public.fn_decorate_url(c.destination_url, v_tid, v_utm);
  v_ident := public.fn_conversion_identity(
      jsonb_build_object('classification','CAMPAIGN'),
      jsonb_build_object('user_id',p_tenant,'product_id',c.product_id),
      c.destination_url, NULL, c.destination_url)
    || jsonb_build_object('campaign',p_cb_campaign_id,'creative',(c.creative_selection->0->>'angle_id'),'pulse_tid',v_tid);
  INSERT INTO public.commerce_tracking_identities(tenant_id,pulse_tid,campaign_id,creative_id,product_id,opportunity_id,decision_id,destination_url,decorated_url,utm,identity)
  VALUES (p_tenant,v_tid,p_cb_campaign_id, nullif(c.creative_selection->0->>'angle_id','')::uuid, c.product_id, c.opportunity_id, c.decision_id, c.destination_url, v_dec, v_utm, v_ident)
  ON CONFLICT (tenant_id,pulse_tid) DO UPDATE SET decorated_url=EXCLUDED.decorated_url, identity=EXCLUDED.identity
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status','ok','tracking_identity_id',v_id,'pulse_tid',v_tid,'decorated_url',v_dec);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_candidate_pricing_economics(p_supplier jsonb, p_market_price numeric, p_display_currency text, p_ad_reserve numeric DEFAULT 15, p_variable_costs numeric DEFAULT 0, p_target_contribution_min numeric DEFAULT 15, p_target_contribution_max numeric DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_econ jsonb; v_landed numeric; v_contribution numeric; v_band text; v_required numeric;
  v_reserve numeric := coalesce(p_ad_reserve,15);
  v_var numeric := coalesce(p_variable_costs,0);
  v_cur text := upper(coalesce(p_display_currency,''));
BEGIN
  IF p_market_price IS NULL OR p_market_price <= 0 THEN
    RETURN jsonb_build_object('dimension','pricing','pricing_model','MARKET_LED','state','UNKNOWN',
      'known',false,'reason','no_market_price',
      'note','market-supported selling price is required; pricing is market-led, never cost-plus-markup');
  END IF;

  v_econ := public.fn_supplier_economics(p_supplier, p_market_price, p_display_currency);
  IF (v_econ->>'known')::boolean IS NOT TRUE THEN
    RETURN jsonb_build_object('dimension','pricing','pricing_model','MARKET_LED','state','UNKNOWN',
      'known',false,'reason', coalesce(v_econ->>'reason','economics_unknown'),
      'economics',v_econ,'note','landed economics unknown; cannot compute contribution (fail-closed)');
  END IF;

  v_landed := (v_econ->>'landed_cost_display')::numeric;
  v_contribution := round(p_market_price - v_landed - v_reserve - v_var, 2);
  v_required := round(v_landed + v_reserve + v_var + p_target_contribution_min, 2);

  v_band := CASE
    WHEN v_contribution >= p_target_contribution_max THEN 'STRONG'
    WHEN v_contribution >= p_target_contribution_min THEN 'MEETS_TARGET'
    WHEN v_contribution > 0 THEN 'THIN'
    ELSE 'UNVIABLE' END;

  RETURN jsonb_build_object(
    'dimension','pricing','pricing_model','MARKET_LED','state','OBSERVED','known',true,
    'display_currency', v_cur,
    'market_price', p_market_price,
    'landed_cost', v_landed,
    'ad_reserve', jsonb_build_object('amount',v_reserve,'currency',v_cur,'assumption',true,
        'source','FOUNDER_INITIAL_AD_RESERVE',
        'note','pre-launch advertising reserve assumption; replace with real CPA/CAC once campaign data exists'),
    'variable_costs', v_var,
    'projected_contribution', v_contribution,
    'target_contribution_min', p_target_contribution_min,
    'target_contribution_max', p_target_contribution_max,
    'contribution_band', v_band,
    'meets_target', (v_contribution >= p_target_contribution_min),
    'market_price_required_for_target', v_required,
    'economics_subscore', v_econ->'subscore',
    'market_price_integrity','NOT_INFLATED_ABOVE_MARKET',
    'suggested_action', CASE WHEN v_band='UNVIABLE' THEN 'AVOID'
                             WHEN v_band='THIN' THEN 'WATCH'
                             ELSE 'TEST_ELIGIBLE_ECONOMICS' END,
    'is_net_profit', false,
    'note', CASE
      WHEN v_band='UNVIABLE' THEN 'market price cannot cover landed + ad reserve + variable + viable contribution; downgrade/reject (never inflate above defensible market price)'
      WHEN v_band='THIN' THEN 'positive but below target contribution; WATCH unless market evidence supports a higher defensible price'
      ELSE 'projected contribution meets target on current assumptions; this is a target contribution, NOT guaranteed net profit' END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_candidate_research_priority(p_product_id uuid, p_market text DEFAULT 'GB'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_prod public.commerce_products%rowtype;
  v_med numeric; v_pmin numeric; v_pmax numeric; v_mkt_n int;
  v_cjpid text; v_cost numeric; v_ship numeric; v_cur text; v_fx jsonb; v_rate numeric;
  v_landed_disp numeric; v_contrib numeric; v_basis text; v_class text;
  v_ref_cpa numeric := 15;
  v_comm int; v_intent boolean; v_tier text;
BEGIN
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  SELECT count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY (value->>'price')::numeric),
         min((value->>'price')::numeric), max((value->>'price')::numeric)
    INTO v_mkt_n, v_med, v_pmin, v_pmax
    FROM public.commerce_signals
    WHERE product_id = p_product_id AND signal_type='MARKETPLACE_ACTIVITY'
      AND coalesce(value->>'market', v_mkt) = v_mkt
      AND (value->>'price') ~ '^[0-9]+(\.[0-9]+)?$' AND upper(coalesce(value->>'currency','GBP'))='GBP';

  SELECT count(DISTINCT coalesce(dedup_key,id::text)),
         bool_or(coalesce((value->'intent_indicators'->>'purchase_intent')::boolean,false))
    INTO v_comm, v_intent
    FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='COMMUNITY_ATTENTION';
  v_comm := coalesce(v_comm,0);

  v_cjpid := v_prod.extended->>'cj_source_product_id';
  IF v_cjpid IS NOT NULL THEN
    SELECT supplier_cost,
           nullif(btrim(supplier_enrichment->'freight'->v_mkt->'representative'->>'shipping_cost'),'')::numeric,
           upper(coalesce(nullif(btrim(cost_currency),''),'USD'))
      INTO v_cost, v_ship, v_cur
      FROM public.commerce_supplier_products WHERE source_product_id=v_cjpid;
  END IF;

  IF v_cost IS NOT NULL AND v_ship IS NOT NULL AND v_med IS NOT NULL THEN
    v_fx := public.get_fx_rate(v_cur,'GBP'); v_rate := nullif(v_fx->>'rate','')::numeric;
    IF v_rate IS NOT NULL AND coalesce((v_fx->>'stale')::boolean,true) = false THEN
      v_landed_disp := round((v_cost + v_ship) * v_rate, 2);
      v_contrib := round(v_med - v_landed_disp, 2);
      v_basis := 'real_economics';
    END IF;
  END IF;

  IF v_basis IS NULL THEN
    IF v_med IS NULL THEN v_class := 'HEADROOM_UNKNOWN'; v_basis := 'no_price_evidence';
    ELSE v_contrib := round(0.55 * v_med, 2); v_basis := 'price_ceiling_estimate'; END IF;
  END IF;

  IF v_class IS NULL THEN
    v_class := CASE WHEN v_contrib >= 25 THEN 'STRONG_POTENTIAL'
                    WHEN v_contrib >= 15 THEN 'POTENTIALLY_VIABLE'
                    ELSE 'LIKELY_THIN' END;
  END IF;

  v_tier := CASE
     WHEN v_class='STRONG_POTENTIAL' THEN 'HIGH'
     WHEN v_class='POTENTIALLY_VIABLE' AND (v_comm>=1 OR v_intent) THEN 'HIGH'
     WHEN v_class='POTENTIALLY_VIABLE' THEN 'MEDIUM'
     WHEN v_class='HEADROOM_UNKNOWN' AND (v_comm>=2 OR v_intent) THEN 'MEDIUM'
     WHEN v_class='HEADROOM_UNKNOWN' THEN 'LOW'
     ELSE 'LOW' END;

  RETURN jsonb_build_object(
    'scope','RESEARCH_PRIORITY_ONLY',
    'not','canonical_opportunity|economics|TEST|profitability_prediction',
    'product_id', p_product_id, 'market', v_mkt,
    'headroom_class', v_class, 'basis', v_basis,
    'observed_median_price_gbp', v_med, 'observed_price_min_gbp', v_pmin, 'observed_price_max_gbp', v_pmax,
    'marketplace_listing_sample', coalesce(v_mkt_n,0),
    'contribution_estimate_gbp', v_contrib, 'landed_cost_gbp', v_landed_disp, 'reference_cpa_gbp', v_ref_cpa,
    'community_signals', v_comm, 'community_purchase_intent', coalesce(v_intent,false),
    'research_priority', v_tier,
    'claim_safety','price != profit; marketplace listings != sales; attention != demand; research priority != TEST');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_canonical_product_decision(p_profile jsonb, p_product jsonb, p_supplier jsonb, p_reviews jsonb, p_auth_evidence jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_supply jsonb := public.fn_beta_supply_decision(p_product,p_supplier,p_reviews,p_auth_evidence,p_target_market,p_selling_price,p_display_currency);
  v_pt text := v_supply->'product_trust'->>'gate';
  v_conf text := v_supply->>'supply_confidence';
  v_exec text := v_supply->'supplier_execution'->>'supplier_execution_gate';
  v_del_ss numeric := nullif(v_supply->'supplier_execution'->'delivery'->>'subscore','')::numeric;
  v_avl_ss numeric := nullif(v_supply->'supplier_execution'->'availability'->>'subscore','')::numeric;
  v_econ_ss numeric := nullif(v_supply->'supplier_execution'->'economics'->>'subscore','')::numeric;
  v_sup_score numeric;
  -- profile category readers
  fsd jsonb := p_profile->'SEARCH_DEMAND'; fso jsonb := p_profile->'SOCIAL_ATTENTION';
  fco jsonb := p_profile->'COMMUNITY_ATTENTION'; fmk jsonb := p_profile->'MARKETPLACE_ACTIVITY';
  fad jsonb := p_profile->'ADVERTISING_ACTIVITY'; fcp jsonb := p_profile->'COMPETITOR_ACTIVITY';
  fst jsonb := p_profile->'COMPETITION_SATURATION';
  sv_state text; sv_score numeric; sv_conf text;
  ac_state text; ac_score numeric;
  v_dims jsonb; v_score jsonb; v_op numeric;
  cats int := 0; catlist text[] := '{}';
  bi_state text := coalesce(fsd->>'state','SOURCE_BLOCKED'); bi_score numeric := nullif(fsd->>'score','')::numeric;
  risk text := coalesce(fst->>'risk_level','UNKNOWN'); risk_sev text := coalesce(fst->>'severity','');
  score_ord int; supply_ord int; cat_ord int; sat_ord int; buyer_ord int; final_ord int;
  v_class text; v_rec text; v_reasons_for text[] := '{}'; v_reasons_against text[] := '{}'; v_next text[] := '{}';
  v_band jsonb;
BEGIN
  -- supplier dimension score from real execution subscores
  SELECT round(avg(x)) INTO v_sup_score FROM unnest(ARRAY[v_del_ss,v_avl_ss,v_econ_ss]) x WHERE x IS NOT NULL;

  -- social/viral merge (community + social); observed if either observed
  IF coalesce(fso->>'state','')='OBSERVED' OR coalesce(fco->>'state','')='OBSERVED' THEN
    sv_state := 'OBSERVED';
    SELECT round(avg(x)) INTO sv_score FROM unnest(ARRAY[
      CASE WHEN fso->>'state'='OBSERVED' THEN nullif(fso->>'score','')::numeric END,
      CASE WHEN fco->>'state'='OBSERVED' THEN nullif(fco->>'score','')::numeric END]) x WHERE x IS NOT NULL;
    sv_conf := CASE WHEN fso->>'state'='OBSERVED' AND fco->>'state'='OBSERVED' THEN 'corroborated' ELSE 'partial_single_channel' END;
  ELSE sv_state := coalesce(fco->>'state', fso->>'state','NOT_OBSERVED'); sv_score := NULL; sv_conf := 'none'; END IF;

  -- advertising/competitor merge
  IF coalesce(fad->>'state','')='OBSERVED' OR coalesce(fcp->>'state','')='OBSERVED' THEN
    ac_state := 'OBSERVED';
    SELECT round(avg(x)) INTO ac_score FROM unnest(ARRAY[nullif(fad->>'score','')::numeric, nullif(fcp->>'score','')::numeric]) x WHERE x IS NOT NULL;
  ELSE ac_state := coalesce(fad->>'state', fcp->>'state','SOURCE_BLOCKED'); ac_score := NULL; END IF;

  v_dims := jsonb_build_object(
    'search_buyer_intent', jsonb_build_object('state',bi_state,'score',bi_score,'confidence',fsd->>'confidence','blocked_reason',fsd->>'blocked_reason'),
    'social_viral', jsonb_build_object('state',sv_state,'score',sv_score,'confidence',sv_conf),
    'marketplace_validation', jsonb_build_object('state',coalesce(fmk->>'state','SOURCE_BLOCKED'),'score',nullif(fmk->>'score','')::numeric,'blocked_reason',fmk->>'blocked_reason'),
    'advertising_competitor', jsonb_build_object('state',ac_state,'score',ac_score,'blocked_reason',coalesce(fad->>'blocked_reason',fcp->>'blocked_reason')),
    'supplier_quality_economics', jsonb_build_object('state', CASE WHEN v_exec='SUPPLIER_EXECUTION_INSUFFICIENT' THEN 'INSUFFICIENT_EVIDENCE' ELSE 'OBSERVED' END,'score',v_sup_score,'confidence','real_cj'),
    'competition_saturation_gap', jsonb_build_object('state',coalesce(fst->>'state','NOT_OBSERVED'),'score',nullif(fst->>'score','')::numeric));

  v_score := public.fn_product_opportunity_score(v_dims);
  v_op := nullif(v_score->>'opportunity_score','')::numeric;

  -- independent evidence categories (dedup: ad+competitor=one, supply=one)
  IF fsd->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'SEARCH_DEMAND'); END IF;
  IF fso->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'SOCIAL_ATTENTION'); END IF;
  IF fco->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'COMMUNITY_ATTENTION'); END IF;
  IF fmk->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'MARKETPLACE_ACTIVITY'); END IF;
  IF ac_state='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'ADVERTISING_OR_COMPETITOR'); END IF;
  IF v_exec<>'SUPPLIER_EXECUTION_INSUFFICIENT' THEN cats:=cats+1; catlist:=array_append(catlist,'SUPPLY'); END IF;
  IF (v_supply->'product_trust'->'quality'->>'known')::boolean THEN cats:=cats+1; catlist:=array_append(catlist,'PRODUCT_QUALITY'); END IF;
  IF fst->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'COMPETITION_SATURATION'); END IF;

  -- ordinal ceilings
  v_band := public.fn_opportunity_band(v_op);
  score_ord := nullif(v_band->>'ordinal','')::int;
  supply_ord := CASE WHEN v_pt='PRODUCT_TRUST_BLOCKED' THEN 0 WHEN v_exec='SUPPLIER_EXECUTION_FAIL' THEN 0
                     WHEN v_exec='SUPPLIER_EXECUTION_INSUFFICIENT' THEN 1
                     WHEN v_conf='FULLY_VERIFIED' THEN 4
                     WHEN v_conf='BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED' THEN 3 ELSE 1 END;
  cat_ord := CASE WHEN cats>=3 THEN 4 WHEN cats=2 THEN 3 WHEN cats=1 THEN 1 ELSE 0 END;
  sat_ord := CASE WHEN risk='CONFIRMED_RISK' AND risk_sev='SEVERE' THEN 0 WHEN risk='CONFIRMED_RISK' THEN 1
                  WHEN risk='INFERRED_RISK' THEN 3 ELSE 5 END;
  buyer_ord := CASE WHEN bi_state='OBSERVED' AND coalesce(bi_score,0) < 75 THEN 3 ELSE 5 END;

  IF v_pt='PRODUCT_TRUST_BLOCKED' THEN
    v_class := 'AVOID'; v_rec := 'AVOID_PRODUCT_TRUST_BLOCKED';
    v_reasons_against := array_append(v_reasons_against,'authenticity_'||coalesce(v_supply->'product_trust'->'authenticity'->>'state','MISSING'));
  ELSIF v_exec='SUPPLIER_EXECUTION_FAIL' THEN
    v_class := 'AVOID'; v_rec := 'AVOID_SUPPLIER_EXECUTION_FAIL';
    v_reasons_against := array_append(v_reasons_against, array_to_string(ARRAY(SELECT jsonb_array_elements_text(v_supply->'supplier_execution'->'critical_failures')),','));
  ELSIF v_op IS NULL THEN
    v_class := 'INSUFFICIENT_EVIDENCE'; v_rec := 'GATHER_EVIDENCE';
    v_reasons_against := array_append(v_reasons_against,'no_observed_scoring_dimensions');
  ELSE
    final_ord := least(coalesce(score_ord,5), supply_ord, cat_ord, sat_ord, buyer_ord);
    v_class := CASE final_ord WHEN 0 THEN 'AVOID' WHEN 1 THEN 'WATCH' WHEN 2 THEN 'WATCH'
                              WHEN 3 THEN 'STRONG_TEST' WHEN 4 THEN 'HIGH_CONFIDENCE_TEST'
                              WHEN 5 THEN 'EXCEPTIONAL_TEST_CANDIDATE' END;
    v_rec := CASE WHEN final_ord>=3 THEN 'TEST' WHEN final_ord IN (1,2) THEN 'WATCH' ELSE 'AVOID' END;
    -- explanation of what capped the class
    IF supply_ord < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'supply_confidence_cap_'||v_conf); END IF;
    IF cat_ord < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'insufficient_independent_categories('||cats||')'); END IF;
    IF sat_ord < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'competition_'||risk); END IF;
    IF buyer_ord < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'buyer_intent_below_threshold'); END IF;
  END IF;

  -- reasons_for (observed strengths)
  IF v_exec='SUPPLIER_EXECUTION_PASS' THEN v_reasons_for := array_append(v_reasons_for,'supplier_execution_pass_real_delivery_stock_economics'); END IF;
  IF v_pt IN ('PRODUCT_TRUST_PASS','PRODUCT_TRUST_ACCEPTABLE') THEN v_reasons_for := array_append(v_reasons_for,'product_trust_'||v_pt); END IF;
  IF fco->>'state'='OBSERVED' THEN v_reasons_for := array_append(v_reasons_for,'real_community_attention_evidence'); END IF;

  -- next evidence needed (from blocked/unknown)
  IF bi_state<>'OBSERVED' THEN v_next := array_append(v_next,'search_buyer_intent('||bi_state||')'); END IF;
  IF coalesce(fmk->>'state','')<>'OBSERVED' THEN v_next := array_append(v_next,'marketplace('||coalesce(fmk->>'state','SOURCE_BLOCKED')||')'); END IF;
  IF ac_state<>'OBSERVED' THEN v_next := array_append(v_next,'advertising_competitor('||ac_state||')'); END IF;
  IF v_conf<>'FULLY_VERIFIED' THEN v_next := array_append(v_next,'supplier_reliability_for_full_verification'); END IF;

  RETURN jsonb_build_object(
    'target_market', upper(coalesce(p_target_market,'UNKNOWN')),
    'opportunity_score', v_op,
    'classification', v_class,
    'recommendation', v_rec,
    'score_band', v_band->>'band',
    'evidence_completeness', v_score->>'evidence_completeness',
    'independent_evidence_categories', cats,
    'independent_category_list', to_jsonb(catlist),
    'dimension_scores', v_score->'dimensions',
    'supply_confidence', v_conf,
    'product_trust', v_supply->'product_trust',
    'supplier_execution', v_supply->'supplier_execution',
    'buyer_intent', jsonb_build_object('state',bi_state,'score',bi_score,'note','Google Keyword Planner blocked -> not fabricated'),
    'viral_potential', jsonb_build_object(
       'model','velocity30/creator_spread20/visual20/novelty15/cross_platform15',
       'state', CASE WHEN sv_state='OBSERVED' THEN 'PARTIAL' ELSE 'INSUFFICIENT' END,
       'observed_components', CASE WHEN fco->>'state'='OBSERVED' THEN jsonb_build_array('creator_community_spread') ELSE '[]'::jsonb END,
       'unavailable_components', jsonb_build_array('social_velocity','visual_demonstration','cross_platform_corroboration'),
       'note','missing components NOT normalized into certainty'),
    'competition_risk', jsonb_build_object('risk_level',risk,'severity',risk_sev,'state',coalesce(fst->>'state','NOT_OBSERVED')),
    'blocked_sources', v_score->'blocked_sources',
    'unknowns', v_score->'not_observed_dimensions',
    'reasons_for', to_jsonb(v_reasons_for),
    'reasons_against', to_jsonb(v_reasons_against),
    'next_evidence_needed', to_jsonb(v_next),
    'lifecycle_note','pre-spend classification; WINNER is post-spend/post-conversion only and is never emitted here',
    'provenance', jsonb_build_object('scoring','canonical_100pt_v1','supply','GLOBAL_SUPPLY+TENANT_ECONOMICS','product_trust','PRODUCT_LEVEL'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_canonical_product_decision_v2(p_profile jsonb, p_product jsonb, p_supplier jsonb, p_reviews jsonb, p_auth_evidence jsonb, p_market_advantage jsonb, p_fees jsonb, p_cx_signals jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_supply jsonb := public.fn_beta_supply_decision(p_product,p_supplier,p_reviews,p_auth_evidence,p_target_market,p_selling_price,p_display_currency);
  v_pt text := v_supply->'product_trust'->>'gate';
  v_conf_supply text := v_supply->>'supply_confidence';
  v_exec text := v_supply->'supplier_execution'->>'supplier_execution_gate';
  v_del jsonb := v_supply->'supplier_execution'->'delivery';
  v_quality jsonb := v_supply->'product_trust'->'quality';
  v_econ_exec jsonb := v_supply->'supplier_execution'->'economics';
  v_econ jsonb; v_dims jsonb; v_opp jsonb; v_ma jsonb; v_cx jsonb; v_timing jsonb; v_conf jsonb;
  v_op numeric; v_maScore numeric; v_cxScore numeric; v_evConf numeric;
  fsd jsonb := p_profile->'SEARCH_DEMAND'; fso jsonb := p_profile->'SOCIAL_ATTENTION'; fco jsonb := p_profile->'COMMUNITY_ATTENTION';
  fmk jsonb := p_profile->'MARKETPLACE_ACTIVITY'; fad jsonb := p_profile->'ADVERTISING_ACTIVITY'; fcp jsonb := p_profile->'COMPETITOR_ACTIVITY';
  fst jsonb := p_profile->'COMPETITION_SATURATION'; ftr jsonb := p_profile->'TREND';
  sv_state text; sv_score numeric; ac_state text; ac_score numeric; sup_dim_score numeric; econ_dim_score numeric;
  cats int := 0; catlist text[] := '{}'; corroborated boolean; unknown_crit int := 0;
  risk text := coalesce(fst->>'risk_level','UNKNOWN'); risk_sev text := upper(coalesce(fst->>'severity',''));
  bi_state text := coalesce(fsd->>'state','SOURCE_BLOCKED'); bi_score numeric := nullif(fsd->>'score','')::numeric;
  g1 int; g2 int; g3 int; g4 int; g5 int; g6 int; g7 int; ma_ord int; score_ord int; buyer_ord int; final_ord int;
  v_band jsonb; v_class text; v_rec text; v_action text; v_action_why text; v_ev_next text[] := '{}';
  v_reasons_for text[] := '{}'; v_reasons_against text[] := '{}';
  v_econ_state text; v_cx_gate text; comply_ok boolean;
BEGIN
  v_econ := public.fn_economics_breakeven(p_selling_price, nullif(v_econ_exec->>'landed_cost_original','')::numeric,
              v_econ_exec->>'landed_cost_currency', p_display_currency, p_fees);
  v_econ_state := coalesce(v_econ->>'economics_state','UNKNOWN');

  IF coalesce(fso->>'state','')='OBSERVED' OR coalesce(fco->>'state','')='OBSERVED' THEN sv_state:='OBSERVED';
     SELECT round(avg(x)) INTO sv_score FROM unnest(ARRAY[CASE WHEN fso->>'state'='OBSERVED' THEN nullif(fso->>'score','')::numeric END,
        CASE WHEN fco->>'state'='OBSERVED' THEN nullif(fco->>'score','')::numeric END]) x WHERE x IS NOT NULL;
  ELSE sv_state := coalesce(fco->>'state',fso->>'state','NOT_OBSERVED'); END IF;
  IF coalesce(fad->>'state','')='OBSERVED' OR coalesce(fcp->>'state','')='OBSERVED' THEN ac_state:='OBSERVED';
     SELECT round(avg(x)) INTO ac_score FROM unnest(ARRAY[nullif(fad->>'score','')::numeric,nullif(fcp->>'score','')::numeric]) x WHERE x IS NOT NULL;
  ELSE ac_state := coalesce(fad->>'state',fcp->>'state','SOURCE_BLOCKED'); END IF;

  sup_dim_score := CASE WHEN v_exec='SUPPLIER_EXECUTION_INSUFFICIENT' THEN NULL
    WHEN v_exec='SUPPLIER_EXECUTION_FAIL' THEN 10 ELSE (
      SELECT round(avg(x)) FROM unnest(ARRAY[nullif(v_del->>'subscore','')::numeric,
        nullif(v_supply->'supplier_execution'->'availability'->>'subscore','')::numeric]) x WHERE x IS NOT NULL) END;
  econ_dim_score := CASE v_econ_state WHEN 'VIABLE' THEN 85 WHEN 'THIN' THEN 45 WHEN 'NEGATIVE' THEN 10 ELSE NULL END;

  v_dims := jsonb_build_object(
    'buyer_intent_demand', jsonb_build_object('state',bi_state,'score',bi_score,'blocked_reason',fsd->>'blocked_reason'),
    'trend_velocity_timing', jsonb_build_object('state',coalesce(ftr->>'state','NOT_OBSERVED'),'score',nullif(ftr->>'score','')::numeric),
    'social_viral', jsonb_build_object('state',sv_state,'score',sv_score),
    'marketplace_validation', jsonb_build_object('state',coalesce(fmk->>'state','SOURCE_BLOCKED'),'score',nullif(fmk->>'score','')::numeric,'blocked_reason',fmk->>'blocked_reason'),
    'advertising_validation', jsonb_build_object('state',ac_state,'score',ac_score,'blocked_reason',coalesce(fad->>'blocked_reason',fcp->>'blocked_reason')),
    'competition_saturation_gap', jsonb_build_object('state',coalesce(fst->>'state','NOT_OBSERVED'),'score',nullif(fst->>'score','')::numeric),
    'economics_profit', jsonb_build_object('state',CASE WHEN econ_dim_score IS NULL THEN 'INSUFFICIENT_EVIDENCE' ELSE 'OBSERVED' END,'score',econ_dim_score),
    'supply_delivery', jsonb_build_object('state',CASE WHEN sup_dim_score IS NULL THEN 'INSUFFICIENT_EVIDENCE' ELSE 'OBSERVED' END,'score',sup_dim_score));

  v_opp := public.fn_opportunity_score_v2(v_dims); v_op := nullif(v_opp->>'score','')::numeric;
  v_ma := public.fn_market_advantage_score(coalesce(p_market_advantage,'{}'::jsonb)); v_maScore := nullif(v_ma->>'score','')::numeric;
  v_timing := public.fn_market_timing(ftr);
  v_cx := public.fn_customer_experience(v_quality, v_del, v_conf_supply, coalesce(p_cx_signals,'{}'::jsonb));
  v_cxScore := nullif(v_cx->>'customer_experience_score','')::numeric; v_cx_gate := v_cx->>'cx_gate';

  IF fsd->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'SEARCH_DEMAND'); END IF;
  IF ftr->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'TREND'); END IF;
  IF fso->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'SOCIAL_ATTENTION'); END IF;
  IF fco->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'COMMUNITY_ATTENTION'); END IF;
  IF fmk->>'state'='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'MARKETPLACE_ACTIVITY'); END IF;
  IF ac_state='OBSERVED' THEN cats:=cats+1; catlist:=array_append(catlist,'ADVERTISING_OR_COMPETITOR'); END IF;
  IF v_exec<>'SUPPLIER_EXECUTION_INSUFFICIENT' THEN cats:=cats+1; catlist:=array_append(catlist,'SUPPLY'); END IF;
  IF (v_quality->>'known')::boolean THEN cats:=cats+1; catlist:=array_append(catlist,'PRODUCT_QUALITY'); END IF;

  corroborated := (cats >= 3);
  unknown_crit := (CASE WHEN bi_state='OBSERVED' THEN 0 ELSE 1 END)
                + (CASE WHEN econ_dim_score IS NOT NULL THEN 0 ELSE 1 END)
                + (CASE WHEN sup_dim_score IS NOT NULL THEN 0 ELSE 1 END)
                + (CASE WHEN (v_quality->>'known')::boolean THEN 0 ELSE 1 END);
  v_conf := public.fn_evidence_confidence(nullif(v_opp->>'completeness','')::numeric, cats, corroborated,
              coalesce((p_profile->'_meta'->>'conflicts')::boolean,false), upper(coalesce(p_profile->'_meta'->>'freshness','FRESH')), unknown_crit);
  v_evConf := (v_conf->>'evidence_confidence')::numeric;

  comply_ok := (v_pt <> 'PRODUCT_TRUST_BLOCKED');
  g1 := CASE WHEN v_pt='PRODUCT_TRUST_BLOCKED' THEN 0 WHEN v_pt='PRODUCT_TRUST_WATCH' THEN 1 ELSE 5 END;
  g2 := CASE WHEN v_exec='SUPPLIER_EXECUTION_FAIL' THEN 0 WHEN v_exec='SUPPLIER_EXECUTION_INSUFFICIENT' THEN 1
             WHEN v_conf_supply='FULLY_VERIFIED' THEN 4 WHEN v_conf_supply='BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED' THEN 3 ELSE 1 END;
  g3 := CASE v_econ_state WHEN 'NEGATIVE' THEN 0 WHEN 'THIN' THEN 2 WHEN 'VIABLE' THEN 5 ELSE 3 END;
  g4 := CASE v_cx_gate WHEN 'CX_BLOCKED' THEN 0 WHEN 'CX_WATCH' THEN 1 WHEN 'CX_INSUFFICIENT' THEN 3 WHEN 'CX_ACCEPTABLE' THEN 4 WHEN 'CX_PASS' THEN 5 END;
  g5 := CASE WHEN risk='CONFIRMED_RISK' AND risk_sev='SEVERE' THEN 0 WHEN risk='CONFIRMED_RISK' THEN 1 WHEN risk='INFERRED_RISK' THEN 3 ELSE 5 END;
  g6 := CASE WHEN NOT comply_ok THEN 0 ELSE 5 END;
  g7 := CASE WHEN v_evConf>=60 THEN 5 WHEN v_evConf>=45 THEN 4 WHEN v_evConf>=30 THEN 3 ELSE 1 END;
  IF cats < 1 THEN g7 := 0; END IF;
  -- market-advantage ceiling: no identifiable entry edge cannot earn top confidence (unknown != negative -> caps, not blocks)
  ma_ord := CASE WHEN v_maScore IS NULL THEN 3 WHEN v_maScore>=60 THEN 5 WHEN v_maScore>=45 THEN 4 WHEN v_maScore>=30 THEN 3 ELSE 2 END;
  v_band := public.fn_opportunity_band(v_op); score_ord := nullif(v_band->>'ordinal','')::int;
  buyer_ord := CASE WHEN bi_state='OBSERVED' AND coalesce(bi_score,0)<75 THEN 3 ELSE 5 END;

  IF v_pt='PRODUCT_TRUST_BLOCKED' THEN v_class:='AVOID'; v_rec:='AVOID_PRODUCT_TRUST_BLOCKED';
  ELSIF v_exec='SUPPLIER_EXECUTION_FAIL' THEN v_class:='AVOID'; v_rec:='AVOID_SUPPLIER_EXECUTION_FAIL';
  ELSIF v_op IS NULL THEN v_class:='INSUFFICIENT_EVIDENCE'; v_rec:='GATHER_EVIDENCE';
  ELSE
    final_ord := LEAST(coalesce(score_ord,5),g1,g2,g3,g4,g5,g6,g7,ma_ord,buyer_ord);
    v_class := CASE final_ord WHEN 0 THEN 'AVOID' WHEN 1 THEN 'WATCH' WHEN 2 THEN 'WATCH'
                              WHEN 3 THEN 'STRONG_TEST' WHEN 4 THEN 'HIGH_CONFIDENCE_TEST' ELSE 'EXCEPTIONAL_TEST_CANDIDATE' END;
    v_rec := CASE WHEN final_ord>=3 THEN 'TEST' WHEN final_ord IN (1,2) THEN 'WATCH' ELSE 'AVOID' END;
  END IF;

  IF v_cx_gate IN ('CX_BLOCKED','CX_WATCH') THEN v_reasons_against := array_append(v_reasons_against,'customer_experience_'||v_cx_gate); END IF;
  IF v_econ_state IN ('NEGATIVE','THIN') THEN v_reasons_against := array_append(v_reasons_against,'economics_'||v_econ_state); END IF;
  IF g2 < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'supply_'||v_conf_supply); END IF;
  IF g5 < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'competition_'||risk); END IF;
  IF g7 < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'evidence_confidence_'||(v_conf->>'level')); END IF;
  IF ma_ord < coalesce(score_ord,5) THEN v_reasons_against := array_append(v_reasons_against,'weak_or_unknown_market_advantage'); END IF;
  IF buyer_ord<5 THEN v_reasons_against := array_append(v_reasons_against,'buyer_intent_below_75'); END IF;
  IF v_exec='SUPPLIER_EXECUTION_PASS' THEN v_reasons_for := array_append(v_reasons_for,'real_supply_execution_pass'); END IF;
  IF v_econ_state='VIABLE' THEN v_reasons_for := array_append(v_reasons_for,'viable_unit_economics'); END IF;
  IF v_cx_gate IN ('CX_PASS','CX_ACCEPTABLE') THEN v_reasons_for := array_append(v_reasons_for,'acceptable_customer_experience'); END IF;

  v_action := CASE
    WHEN v_pt='PRODUCT_TRUST_BLOCKED' THEN 'AVOID_PRODUCT'
    WHEN v_exec='SUPPLIER_EXECUTION_FAIL' AND (v_del->>'critical')::boolean THEN 'CHANGE_MARKET'
    WHEN v_econ_state='NEGATIVE' THEN 'CHANGE_PRICE'
    WHEN v_exec='SUPPLIER_EXECUTION_FAIL' THEN 'CHANGE_SUPPLIER'
    WHEN v_cx_gate='CX_BLOCKED' THEN 'AVOID_PRODUCT'
    WHEN v_cx_gate='CX_WATCH' THEN 'IMPROVE_OFFER'
    WHEN v_econ_state='THIN' THEN 'CHANGE_PRICE'
    WHEN risk='CONFIRMED_RISK' THEN 'CHANGE_MARKET'
    WHEN v_op IS NULL OR cats<3 OR v_evConf<45 OR v_maScore IS NULL THEN 'GET_MORE_EVIDENCE'
    WHEN buyer_ord<5 THEN 'WATCH_TREND'
    WHEN final_ord>=3 THEN 'RUN_BOUNDED_TEST'
    WHEN final_ord IN (1,2) THEN 'WATCH_TREND'
    ELSE 'AVOID_PRODUCT' END;
  v_action_why := 'driven by binding constraint: '||coalesce(array_to_string(v_reasons_against,', '),'evidence_sufficient_for_next_step');
  IF bi_state<>'OBSERVED' THEN v_ev_next := array_append(v_ev_next,'buyer_intent('||bi_state||')'); END IF;
  IF coalesce(fmk->>'state','')<>'OBSERVED' THEN v_ev_next := array_append(v_ev_next,'marketplace('||coalesce(fmk->>'state','SOURCE_BLOCKED')||')'); END IF;
  IF ac_state<>'OBSERVED' THEN v_ev_next := array_append(v_ev_next,'advertising_creative('||ac_state||')'); END IF;
  IF v_maScore IS NULL THEN v_ev_next := array_append(v_ev_next,'market_advantage_evidence'); END IF;
  IF v_conf_supply<>'FULLY_VERIFIED' THEN v_ev_next := array_append(v_ev_next,'supplier_reliability_for_full_verification'); END IF;
  IF NOT (v_quality->>'known')::boolean THEN v_ev_next := array_append(v_ev_next,'product_reviews_for_quality_confirmation'); END IF;

  RETURN jsonb_build_object(
    'target_market', upper(coalesce(p_target_market,'UNKNOWN')),
    'opportunity_score', v_op, 'market_advantage_score', v_maScore, 'customer_experience_score', v_cxScore, 'evidence_confidence', v_evConf,
    'classification', v_class, 'recommendation', v_rec, 'market_timing', v_timing->>'market_timing',
    'dimension_scores', v_opp->'dimensions',
    'product_trust', v_supply->'product_trust', 'supplier_execution', v_supply->'supplier_execution',
    'supply_confidence', v_conf_supply, 'economics', v_econ, 'break_even_cpa', v_econ->>'break_even_cpa',
    'buyer_intent', jsonb_build_object('state',bi_state,'score',bi_score),
    'viral_potential', jsonb_build_object('state',CASE WHEN sv_state='OBSERVED' THEN 'PARTIAL' ELSE 'INSUFFICIENT' END),
    'marketplace_validation', jsonb_build_object('state',coalesce(fmk->>'state','SOURCE_BLOCKED')),
    'advertising_validation', jsonb_build_object('state',ac_state),
    'competition_risk', jsonb_build_object('risk_level',risk,'severity',risk_sev),
    'market_advantage', v_ma->'dimensions', 'customer_experience', v_cx->'dimensions', 'cx_gate', v_cx_gate,
    'hard_gates', jsonb_build_object('product_trust',g1,'supplier_execution',g2,'economics',g3,'customer_experience',g4,'saturation',g5,'compliance_ip',g6,'evidence_sufficiency',g7,'market_advantage_ceiling',ma_ord),
    'independent_evidence_categories', cats, 'independent_category_list', to_jsonb(catlist), 'evidence_completeness', v_opp->>'completeness',
    'unknowns', v_opp->'unknown_dimensions', 'blocked_sources', v_opp->'blocked_sources',
    'conflicting_evidence', coalesce((p_profile->'_meta'->>'conflicts')::boolean,false),
    'reasons_for', to_jsonb(v_reasons_for), 'reasons_against', to_jsonb(v_reasons_against),
    'recommended_next_action', v_action, 'why_this_action', v_action_why, 'evidence_needed_next', to_jsonb(v_ev_next),
    'prediction_snapshot', jsonb_build_object('snapshot_version','wps_v2','predicted_opportunity',v_op,'predicted_market_advantage',v_maScore,
       'predicted_customer_experience',v_cxScore,'predicted_evidence_confidence',v_evConf,'predicted_classification',v_class,
       'predicted_market_timing',v_timing->>'market_timing','break_even_cpa',v_econ->>'break_even_cpa',
       'predicted_economics_state',v_econ_state,'predicted_risks',to_jsonb(v_reasons_against),'note','for later Performance Learning; no self-modifying weights'),
    'lifecycle_note','pre-spend; WINNER only via fn_winner_evaluation on real post-launch data',
    'provenance', jsonb_build_object('engine','wps_v2','supply','GLOBAL_SUPPLY+TENANT_ECONOMICS','product_trust','PRODUCT_LEVEL'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_category_market_state(p_category text, p_market text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE avs text[];
BEGIN
  SELECT array_agg(a) INTO avs FROM (
    SELECT (public.fn_source_availability(source,p_category,p_market)->>'availability') AS a
    FROM (SELECT DISTINCT source FROM public.provider_capability_registry WHERE evidence_category=p_category) s
  ) x WHERE a IS NOT NULL;
  IF avs IS NULL THEN RETURN 'UNKNOWN'; END IF;
  IF 'AVAILABLE' = ANY(avs) THEN RETURN 'AVAILABLE'; END IF;
  IF 'PARTIAL' = ANY(avs) THEN RETURN 'PARTIAL'; END IF;
  IF 'TEMPORARILY_UNAVAILABLE' = ANY(avs) THEN RETURN 'TEMPORARILY_UNAVAILABLE'; END IF;
  IF 'SOURCE_BLOCKED' = ANY(avs) THEN RETURN 'SOURCE_BLOCKED'; END IF;
  IF 'SOURCE_UNSUPPORTED' = ANY(avs) THEN RETURN 'SOURCE_UNSUPPORTED'; END IF;
  RETURN 'UNKNOWN';
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_approve(p_cb_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts%rowtype;
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF c.status='INCOMPLETE' THEN RETURN jsonb_build_object('status','blocked_incomplete','missing',c.completeness->'missing'); END IF;
  IF c.campaign_target_market IS NULL THEN RETURN jsonb_build_object('status','blocked_no_target_market'); END IF;
  IF c.destination_state <> 'VALID' THEN RETURN jsonb_build_object('status','blocked_destination','destination_state',c.destination_state); END IF;
  IF jsonb_array_length(coalesce(c.creative_selection,'[]'::jsonb))=0 THEN RETURN jsonb_build_object('status','blocked_no_creative'); END IF;
  UPDATE public.campaign_builder_drafts
    SET status='APPROVED', cb_approved_fingerprint=cb_fingerprint, cb_approved_at=now(), updated_at=now()
    WHERE id=p_cb_id;
  RETURN jsonb_build_object('status','APPROVED','campaign_id',p_cb_id,'approved_fingerprint',c.cb_fingerprint,
    'spend_authorization',0,'activation_authorization',false,
    'note','CAMPAIGN CONFIG approval only — distinct from creative/media approval, spend and activation authorities');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_build_campaign(p_tenant uuid, p_brief_id uuid, p_target_market text, p_asset_ids jsonb, p_destination text, p_budget jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  b public.ad_studio_briefs%rowtype; cfg public.meta_platform_config%rowtype;
  v_handoff jsonb; v_creatives jsonb; v_offers jsonb; v_gate jsonb; v_primary jsonb;
  v_dest_state text; v_nonexec boolean := false; v_mkt text := nullif(btrim(coalesce(p_target_market,'')),'');
  v_budget jsonb; v_daily numeric; v_life numeric; v_bcur text; v_endtime text; v_btype text;
  v_disp text; v_mktcur text; v_exec text; v_placements jsonb; v_canon jsonb; v_meta jsonb; v_tt jsonb;
  v_comp jsonb; v_status text; v_fp text; v_id uuid; v_missing text[] := '{}';
BEGIN
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=p_brief_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO cfg FROM public.meta_platform_config WHERE id=1;

  v_handoff := public.fn_ad_studio_campaign_handoff(p_brief_id, p_tenant);
  IF coalesce(v_handoff->>'status','') <> 'ok' THEN
    RETURN jsonb_build_object('status','no_approved_creative','handoff',v_handoff);
  END IF;
  v_creatives := v_handoff->'handoff'->'approved_creatives';
  v_offers := v_handoff->'handoff'->'authorized_offers';
  v_primary := v_creatives->0;

  v_gate := public.fn_media_campaign_safety_gate(p_tenant, coalesce(p_asset_ids,'[]'::jsonb));
  IF (v_gate->>'gate') <> 'PASS' THEN v_nonexec := true; END IF;
  IF jsonb_array_length(coalesce(v_gate->'accepted','[]'::jsonb))=0 THEN v_nonexec := true; END IF;

  v_dest_state := public.fn_cb_validate_destination(p_destination);

  v_disp := 'GBP';
  v_mktcur := upper(coalesce(nullif(btrim(coalesce(b.market_currency,'')),''),'EUR'));
  v_exec := upper(coalesce(cfg.currency,''));

  v_budget := coalesce(p_budget,'{}'::jsonb);
  v_btype := coalesce(v_budget->>'type','lifetime');
  v_daily := nullif(v_budget->>'daily_minor','')::numeric;
  v_life  := nullif(v_budget->>'lifetime_minor','')::numeric;
  v_bcur  := upper(coalesce(nullif(v_budget->>'currency',''), v_mktcur));
  v_endtime := v_budget->>'end_time';
  IF v_daily IS NULL AND v_life IS NULL THEN v_daily := 1000; v_life := 2500; END IF;

  v_placements := jsonb_build_array('FB_FEED','IG_FEED','IG_STORY_REEL');

  v_canon := jsonb_build_object(
    'objective','OUTCOME_SALES','platform','META','status','DRAFT',
    'campaign_target_market', v_mkt,
    'audience', coalesce(b.audience,'{}'::jsonb),
    'placements', v_placements,
    'creative', jsonb_build_object('angle_id',v_primary->>'angle_id','headline',v_primary->>'headline',
        'hook',v_primary->>'hook','primary_copy',v_primary->>'primary_copy','cta',v_primary->>'cta',
        'variants',v_primary->'variants'),
    'offer', v_offers,
    'destination_url', p_destination,
    'budget', jsonb_build_object('type',v_btype,'daily_minor',v_daily,'lifetime_minor',v_life,'currency',v_bcur,
        'end_time',v_endtime,'recommended',true,'authorized',false,
        'hard_ceiling_mechanism','ADSET_LIFETIME_BUDGET_PLUS_END_TIME',
        'hard_ceiling_note','Campaign spend_cap min is 100 USD; test envelope enforced via ad-set lifetime budget + fixed end time and/or account controls, not campaign spend_cap'),
    'schedule', jsonb_build_object('start',coalesce(v_budget->>'start',to_jsonb(now())#>>'{}'),'end',v_endtime),
    'currency', jsonb_build_object('display',v_disp,'market',v_mktcur,'budget',v_bcur,'execution',v_exec),
    'optimization_intent','CONVERSIONS','tracking_state','NOT_CONFIGURED',
    'provenance', jsonb_build_object('brief_id',b.id,'opportunity_id',b.opportunity_id,'decision_id',b.decision_id,'product_id',b.product_id),
    'authorization', jsonb_build_object('creative_approval',true,'campaign_approval',false,'spend_authorization',0,'activation','NOT_AUTHORIZED'));

  v_meta := jsonb_build_object('currency',v_bcur,'account_ref',cfg.account_id,'page_ref',cfg.page_id,
    'campaigns', jsonb_build_array(jsonb_build_object(
      'objective','OUTCOME_SALES','status','PAUSED','spend_cap',NULL,
      'ad_sets', jsonb_build_array(jsonb_build_object(
        'status','PAUSED','daily_budget',v_daily,'lifetime_budget',v_life,'end_time',v_endtime,
        'optimization_goal','OFFSITE_CONVERSIONS',
        'targeting', jsonb_build_object('geo_locations', jsonb_build_object('countries', jsonb_build_array(coalesce(v_mkt,'')))))),
      'ads', jsonb_build_array(jsonb_build_object('creative', jsonb_build_object(
        'link',p_destination,'title',v_primary->>'headline','body',v_primary->>'primary_copy',
        'call_to_action', v_primary->>'cta'))))),
    'preview_only',true);

  v_tt := jsonb_build_object('platform','TIKTOK','execution_adapter','NOT_OPERATIONAL','preview_only',true,
    'note','provider-independent TikTok preview; live TikTok execution NOT claimed',
    'placement','TIKTOK_FEED','aspect_ratio','9:16','hook',v_primary->>'hook','cta',v_primary->>'cta');

  IF v_mkt IS NULL THEN v_missing := array_append(v_missing,'campaign_target_market'); END IF;
  IF jsonb_array_length(coalesce(v_creatives,'[]'::jsonb))=0 THEN v_missing := array_append(v_missing,'approved_creative'); END IF;
  IF v_dest_state <> 'VALID' THEN v_missing := array_append(v_missing,'destination:'||v_dest_state); END IF;
  IF v_daily IS NULL AND v_life IS NULL THEN v_missing := array_append(v_missing,'budget'); END IF;
  IF v_exec='' THEN v_missing := array_append(v_missing,'execution_currency'); END IF;
  v_comp := jsonb_build_object('missing', to_jsonb(v_missing),'media_gate', v_gate->>'gate', 'non_executable_fixture', v_nonexec);
  v_status := CASE WHEN array_length(v_missing,1) IS NULL THEN 'READY_FOR_REVIEW' ELSE 'INCOMPLETE' END;

  v_fp := public.fn_cb_fingerprint(v_canon);

  INSERT INTO public.campaign_builder_drafts(tenant_id,brief_id,product_id,opportunity_id,decision_id,platform,objective,
    selling_market,opportunity_market,campaign_target_market,market_currency,audience,placements,creative_selection,offer,
    destination_url,destination_state,budget,schedule,currency_display,currency_market,currency_execution,fx_snapshot,
    optimization_intent,tracking_state,media_asset_ids,media_gate,canonical_campaign,meta_payload_preview,tiktok_preview,
    completeness,non_executable_fixture,status,cb_fingerprint,spend_authorization,activation_authorization,provenance)
  VALUES (p_tenant,b.id,b.product_id,b.opportunity_id,b.decision_id,'META','OUTCOME_SALES',
    b.market,b.market,v_mkt,v_mktcur,coalesce(b.audience,'{}'::jsonb),v_placements,v_creatives,v_offers,
    p_destination,v_dest_state,v_canon->'budget',v_canon->'schedule',v_disp,v_mktcur,v_exec,'{}'::jsonb,
    'CONVERSIONS','NOT_CONFIGURED',coalesce(p_asset_ids,'[]'::jsonb),v_gate,v_canon,v_meta,v_tt,
    v_comp,v_nonexec,v_status,v_fp,0,false,v_canon->'provenance')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','ok','campaign_id',v_id,'draft_status',v_status,'missing',to_jsonb(v_missing),
    'non_executable_fixture',v_nonexec,'destination_state',v_dest_state,'media_gate',v_gate->>'gate');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_edit(p_cb_id uuid, p_tenant uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts%rowtype; v_canon jsonb; v_fp text; v_inval boolean := false; v_fx boolean := false; v_dest text;
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  v_canon := c.canonical_campaign;
  IF p_patch ? 'campaign_target_market' THEN v_canon := jsonb_set(v_canon,'{campaign_target_market}', to_jsonb(p_patch->>'campaign_target_market')); END IF;
  IF p_patch ? 'destination_url' THEN v_dest := p_patch->>'destination_url'; v_canon := jsonb_set(v_canon,'{destination_url}', to_jsonb(v_dest)); END IF;
  IF p_patch ? 'budget_currency' THEN v_canon := jsonb_set(v_canon,'{budget,currency}', to_jsonb(p_patch->>'budget_currency')); v_fx := true; END IF;
  IF p_patch ? 'daily_minor' THEN v_canon := jsonb_set(v_canon,'{budget,daily_minor}', to_jsonb((p_patch->>'daily_minor')::numeric)); v_fx := true; END IF;
  IF p_patch ? 'headline' THEN v_canon := jsonb_set(v_canon,'{creative,headline}', to_jsonb(p_patch->>'headline')); END IF;

  v_fp := public.fn_cb_fingerprint(v_canon);
  IF c.status='APPROVED' AND v_fp <> coalesce(c.cb_approved_fingerprint,'') THEN v_inval := true; END IF;

  UPDATE public.campaign_builder_drafts SET
    canonical_campaign=v_canon,
    campaign_target_market=coalesce(p_patch->>'campaign_target_market',campaign_target_market),
    destination_url=coalesce(v_dest,destination_url),
    destination_state=CASE WHEN v_dest IS NOT NULL THEN public.fn_cb_validate_destination(v_dest) ELSE destination_state END,
    budget=v_canon->'budget',
    cb_fingerprint=v_fp,
    status=CASE WHEN v_inval THEN 'READY_FOR_REVIEW' ELSE status END,
    cb_approved_fingerprint=CASE WHEN v_inval THEN NULL ELSE cb_approved_fingerprint END,
    cb_approved_at=CASE WHEN v_inval THEN NULL ELSE cb_approved_at END,
    updated_at=now()
  WHERE id=p_cb_id;

  RETURN jsonb_build_object('status','ok','fingerprint',v_fp,'approval_invalidated',v_inval,'fx_sensitive_change',v_fx,
    'revalidation_required', (v_inval OR v_fx),
    'new_status',(SELECT status FROM public.campaign_builder_drafts WHERE id=p_cb_id));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_execution_gate(p_cb_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts%rowtype; v_auth public.marketing_spend_authority%rowtype; v_reasons text[] := '{}';
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF c.status<>'APPROVED' THEN v_reasons := array_append(v_reasons,'campaign_not_approved'); END IF;
  IF c.cb_approved_fingerprint IS NULL OR c.cb_approved_fingerprint<>c.cb_fingerprint THEN v_reasons := array_append(v_reasons,'approval_stale'); END IF;
  IF c.campaign_target_market IS NULL THEN v_reasons := array_append(v_reasons,'no_target_market'); END IF;
  IF c.destination_state<>'VALID' THEN v_reasons := array_append(v_reasons,'destination_'||c.destination_state); END IF;
  IF (c.media_gate->>'gate')<>'PASS' OR c.non_executable_fixture THEN v_reasons := array_append(v_reasons,'media_not_launch_safe'); END IF;
  IF jsonb_array_length(coalesce(c.creative_selection,'[]'::jsonb))=0 THEN v_reasons := array_append(v_reasons,'no_creative'); END IF;

  SELECT * INTO v_auth FROM public.marketing_spend_authority
    WHERE tenant_id=p_tenant AND platform='META' AND status='ACTIVE' AND executable=true
      AND authorized_total>0 AND (end_at IS NULL OR end_at>now()) LIMIT 1;
  IF v_auth.id IS NULL THEN v_reasons := array_append(v_reasons,'no_executable_spend_authority'); END IF;
  IF NOT c.activation_authorization THEN v_reasons := array_append(v_reasons,'activation_not_authorized'); END IF;
  IF c.spend_authorization<=0 THEN v_reasons := array_append(v_reasons,'spend_authorization_zero'); END IF;

  RETURN jsonb_build_object(
    'execution_result', CASE WHEN array_length(v_reasons,1) IS NULL THEN 'EXECUTABLE' ELSE 'NOT_EXECUTABLE_YET' END,
    'reasons', to_jsonb(v_reasons),
    'spend_authorization', c.spend_authorization, 'activation_authorization', c.activation_authorization,
    'meta_write_called', false, 'execution_created', false,
    'note','Preview phase: spend authority 0 and activation false by design -> NOT_EXECUTABLE_YET is the correct result');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_fingerprint(c jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT md5(concat_ws('|',
    coalesce(c->>'objective',''), coalesce(c->>'campaign_target_market',''),
    coalesce(c->'audience'->>'segment',''),
    coalesce(c->'creative'->>'headline',''), coalesce(c->'creative'->>'primary_copy',''),
    coalesce(c->'creative'->>'cta',''), coalesce(c->>'destination_url',''),
    coalesce((c->'offer')::text,''),
    coalesce(c->'budget'->>'type',''), coalesce(c->'budget'->>'daily_minor',''),
    coalesce(c->'budget'->>'lifetime_minor',''), coalesce(c->'budget'->>'currency',''),
    coalesce(c->'budget'->>'end_time',''),
    coalesce((c->'placements')::text,''), coalesce(c->>'tracking_state',''),
    coalesce(c->'currency'->>'execution','')));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_promote_to_executor(p_actor uuid, p_tenant uuid, p_cb_campaign_id uuid, p_authority_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_act jsonb; v_is_auth boolean;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  v_act := public.fn_request_activation(p_actor,p_tenant,p_cb_campaign_id,p_authority_id,'promote-'||p_cb_campaign_id::text);
  IF v_act->>'status' <> 'ACTIVATION_AUTHORIZED' THEN
    RETURN jsonb_build_object('status','NOT_PROMOTED','reason','activation_gate_failed','gate',v_act);
  END IF;
  -- Real promotion requires an auth.users tenant (marketing_campaign_drafts FK). Fixtures never reach here.
  SELECT EXISTS(SELECT 1 FROM auth.users WHERE id=p_tenant) INTO v_is_auth;
  IF NOT v_is_auth THEN RETURN jsonb_build_object('status','NOT_PROMOTED','reason','non_auth_tenant_cannot_persist_executor_draft'); END IF;
  RETURN jsonb_build_object('status','PROMOTION_READY',
    'note','would create marketing_campaign_drafts CREATED_PAUSED via existing approve/get_executable_meta_draft path; not executed in this unit');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_cb_validate_destination(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_url IS NULL OR btrim(p_url)='' THEN 'INVALID_MISSING'
    WHEN lower(p_url) !~ '^https?://[a-z0-9.-]+\.[a-z]{2,}(/|$)' THEN 'INVALID_MALFORMED'
    WHEN lower(p_url) ~ '(example\.(test|com|org)|localhost|127\.0\.0\.1|placeholder|your-?domain|todo|changeme)' THEN 'INVALID_PLACEHOLDER'
    ELSE 'VALID' END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_cj_normalize_stock(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE cj numeric:=0; fac numeric:=0; tot numeric:=0; n int:=0; w jsonb; whs jsonb:='[]'::jsonb;
  st text; reason text;
BEGIN
  IF p_data IS NULL OR jsonb_typeof(p_data)<>'array' OR jsonb_array_length(p_data)=0 THEN
    RETURN jsonb_build_object('stock_state','UNKNOWN','reason','NO_WAREHOUSE_ROWS',
      'cj_inventory',0,'factory_inventory',0,'total_inventory',0,'warehouses','[]'::jsonb,
      'source','CJ_STOCK_QUERY_BY_VID');
  END IF;
  FOR w IN SELECT * FROM jsonb_array_elements(p_data) LOOP
    n := n+1;
    cj  := cj  + coalesce((w->>'cjInventoryNum')::numeric,0);
    fac := fac + coalesce((w->>'factoryInventoryNum')::numeric,0);
    tot := tot + coalesce((w->>'totalInventoryNum')::numeric, (w->>'storageNum')::numeric, 0);
    whs := whs || jsonb_build_array(jsonb_build_object(
      'warehouse', w->>'areaEn', 'country', w->>'countryCode', 'vid', w->>'vid',
      'cj_inventory', coalesce((w->>'cjInventoryNum')::numeric,0),
      'factory_inventory', coalesce((w->>'factoryInventoryNum')::numeric,0),
      'total_inventory', coalesce((w->>'totalInventoryNum')::numeric,(w->>'storageNum')::numeric,0)));
  END LOOP;
  IF cj > 0 THEN st:='IN_STOCK'; reason:='CJ_WAREHOUSE_READY_TO_SHIP';
  ELSIF fac > 0 THEN st:='OUT_OF_STOCK'; reason:='ZERO_CJ_WAREHOUSE_FACTORY_REPLENISHABLE_ONLY';
  ELSE st:='OUT_OF_STOCK'; reason:='VERIFIED_ZERO_ALL_LOCATIONS'; END IF;
  RETURN jsonb_build_object('stock_state',st,'reason',reason,
    'cj_inventory',cj,'factory_inventory',fac,'total_inventory',tot,
    'warehouses',whs,'source','CJ_STOCK_QUERY_BY_VID');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_classify_ad_creative_pattern(p_ad_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_ad_text IS NULL OR btrim(p_ad_text)='' THEN 'unknown'
    WHEN p_ad_text ~* '(before|after|transformation|results in)' THEN 'before_after'
    WHEN p_ad_text ~* '(tired of|struggle|finally|say goodbye|problem|solution|fix your)' THEN 'problem_solution'
    WHEN p_ad_text ~* '(today only|limited|hurry|last chance|selling out|while stocks|ends soon|don''t miss)' THEN 'urgency'
    WHEN p_ad_text ~* '(bundle|set of|[0-9]+[ -]?pack|kit|combo)' THEN 'bundle'
    WHEN p_ad_text ~* '(\$|% ?off|sale|discount|deal|save [0-9])' THEN 'price_led'
    WHEN p_ad_text ~* '(how to|tips|guide|learn|step by step)' THEN 'educational'
    WHEN p_ad_text ~* '(vs\.?|versus|better than|compare)' THEN 'comparison'
    WHEN p_ad_text ~* '(watch|see how|demo|in action)' THEN 'demonstration'
    WHEN p_ad_text ~* '(i love|my favorite|honest review|obsessed|game changer)' THEN 'ugc_testimonial'
    ELSE 'feature_led' END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_classify_ad_product_match(p_product_name text, p_ad_text text, p_page_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  prod text; hay text; ptoks text[]; htoks text[]; shared int; overlap numeric; m text;
  accessory_kw text[] := ARRAY['case','cover','mount','stand','bag','strap','adapter','replacement','parts','part',
    'charger','cable','holder','sleeve','protector','tripod','gimbal','refill','filter','filters','battery','batteries','accessory','accessories'];
BEGIN
  prod := btrim(regexp_replace(lower(coalesce(p_product_name,'')), '[^a-z0-9]+',' ','g'));
  hay  := btrim(regexp_replace(lower(coalesce(p_ad_text,'')||' '||coalesce(p_page_name,'')), '[^a-z0-9]+',' ','g'));
  IF prod='' OR hay='' THEN RETURN jsonb_build_object('match','AMBIGUOUS','basis','empty'); END IF;
  -- verbatim product phrase present -> definitely the product
  IF position(prod in hay) > 0 THEN RETURN jsonb_build_object('match','EXACT_OR_CLOSE_MATCH','basis','verbatim_product'); END IF;
  ptoks := string_to_array(prod,' ');
  htoks := string_to_array(hay,' ');
  -- accessory-dominant ad (accessory term present, not part of product name) -> ACCESSORY
  IF EXISTS (SELECT 1 FROM unnest(htoks) t WHERE t = ANY(accessory_kw) AND t <> ALL(ptoks)) THEN
    RETURN jsonb_build_object('match','ACCESSORY','basis','accessory_term');
  END IF;
  SELECT count(*) INTO shared FROM (SELECT unnest(ptoks) INTERSECT SELECT unnest(htoks)) s;
  overlap := shared::numeric / greatest(array_length(ptoks,1),1);
  m := CASE WHEN overlap >= 0.66 THEN 'EXACT_OR_CLOSE_MATCH'
            WHEN overlap >= 0.40 THEN 'RELATED'
            WHEN overlap >= 0.25 THEN 'AMBIGUOUS'
            ELSE 'IRRELEVANT' END;
  RETURN jsonb_build_object('match', m, 'basis','token_overlap', 'overlap', round(overlap,2));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_classify_search_query_relevance(p_product_name text, p_query text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  prod text; q text; ptoks text[]; qtoks text[]; overlap numeric; shared int; has_mod boolean;
  accessory_kw text[] := ARRAY['case','cover','mount','stand','bag','strap','adapter','charger','cable','holder','sleeve','skin','protector','compatible','accessory','accessories','battery','batteries'];
  info_kw text[] := ARRAY['how','what','why','when','where','guide','tutorial','recipe','recipes','meaning','definition','review','reviews','tips','diy','instructions','instruction','manual','versus','vs'];
  -- SERVICE = strong local/service evidence only. NOTE: 'repair' is intentionally NOT here.
  service_kw text[] := ARRAY['service','services','technician','technicians','professional','professionals','company','companies','quote','quotes','booking','installer','installation','handyman','contractor','repairman','upholsterer','near','nearby','rental','hire','salary','jobs'];
  -- physical-product modifiers: presence keeps product intent even with 'repair' in the query
  modifier_kw text[] := ARRAY['patch','patches','kit','kits','tape','tool','tools','marker','markers','compound','device','machine','replacement','part','parts','pack','set','sheet','sheets','sticker','stickers','paste','glue','filler','pen','pens','cream','solution','spray'];
BEGIN
  prod := btrim(regexp_replace(lower(coalesce(p_product_name,'')), '[^a-z0-9]+',' ','g'));
  q    := btrim(regexp_replace(lower(coalesce(p_query,'')),        '[^a-z0-9]+',' ','g'));
  IF prod = '' OR q = '' THEN RETURN jsonb_build_object('relevance','AMBIGUOUS','reason','empty'); END IF;
  IF q = prod THEN RETURN jsonb_build_object('relevance','DIRECT_PRODUCT','reason','exact'); END IF;
  ptoks := string_to_array(prod,' ');
  qtoks := string_to_array(q,' ');
  has_mod := EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(modifier_kw));

  -- SERVICE intent: strong single tokens OR service phrases (repair shop/store, near me, book ... repair)
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(service_kw))
     OR q LIKE '%repair shop%' OR q LIKE '%repair store%' OR q LIKE '%near me%'
     OR (q LIKE 'book %' AND q LIKE '%repair%') THEN
    RETURN jsonb_build_object('relevance','SERVICE','reason','service_or_local_intent');
  END IF;

  -- INFORMATIONAL
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(info_kw)) THEN
    RETURN jsonb_build_object('relevance','INFORMATIONAL','reason','informational_intent');
  END IF;

  -- ACCESSORY noun present but not part of the product's own name
  IF EXISTS (SELECT 1 FROM unnest(qtoks) t WHERE t = ANY(accessory_kw) AND t <> ALL(ptoks)) THEN
    RETURN jsonb_build_object('relevance','ACCESSORY','reason','accessory_term');
  END IF;

  SELECT count(*) INTO shared FROM (SELECT unnest(ptoks) INTERSECT SELECT unnest(qtoks)) s;
  overlap := shared::numeric / greatest(array_length(ptoks,1),1);

  IF overlap >= 0.75 THEN
    RETURN jsonb_build_object('relevance','DIRECT_PRODUCT','reason','strong_token_overlap','overlap',round(overlap,2),'has_modifier',has_mod);
  ELSIF (has_mod AND overlap >= 0.5) OR overlap >= 0.6 THEN
    RETURN jsonb_build_object('relevance','CLOSE_VARIANT','reason','product_variant','overlap',round(overlap,2),'has_modifier',has_mod);
  ELSIF overlap >= 0.34 THEN
    RETURN jsonb_build_object('relevance','AMBIGUOUS','reason','partial_overlap','overlap',round(overlap,2),'has_modifier',has_mod);
  ELSE
    RETURN jsonb_build_object('relevance','IRRELEVANT','reason','low_overlap','overlap',round(overlap,2),'has_modifier',has_mod);
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_classify_seasonality(p_monthly jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_mean numeric; v_n int; v_first3 numeric; v_last3 numeric; v_peaks int[]; v_cls text;
BEGIN
  IF jsonb_typeof(p_monthly) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('class','unsupported','inferred',true,'reason','no_history');
  END IF;
  SELECT count(*), avg(v) INTO v_n, v_mean FROM (
    SELECT (e->>'volume')::numeric v FROM jsonb_array_elements(p_monthly) e WHERE (e->>'volume') ~ '^[0-9]+(\.[0-9]+)?$') s;
  IF coalesce(v_n,0) < 6 THEN
    RETURN jsonb_build_object('class','insufficient_history','inferred',true,'months',coalesce(v_n,0));
  END IF;
  SELECT array_agg(DISTINCT (e->>'month')::int) INTO v_peaks
    FROM jsonb_array_elements(p_monthly) e
   WHERE (e->>'volume') ~ '^[0-9]+(\.[0-9]+)?$' AND (e->>'volume')::numeric >= 1.4 * v_mean
     AND (e->>'month') ~ '^[0-9]+$';
  SELECT avg(v) INTO v_first3 FROM (
    SELECT (e->>'volume')::numeric v, coalesce((e->>'year')::int,0)*12+coalesce((e->>'month')::int,0) ord
    FROM jsonb_array_elements(p_monthly) e WHERE (e->>'volume') ~ '^[0-9]+(\.[0-9]+)?$' ORDER BY ord LIMIT 3) a;
  SELECT avg(v) INTO v_last3 FROM (
    SELECT (e->>'volume')::numeric v, coalesce((e->>'year')::int,0)*12+coalesce((e->>'month')::int,0) ord
    FROM jsonb_array_elements(p_monthly) e WHERE (e->>'volume') ~ '^[0-9]+(\.[0-9]+)?$' ORDER BY ord DESC LIMIT 3) a;

  IF v_peaks IS NOT NULL AND v_peaks <@ ARRAY[11,12,1] THEN v_cls := 'holiday_concentrated';
  ELSIF v_peaks IS NOT NULL AND v_peaks <@ ARRAY[6,7,8] THEN v_cls := 'summer_concentrated';
  ELSIF v_last3 > v_first3 * 1.2 THEN v_cls := 'rising_seasonal';
  ELSIF v_last3 < v_first3 * 0.8 THEN v_cls := 'declining';
  ELSE v_cls := 'stable';
  END IF;

  RETURN jsonb_build_object('class',v_cls,'inferred',true,'months',v_n,
    'mean',round(v_mean,1),'peak_months',to_jsonb(coalesce(v_peaks,ARRAY[]::int[])));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_commerce_destination_router(p_decision jsonb, p_destination text, p_context jsonb, p_store_connection jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_rec text := p_decision->>'recommendation'; v_class text := p_decision->>'classification';
        v_dest text := upper(coalesce(p_destination,'')); v_page jsonb; v_state text; v_provider text; v_landing text;
BEGIN
  IF v_rec <> 'TEST' THEN
    RETURN jsonb_build_object('status','DENIED','commerce_handoff_allowed',false,'classification',v_class,'destination',v_dest,
      'reason','commerce execution requires a TEST decision; current='||coalesce(v_class,'UNKNOWN'),
      'note','WATCH/AVOID never route to store build or existing-store handoff');
  END IF;
  IF v_dest NOT IN ('EXISTING_STORE','PULSE_STORE') THEN
    RETURN jsonb_build_object('status','DESTINATION_REQUIRED','reason','choose EXISTING_STORE or PULSE_STORE','commerce_handoff_allowed',false);
  END IF;
  v_page := public.fn_build_product_page_model(p_decision, p_context);

  IF v_dest='EXISTING_STORE' THEN
    v_state := upper(coalesce(p_store_connection->>'connection_state',''));
    v_provider := upper(coalesce(p_store_connection->>'provider',''));
    IF v_state <> 'CONNECTED' THEN
      RETURN jsonb_build_object('status','BLOCKED_STORE_NOT_CONNECTED','destination','EXISTING_STORE','commerce_handoff_allowed',false,
        'connection_state', coalesce(nullif(v_state,''),'NOT_CONNECTED'),'required_action','CONNECT_STORE',
        'reason','connect an existing store before product handoff');
    END IF;
    v_landing := coalesce(p_store_connection->>'store_domain','store')||'/products/DRAFT';
    RETURN jsonb_build_object('status','ROUTED','commerce_handoff_allowed',true,'destination','EXISTING_STORE',
      'route','EXISTING_STORE_PRODUCT_HANDOFF','operation','CREATE_NEW_PRODUCT_PAGE','draft_first',true,'auto_overwrite',false,
      'store_provider',v_provider,'store_connection_id',p_store_connection->>'id','product_page_model',v_page,
      'existing_store_product_handoff', jsonb_build_object('store_connection_id',p_store_connection->>'id','provider',v_provider,
        'product_id',p_context->>'product_id','market',p_decision->>'target_market','decision',v_class,
        'opportunity_score',p_decision->>'opportunity_score','evidence_confidence',p_decision->>'evidence_confidence',
        'selling_price',p_context->>'selling_price','currency',p_context->>'display_currency',
        'landed_cost',p_decision->'economics'->>'landed_cost_display','delivery_evidence',p_decision->'supplier_execution'->'delivery',
        'supplier_reference',p_context->'supplier_reference','buyer_intent',p_context->'buyer_intent',
        'operation','CREATE_NEW_PRODUCT_PAGE','publish_mode','DRAFT_FIRST_REVIEW_REQUIRED','provenance',p_context->'provenance'),
      'ad_studio_handoff', public.fn_ad_studio_handoff(p_decision,p_context,v_landing,v_provider),
      'conversion_identity', public.fn_conversion_identity(p_decision,p_context,'EXISTING_STORE',p_store_connection->>'id',v_landing),
      'review_required',true,'note','DRAFT_FIRST; never auto-overwrites an existing merchant product');
  ELSE
    v_landing := 'pulse-store/DRAFT';
    RETURN jsonb_build_object('status','ROUTED','commerce_handoff_allowed',true,'destination','PULSE_STORE',
      'route','PULSE_STORE_BUILDER_HANDOFF','operation','BUILD_PULSE_ONE_PRODUCT_STORE','draft_first',true,'requires_existing_url',false,
      'product_page_model',v_page,
      'pulse_store_handoff', jsonb_build_object('project_state','DRAFT','product_id',p_context->>'product_id','market',p_decision->>'target_market',
        'decision',v_class,'page_model_included',true,'publish_mode','EXPLICIT_PUBLICATION_LATER','no_url_required',true),
      'ad_studio_handoff', public.fn_ad_studio_handoff(p_decision,p_context,v_landing,'PULSE_STORE'),
      'conversion_identity', public.fn_conversion_identity(p_decision,p_context,'PULSE_STORE',NULL,v_landing),
      'review_required',true,'note','Pulse Store DRAFT allowed; explicit publication is a later step');
  END IF;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_commerce_product_identity(p_product_url text, p_platform_id text, p_title text, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_url text := nullif(btrim(coalesce(p_product_url,'')),'');
  v_hostpath text;
  v_pid text := nullif(btrim(coalesce(p_platform_id,'')),'');
  v_title text;
  v_src text := lower(nullif(btrim(coalesce(p_source,'')),''));
BEGIN
  -- Strongest: canonical product URL (lowercased, scheme/query/fragment/trailing-slash/www stripped).
  IF v_url IS NOT NULL THEN
    v_hostpath := lower(v_url);
    v_hostpath := regexp_replace(v_hostpath, '^https?://', '');
    v_hostpath := regexp_replace(v_hostpath, '[#?].*$', '');
    v_hostpath := regexp_replace(v_hostpath, '/+$', '');
    v_hostpath := regexp_replace(v_hostpath, '^www\.', '');
    IF v_hostpath <> '' THEN
      RETURN jsonb_build_object('identity', 'url:' || v_hostpath, 'basis', 'canonical_url');
    END IF;
  END IF;
  -- Next: source-specific platform identifier.
  IF v_pid IS NOT NULL THEN
    RETURN jsonb_build_object('identity', 'pid:' || coalesce(v_src,'') || ':' || lower(v_pid), 'basis', 'platform_id');
  END IF;
  -- Fallback: deterministic normalized name (+ source to reduce cross-store collisions).
  v_title := lower(regexp_replace(btrim(coalesce(p_title,'')), '\s+', ' ', 'g'));
  IF v_title <> '' THEN
    RETURN jsonb_build_object('identity', 'name:' || coalesce(v_src,'') || ':' || v_title, 'basis', 'normalized_name');
  END IF;
  RETURN NULL; -- no usable identity → caller must not fabricate one
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_commerce_supplier_products_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN NEW.updated_at := now(); RETURN NEW; END $function$
;

CREATE OR REPLACE FUNCTION public.fn_compliance_pregate(p_product jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_hay text := ' '||lower(coalesce(p_product->>'title','')||' '||coalesce(p_product->>'title_original','')||' '
              ||coalesce(p_product->>'name','')||' '||coalesce(p_product->>'category','')||' '
              ||coalesce(p_product->>'product_type','')||' '||coalesce(p_product->>'description',''))||' ';
  -- word-boundary regex alternations (avoid substring false positives e.g. pill vs pillow, ems vs items)
  re_restricted text := '\y(supplement|pills?|capsule|gummies?|probiotic|collagen powder|protein powder|tincture|cbd|hemp oil|melatonin|creatine|nootropic|ingestible|edible|pepper spray|stun gun|taser|switchblade|butterfly knife|machete|crossbow|firearm|ammunition|brass knuckle|vape|vaping|e-liquid|nicotine|cigarette|tobacco|cannabis|kratom|poppers|pesticide|fireworks|prescription|medical-grade)\y';
  re_elevated text := '\y(therapy|therapeutic|tens|ems|muscle stimulator|infrared|red light|led therapy|clinically|dermatologist|acne treatment|pain relief|posture corrector|blood pressure|oximeter|thermometer|nebuli[sz]er|ecg|photon|microcurrent|microneedle|derma roller|derma pen|ipl|laser|uv light|ozone|high frequency wand|space heater|electric blanket|power bank|lithium|18650|e-bike|hoverboard|mains powered|baby|infant|newborn|crib|cot|car seat|pacifier|teether|toddler|respirator|n95|ffp2|ffp3|safety helmet|hard hat|safety harness|bulletproof|stab vest)\y';
  benign_cat text[] := ARRAY['home','garden','storage','kitchen','pet','office','cleaning','organizer','organiser',
    'outdoor','bathroom','stationery','apparel','clothing','textile','accessories','decor','homeware','travel',
    'bedding','lighting','electronics','photo frame','picture frame'];
  v_cat text := lower(coalesce(p_product->>'category','')||' '||coalesce(p_product->>'product_type',''));
  v_m text[]; v_reason text;
BEGIN
  IF btrim(v_hay) = '' THEN
    RETURN jsonb_build_object('risk_class','UNKNOWN','confidence','LOW','risk_reasons',jsonb_build_array('no_product_text'),
      'required_evidence',jsonb_build_array('product_identity'),'research_allowed',true,'supplier_validation_allowed',true,
      'store_allowed',false,'advertising_allowed',false,'claim_restrictions',jsonb_build_array(),
      'scope','RESEARCH_RISK_PREGATE_ONLY','not','legal_opinion|certification|declaration_of_compliance_or_safety',
      'provenance',jsonb_build_object('method','deterministic_wordboundary','source','product_metadata'));
  END IF;

  v_m := regexp_match(v_hay, re_restricted);
  IF v_m IS NOT NULL THEN
    RETURN jsonb_build_object('risk_class','RESTRICTED_OR_UNSUITABLE','confidence','HIGH',
      'risk_reasons',jsonb_build_array('restricted:'||v_m[1]),
      'required_evidence',jsonb_build_array('excluded_from_founder_dropshipping_beta_pending_policy_review'),
      'research_allowed',false,'supplier_validation_allowed',false,'store_allowed',false,'advertising_allowed',false,
      'claim_restrictions',jsonb_build_array('category_restricted_for_this_tournament'),
      'scope','RESEARCH_RISK_PREGATE_ONLY','not','legal_opinion|certification|declaration_of_compliance_or_safety',
      'provenance',jsonb_build_object('method','deterministic_wordboundary','source','product_metadata','note','risk pre-screen; not a legality determination'));
  END IF;

  v_m := regexp_match(v_hay, re_elevated);
  IF v_m IS NOT NULL THEN
    RETURN jsonb_build_object('risk_class','ELEVATED_EVIDENCE_REQUIRED','confidence','MEDIUM',
      'risk_reasons',jsonb_build_array('elevated:'||v_m[1]),
      'required_evidence',jsonb_build_array('product_safety_evidence','applicable_conformity_or_certification_evidence','claim_substantiation_if_health_related','intended_use_and_configuration'),
      'research_allowed',true,'supplier_validation_allowed',true,'store_allowed',false,'advertising_allowed',false,
      'claim_restrictions',jsonb_build_array('no_medical_or_therapeutic_claims_without_substantiation','no_cure_treat_heal_disease_claims','no_clinically_proven_or_regulator_approved_claims_without_evidence','cosmetic_or_appearance_positioning_only_where_generally_permissible'),
      'scope','RESEARCH_RISK_PREGATE_ONLY','not','legal_opinion|certification|declaration_of_compliance_or_safety',
      'provenance',jsonb_build_object('method','deterministic_wordboundary','source','product_metadata','note','elevated risk; TEST/store/advertising fail closed until required critical evidence verified'));
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(benign_cat) c WHERE v_cat LIKE '%'||c||'%' OR v_hay LIKE '%'||c||'%') THEN
    RETURN jsonb_build_object('risk_class','LOW_REGULATORY_RISK','confidence','MEDIUM',
      'risk_reasons',jsonb_build_array('ordinary_commodity_category_no_elevated_or_restricted_signal'),
      'required_evidence',jsonb_build_array(),'research_allowed',true,'supplier_validation_allowed',true,
      'store_allowed',true,'advertising_allowed',true,'claim_restrictions',jsonb_build_array('avoid_unsubstantiated_performance_claims'),
      'scope','RESEARCH_RISK_PREGATE_ONLY','not','legal_opinion|certification|declaration_of_compliance_or_safety',
      'provenance',jsonb_build_object('method','deterministic_wordboundary','source','product_metadata'));
  END IF;

  RETURN jsonb_build_object('risk_class','UNKNOWN','confidence','LOW',
    'risk_reasons',jsonb_build_array('insufficient_category_signal'),'required_evidence',jsonb_build_array('product_category_and_characteristics'),
    'research_allowed',true,'supplier_validation_allowed',true,'store_allowed',false,'advertising_allowed',false,
    'claim_restrictions',jsonb_build_array('no_unsubstantiated_claims'),
    'scope','RESEARCH_RISK_PREGATE_ONLY','not','legal_opinion|certification|declaration_of_compliance_or_safety',
    'provenance',jsonb_build_object('method','deterministic_wordboundary','source','product_metadata','note','category signal insufficient; cheap research may continue but spend/store/ads fail closed'));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_conversion_identity(p_decision jsonb, p_context jsonb, p_destination text, p_store_ref text, p_landing text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object('identity_version','pulse_attr_v1',
    'tenant', p_context->>'user_id','product', p_context->>'product_id','decision', p_decision->>'classification',
    'store_destination', p_destination,'store_or_project_id', p_store_ref,'landing_page', p_landing,
    'creative', NULL,'campaign', NULL,'ad', NULL,'session', NULL,'conversion_event', NULL,
    'note','common attribution skeleton; normalizes Shopify/Pulse/Woo purchases into one Performance model later (not implemented here)');
$function$
;

CREATE OR REPLACE FUNCTION public.fn_conversion_ledger_summary(p_tenant uuid, p_provider text DEFAULT 'META'::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'tenant_id', p_tenant,
    'provider', p_provider,
    'by_state', COALESCE((
      SELECT jsonb_object_agg(state, c)
      FROM (SELECT state, count(*) c FROM public.conversion_dispatch_ledger
            WHERE tenant_id = p_tenant AND provider = p_provider GROUP BY state) s), '{}'::jsonb),
    'accepted', (SELECT count(*) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED'),
    'accepted_non_test', (SELECT count(*) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED' AND is_test = false),
    'last_accepted_at', (SELECT max(last_attempt_at) FROM public.conversion_dispatch_ledger
                 WHERE tenant_id = p_tenant AND provider = p_provider AND state = 'ACCEPTED')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.fn_country_evaluation_state(p_tenant uuid, p_product_id uuid, p_country text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE u record; has_eval boolean;
BEGIN
  SELECT * INTO u FROM public.ecommerce_market_universe WHERE country_code=p_country;
  SELECT EXISTS(SELECT 1 FROM public.product_market_evaluations e
     WHERE e.product_id=p_product_id AND e.country_code=p_country AND e.tenant_id=p_tenant) INTO has_eval;
  IF u.country_code IS NULL THEN
    RETURN jsonb_build_object('country',p_country,'state','UNSUPPORTED','reason','country not in ecommerce market universe');
  ELSIF has_eval THEN
    RETURN jsonb_build_object('country',p_country,'state','EVALUATED','universe_status',u.status,'action','read fn_own_product_country_explorer for full intelligence');
  ELSIF u.status='ELIGIBLE' THEN
    RETURN jsonb_build_object('country',p_country,'state','ANALYSIS_REQUIRED','universe_status',u.status,
      'action','run Product x Country deep validation pipeline for this market, then persist','note','missing evidence is NOT low saturation and NOT favorable');
  ELSE
    RETURN jsonb_build_object('country',p_country,'state',u.status,'universe_status',u.status,
      'reason','insufficient legitimate source coverage to evaluate this market','note','missing evidence is never interpreted as favorable');
  END IF;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_create_pulse_store_draft(p_user_id uuid, p_decision jsonb, p_context jsonb, p_source_kind text DEFAULT 'REAL'::text, p_product_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_rec text := p_decision->>'recommendation'; v_class text := p_decision->>'classification';
  v_page jsonb; v_page_id uuid; v_proj_id uuid; v_mkt text := upper(coalesce(p_decision->>'target_market',''));
  v_landed_orig numeric; v_landed_cur text; v_econ_state text; v_history jsonb := jsonb_build_array('DRAFT','GENERATING','READY_FOR_REVIEW'); v_slug text;
BEGIN
  IF v_rec <> 'TEST' THEN
    RETURN jsonb_build_object('status','DENIED','commerce_handoff_allowed',false,'classification',v_class,
      'reason','Pulse Store generation requires a TEST decision; current='||coalesce(v_class,'UNKNOWN'),'created',false);
  END IF;
  v_page := public.fn_generate_page_copy(p_decision, p_context);
  v_landed_orig := nullif(p_decision->'supplier_execution'->'economics'->>'landed_cost_original','')::numeric;
  v_landed_cur := p_decision->'supplier_execution'->'economics'->>'landed_cost_currency';
  v_econ_state := p_decision->'economics'->>'economics_state';

  INSERT INTO public.commerce_product_pages(user_id,product_id,market,destination,decision_classification,page_model,status,
     source_kind,product_ref,selling_price,display_currency,source_currency,landed_cost_display,economics_state,claim_safety,provenance)
  VALUES (p_user_id, p_product_id, v_mkt, 'PULSE_STORE', v_class, v_page, 'READY_FOR_REVIEW',
     p_source_kind, jsonb_build_object('title',p_context->>'product_title','positioning',p_context->>'positioning',
        'supplier_reference',p_context->'supplier_reference','is_fixture',(p_source_kind='FIXTURE')),
     nullif(p_context->>'selling_price','')::numeric, p_context->>'display_currency', v_landed_cur,
     nullif(p_decision->'economics'->>'landed_cost_display','')::numeric, v_econ_state, v_page->'claim_safety',
     jsonb_build_object('engine','pulse_store_renderer_v1','state_history',v_history,'source_kind',p_source_kind,
        'landed_cost_original',v_landed_orig,'note', CASE WHEN p_source_kind='FIXTURE' THEN 'DETERMINISTIC TEST FIXTURE - not real customer intelligence' ELSE 'real' END))
  RETURNING id INTO v_page_id;

  v_slug := 'draft-'||left(replace(v_page_id::text,'-',''),10);
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,public_route,settings,source_kind)
  VALUES (p_user_id, v_page_id, 'READY_FOR_REVIEW', v_slug, NULL,
     jsonb_build_object('destination','PULSE_STORE','no_url_required',true,'state_history',v_history,'preview_noindex',true), p_source_kind)
  RETURNING id INTO v_proj_id;

  RETURN jsonb_build_object('status','ok','commerce_handoff_allowed',true,'classification',v_class,'created',true,
    'store_project_id',v_proj_id,'product_page_id',v_page_id,'project_state','READY_FOR_REVIEW','state_history',v_history,
    'source_kind',p_source_kind,'market',v_mkt,'slug',v_slug,'page_model',v_page,
    'ad_studio_handoff', public.fn_ad_studio_handoff(p_decision,p_context,'pulse-store/'||v_slug||'/preview','PULSE_STORE'),
    'conversion_identity', public.fn_conversion_identity(p_decision,p_context,'PULSE_STORE',v_proj_id::text,'pulse-store/'||v_slug||'/preview'),
    'conversion_hooks_live', jsonb_build_array('STORE_VIEW','PRODUCT_VIEW','PRIMARY_CTA_CLICK'),
    'conversion_hooks_prepared_not_fired', jsonb_build_array('ADD_TO_CART','CHECKOUT_STARTED','PURCHASE'),
    'preview', jsonb_build_object('route','/preview/'||v_proj_id::text,'noindex',true,'auth','tenant_only','public',false));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_create_spend_authority(p_actor uuid, p_input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_id uuid; a public.marketing_spend_authority; v_tenant uuid := (p_input->>'tenant_id')::uuid;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','tenant_required'); END IF;
  -- Production: RLS + auth.uid() must equal an authorized owner/member of tenant. Modeled here by requiring actor.
  INSERT INTO public.marketing_spend_authority(tenant_id,platform,ad_account,execution_currency,mode,
    authorized_total,max_daily,max_campaign,max_product_test,allowed_markets,allowed_actions,allowed_campaign_types,
    start_at,end_at,status,is_synthetic,executable,hard_ceiling_mechanism,created_by)
  VALUES (v_tenant, upper(coalesce(p_input->>'platform','META')), p_input->>'ad_account',
    upper(coalesce(p_input->>'execution_currency','')), upper(coalesce(p_input->>'mode','MANUAL')),
    coalesce((p_input->>'authorized_total')::numeric,0), coalesce((p_input->>'max_daily')::numeric,0),
    coalesce((p_input->>'max_campaign')::numeric,0), coalesce((p_input->>'max_product_test')::numeric,0),
    coalesce(p_input->'allowed_markets','[]'::jsonb), coalesce(p_input->'allowed_actions','["CREATE_PAUSED"]'::jsonb),
    coalesce(p_input->'allowed_campaign_types','[]'::jsonb),
    nullif(p_input->>'start_at','')::timestamptz, nullif(p_input->>'end_at','')::timestamptz,
    'DRAFT', coalesce((p_input->>'is_synthetic')::boolean,true), coalesce((p_input->>'executable')::boolean,false),
    coalesce(p_input->>'hard_ceiling_mechanism','ADSET_LIFETIME_BUDGET_PLUS_END_TIME'), p_actor)
  RETURNING id INTO v_id;
  SELECT * INTO a FROM public.marketing_spend_authority WHERE id=v_id;
  UPDATE public.marketing_spend_authority SET authority_fingerprint=public.fn_spend_authority_fingerprint(a) WHERE id=v_id;
  PERFORM public.fn_authority_audit(v_tenant,'AUTHORITY_CREATED',p_actor,v_id,NULL,NULL,to_jsonb(a),NULL,p_input->>'correlation_key');
  RETURN jsonb_build_object('status','ok','authority_id',v_id,'authority_status','DRAFT',
    'executable',a.executable,'authorized_total',a.authorized_total);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_currency_for_country(p_country text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE c text := upper(btrim(coalesce(p_country,'')));
BEGIN
    IF c = '' THEN RETURN NULL; END IF;
    -- Eurozone (names + ISO2)
    IF c IN ('IE','IRELAND','DE','GERMANY','FR','FRANCE','ES','SPAIN','IT','ITALY',
             'NL','NETHERLANDS','PT','PORTUGAL','BE','BELGIUM','AT','AUSTRIA','FI','FINLAND',
             'GR','GREECE','LU','LUXEMBOURG','SK','SLOVAKIA','SI','SLOVENIA','EE','ESTONIA',
             'LV','LATVIA','LT','LITHUANIA','CY','CYPRUS','MT','MALTA','HR','CROATIA','EU','EUROZONE')
       THEN RETURN 'EUR'; END IF;
    IF c IN ('GB','UK','UNITED KINGDOM','GREAT BRITAIN','ENGLAND','SCOTLAND','WALES') THEN RETURN 'GBP'; END IF;
    IF c IN ('US','USA','UNITED STATES','UNITED STATES OF AMERICA') THEN RETURN 'USD'; END IF;
    IF c IN ('ZA','SOUTH AFRICA') THEN RETURN 'ZAR'; END IF;
    IF c IN ('AU','AUSTRALIA') THEN RETURN 'AUD'; END IF;
    IF c IN ('CA','CANADA') THEN RETURN 'CAD'; END IF;
    IF c IN ('NZ','NEW ZEALAND') THEN RETURN 'NZD'; END IF;
    IF c IN ('CH','SWITZERLAND') THEN RETURN 'CHF'; END IF;
    IF c IN ('SE','SWEDEN') THEN RETURN 'SEK'; END IF;
    IF c IN ('NO','NORWAY') THEN RETURN 'NOK'; END IF;
    IF c IN ('DK','DENMARK') THEN RETURN 'DKK'; END IF;
    IF c IN ('PL','POLAND') THEN RETURN 'PLN'; END IF;
    IF c IN ('NG','NIGERIA') THEN RETURN 'NGN'; END IF;
    IF c IN ('KE','KENYA') THEN RETURN 'KES'; END IF;
    IF c IN ('GH','GHANA') THEN RETURN 'GHS'; END IF;
    IF c IN ('IN','INDIA') THEN RETURN 'INR'; END IF;
    IF c IN ('AE','UNITED ARAB EMIRATES','UAE') THEN RETURN 'AED'; END IF;
    IF c IN ('SG','SINGAPORE') THEN RETURN 'SGD'; END IF;
    IF c IN ('JP','JAPAN') THEN RETURN 'JPY'; END IF;
    IF c IN ('BR','BRAZIL') THEN RETURN 'BRL'; END IF;
    IF c IN ('MX','MEXICO') THEN RETURN 'MXN'; END IF;
    -- Already an ISO-4217 code passed through? accept common ones verbatim.
    IF c IN ('EUR','GBP','USD','ZAR','AUD','CAD','NZD','CHF','SEK','NOK','DKK','PLN',
             'NGN','KES','GHS','INR','AED','SGD','JPY','BRL','MXN') THEN RETURN c; END IF;
    RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_customer_experience(p_quality jsonb, p_delivery jsonb, p_supply_confidence text, p_cx_signals jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  q_state text := coalesce(p_quality->>'state','PRODUCT_QUALITY_UNKNOWN');
  q_ss numeric := nullif(p_quality->>'subscore','')::numeric;
  d_known boolean := coalesce((p_delivery->>'known')::boolean,false);
  d_supported boolean := coalesce((p_delivery->>'supported')::boolean,false);
  d_days numeric := nullif(p_delivery->>'days','')::numeric;
  d_critical boolean := coalesce((p_delivery->>'critical')::boolean,false);
  exp_r text := upper(coalesce(p_cx_signals->>'expectation_reality','UNKNOWN'));
  ret_r text := upper(coalesce(p_cx_signals->>'return_refund','UNKNOWN'));
  use_state text := upper(coalesce(p_cx_signals->>'usefulness','UNKNOWN'));
  use_ss numeric := nullif(p_cx_signals->>'usefulness_score','')::numeric;
  sup_c text := upper(coalesce(p_cx_signals->>'support_complexity','UNKNOWN'));
  safety text := upper(coalesce(p_cx_signals->>'safety','NONE'));
  dims jsonb := '{}'::jsonb; gate text; reasons text[] := '{}';
  d_score numeric; exp_score numeric; ret_score numeric; sup_score numeric; supf_score numeric; use_dimscore numeric;
BEGIN
  -- sub-dimension scores (only KNOWN ones score)
  d_score := CASE WHEN NOT d_known THEN NULL WHEN NOT d_supported THEN 0
                  WHEN d_days IS NULL THEN 55 WHEN d_days<=7 THEN 95 WHEN d_days<=14 THEN 80 WHEN d_days<=21 THEN 55 ELSE 30 END;
  exp_score := CASE exp_r WHEN 'LOW' THEN 90 WHEN 'INFERRED_MED' THEN 60 WHEN 'HIGH_MISREP' THEN 10 ELSE NULL END;
  ret_score := CASE ret_r WHEN 'LOW' THEN 85 WHEN 'INFERRED_HIGH' THEN 35 ELSE NULL END;
  supf_score := CASE p_supply_confidence WHEN 'FULLY_VERIFIED' THEN 90 WHEN 'BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED' THEN 60 ELSE NULL END;
  use_dimscore := CASE WHEN use_state='OBSERVED' THEN coalesce(use_ss,70) ELSE NULL END;
  sup_score := CASE sup_c WHEN 'LOW' THEN 90 WHEN 'INFERRED_HIGH' THEN 40 ELSE NULL END;

  dims := jsonb_build_object(
    'product_quality', jsonb_build_object('state',q_state,'score',CASE WHEN (p_quality->>'known')::boolean THEN q_ss ELSE NULL END),
    'delivery', jsonb_build_object('state',CASE WHEN d_known THEN 'OBSERVED' ELSE 'UNKNOWN' END,'score',CASE WHEN d_known THEN d_score ELSE NULL END),
    'expectation_reality', jsonb_build_object('state',CASE WHEN exp_score IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,'score',exp_score),
    'return_refund_risk', jsonb_build_object('state',CASE WHEN ret_score IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,'score',ret_score),
    'fulfilment_confidence', jsonb_build_object('state',CASE WHEN supf_score IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,'score',supf_score),
    'usefulness', jsonb_build_object('state',CASE WHEN use_dimscore IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,'score',use_dimscore),
    'support_complexity', jsonb_build_object('state',CASE WHEN sup_score IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,'score',sup_score));

  -- conservative gate (critical safety/misrepresentation/delivery override commercial score)
  IF safety='CONFIRMED' OR exp_r='HIGH_MISREP' OR d_critical OR (d_known AND NOT d_supported) THEN
    gate := 'CX_BLOCKED';
    IF exp_r='HIGH_MISREP' THEN reasons := array_append(reasons,'marketing_claim_exceeds_product_evidence'); END IF;
    IF safety='CONFIRMED' THEN reasons := array_append(reasons,'confirmed_safety_risk'); END IF;
    IF d_critical OR (d_known AND NOT d_supported) THEN reasons := array_append(reasons,'delivery_unacceptable'); END IF;
  ELSIF (d_known AND d_days IS NOT NULL AND d_days>21) OR ret_r='INFERRED_HIGH'
        OR q_state IN ('PRODUCT_QUALITY_WEAK','PRODUCT_QUALITY_CONFLICTING') OR sup_c='INFERRED_HIGH' THEN
    gate := 'CX_WATCH';
    IF d_known AND d_days>21 THEN reasons := array_append(reasons,'slow_delivery'); END IF;
    IF ret_r='INFERRED_HIGH' THEN reasons := array_append(reasons,'inferred_high_return_refund_risk'); END IF;
    IF q_state IN ('PRODUCT_QUALITY_WEAK','PRODUCT_QUALITY_CONFLICTING') THEN reasons := array_append(reasons,'weak_or_conflicting_product_quality'); END IF;
    IF sup_c='INFERRED_HIGH' THEN reasons := array_append(reasons,'high_support_complexity'); END IF;
  ELSIF q_state IN ('PRODUCT_QUALITY_STRONG','PRODUCT_QUALITY_ACCEPTABLE') AND d_known AND d_supported THEN
    gate := 'CX_PASS'; reasons := array_append(reasons,'quality_supported_and_delivery_acceptable');
  ELSIF d_known AND d_supported THEN
    gate := 'CX_ACCEPTABLE'; reasons := array_append(reasons,'delivery_acceptable_quality_unknown_no_elevated_risk');
  ELSE
    gate := 'CX_INSUFFICIENT'; reasons := array_append(reasons,'insufficient_cx_evidence');
  END IF;

  RETURN jsonb_build_object('customer_experience_score',(public.fn_weighted_over_observed(dims, jsonb_build_object(
      'product_quality',25,'delivery',20,'expectation_reality',15,'return_refund_risk',15,
      'fulfilment_confidence',10,'usefulness',10,'support_complexity',5))->>'score')::numeric,
    'cx_gate',gate,'reasons',to_jsonb(reasons),'dimensions',dims,
    'unknown_note','UNKNOWN sub-dimensions are excluded, never scored 0; UNKNOWN != NEGATIVE');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_decorate_url(p_url text, p_tid text, p_utm jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE WHEN p_url IS NULL OR btrim(p_url)='' THEN NULL ELSE
    p_url || (CASE WHEN position('?' in p_url)>0 THEN '&' ELSE '?' END)
    || 'utm_source=' || coalesce(p_utm->>'source','pulse')
    || '&utm_medium=' || coalesce(p_utm->>'medium','paid_social')
    || '&utm_campaign=' || coalesce(p_utm->>'campaign', p_tid)
    || '&pt=' || p_tid
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_discovery_run_commerce_finalize()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  BEGIN
    PERFORM public.finalize_commerce_from_run(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- fail-soft: commerce normalization must NEVER break core discovery persistence
  END;
  RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_economics_breakeven(p_selling_price numeric, p_landed_cost numeric, p_landed_currency text, p_display_currency text, p_fees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_money jsonb; v_landed_disp numeric; fees_known boolean := (p_fees IS NOT NULL);
  pay_pct numeric := coalesce(nullif(p_fees->>'payment_fee_pct','')::numeric,0);
  plat_pct numeric := coalesce(nullif(p_fees->>'platform_fee_pct','')::numeric,0);
  pay_fixed numeric := coalesce(nullif(p_fees->>'payment_fixed','')::numeric,0);
  other_var numeric := coalesce(nullif(p_fees->>'other_variable','')::numeric,0);
  v_contrib numeric; v_margin numeric; v_state text; v_conf text;
BEGIN
  IF p_selling_price IS NULL OR p_landed_cost IS NULL THEN
    RETURN jsonb_build_object('economics_state','UNKNOWN','known',false,'reason','selling_price_or_landed_cost_missing');
  END IF;
  v_money := public.normalize_money(p_landed_cost, upper(coalesce(p_landed_currency,'USD')), p_display_currency);
  v_landed_disp := nullif(v_money->>'converted_amount','')::numeric;
  IF v_landed_disp IS NULL THEN
    RETURN jsonb_build_object('economics_state','UNKNOWN','known',false,'reason','fx_unavailable_fails_closed','money',v_money);
  END IF;
  v_contrib := round(p_selling_price - v_landed_disp - (pay_pct*p_selling_price) - (plat_pct*p_selling_price) - pay_fixed - other_var, 2);
  v_margin := round(v_contrib / p_selling_price, 4);
  v_state := CASE WHEN v_contrib <= 0 THEN 'NEGATIVE' WHEN v_margin < 0.15 THEN 'THIN' ELSE 'VIABLE' END;
  v_conf := CASE WHEN fees_known THEN 'fees_provided' ELSE 'fees_unknown_assumed_zero' END;
  RETURN jsonb_build_object('economics_state',v_state,'known',true,
    'selling_price',p_selling_price,'landed_cost_display',v_landed_disp,'landed_cost_currency',upper(coalesce(p_landed_currency,'USD')),
    'payment_fee_pct',pay_pct,'platform_fee_pct',plat_pct,'payment_fixed',pay_fixed,'other_variable',other_var,
    'fees_known',fees_known,'contribution_before_ads',v_contrib,'contribution_margin',v_margin,
    'break_even_cpa',v_contrib,'confidence',v_conf,'money',v_money,
    'note','break_even_cpa = contribution_before_ads; unknown fees assumed 0 and flagged, lowering confidence');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_edit_pulse_store_page(p_page_id uuid, p_edits jsonb, p_fees jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_pg public.commerce_product_pages%rowtype; v_model jsonb; v_new_price numeric; v_landed_orig numeric;
  v_econ jsonb; v_state text; v_flag text;
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','page_not_found'); END IF;
  IF v_pg.status='PUBLISHED' THEN RETURN jsonb_build_object('status','cannot_edit_published'); END IF;
  v_model := v_pg.page_model || coalesce(p_edits->'page_model','{}'::jsonb);
  v_new_price := nullif(p_edits->>'selling_price','')::numeric;
  IF v_new_price IS NOT NULL THEN
    v_landed_orig := nullif(v_pg.provenance->>'landed_cost_original','')::numeric;
    v_econ := public.fn_economics_breakeven(v_new_price, v_landed_orig, v_pg.source_currency, coalesce(v_pg.display_currency,'USD'), coalesce(p_fees,'{}'::jsonb));
    v_state := v_econ->>'economics_state';
    v_flag := CASE v_state WHEN 'NEGATIVE' THEN 'UNVIABLE' WHEN 'THIN' THEN 'THIN' WHEN 'VIABLE' THEN 'OK' ELSE 'UNKNOWN' END;
    v_model := jsonb_set(v_model, '{price,selling_price}', to_jsonb(v_new_price::text));
    UPDATE public.commerce_product_pages SET page_model=v_model, selling_price=v_new_price, economics_state=v_state, updated_at=now() WHERE id=p_page_id;
    RETURN jsonb_build_object('status','ok','page_id',p_page_id,'selling_price',v_new_price,'economics_state',v_state,'economics_flag',v_flag,
      'contribution_margin', v_econ->>'contribution_margin','contribution_before_ads', v_econ->>'contribution_before_ads',
      'note','economics recalculated on price edit; not stale; product decision unchanged (canonical process only)');
  ELSE
    UPDATE public.commerce_product_pages SET page_model=v_model, updated_at=now() WHERE id=p_page_id;
    RETURN jsonb_build_object('status','ok','page_id',p_page_id,
      'edited_fields',(SELECT coalesce(jsonb_agg(k),'[]'::jsonb) FROM jsonb_object_keys(coalesce(p_edits->'page_model','{}'::jsonb)) k),
      'note','content edit persisted; no price change');
  END IF;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_eur_to_local(p_ccy text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_ccy='EUR' THEN 1::numeric
    WHEN p_ccy='USD' THEN round(1/(SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency='EUR' ORDER BY as_of DESC LIMIT 1),5)
    ELSE round(
      (SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency=p_ccy ORDER BY as_of DESC LIMIT 1)
      / (SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency='EUR' ORDER BY as_of DESC LIMIT 1), 5)
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_evaluate_product_market(p_tenant uuid, p_product uuid, p_country text, p_market_currency text, p_evidence jsonb, p_economics_inputs jsonb DEFAULT NULL::jsonb, p_policy jsonb DEFAULT '{}'::jsonb, p_is_fixture boolean DEFAULT false, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  W jsonb := coalesce(p_policy->'weights', jsonb_build_object(
    'buyer_search_intent',22,'demand_momentum',8,'marketplace_validation',15,
    'competition_saturation_gap',10,'advertising_activity',15,'market_price_support',10,
    'supplier_availability_stock',8,'landed_economics',12));
  reserve numeric := coalesce(nullif(p_economics_inputs->>'ad_reserve','')::numeric,15);
  target numeric := coalesce(nullif(p_economics_inputs->>'target_contribution','')::numeric,15);
  sell numeric := nullif(p_economics_inputs->>'selling_price','')::numeric;
  price_sc text := coalesce(p_economics_inputs->>'selling_price_source_class', p_evidence->'observed_market_price'->>'source_class','UNKNOWN');
  econ jsonb; contrib numeric; le_sub numeric; econ_gate text;
  price_gate text; stock_gate text; comp_gate text; fulfil_gate text;
  stock_state text := coalesce(p_evidence->>'stock_state','UNKNOWN');
  compliance text := coalesce(p_evidence->>'compliance_risk','UNKNOWN');
  fulfil_usable text := p_evidence->>'fulfilment_usable';
  comps jsonb; sc jsonb; dec jsonb; gates jsonb; row_id uuid; be_cpa numeric;
  function_sub numeric;
BEGIN
  -- economics (reuse canonical breakeven); local market currency preserved
  IF p_economics_inputs IS NULL OR sell IS NULL OR (p_economics_inputs->>'landed_cost') IS NULL THEN
    econ := jsonb_build_object('economics_state','UNKNOWN','known',false,'reason','price_or_landed_unknown');
    contrib := NULL;
  ELSE
    econ := public.fn_economics_breakeven(sell, nullif(p_economics_inputs->>'landed_cost','')::numeric,
              p_economics_inputs->>'landed_currency', coalesce(p_market_currency,'EUR'), p_economics_inputs->'fees');
    be_cpa := nullif(econ->>'break_even_cpa','')::numeric;   -- contribution before ads (per unit)
    IF be_cpa IS NOT NULL THEN contrib := round(be_cpa - reserve, 2); END IF;
  END IF;

  -- landed_economics subscore (derived, explainable)
  IF contrib IS NULL THEN le_sub := NULL; econ_gate := 'WATCH';
  ELSIF contrib < 0 THEN le_sub := 0; econ_gate := 'FAIL';
  ELSE le_sub := round(least(1, contrib/GREATEST(target,0.01))*100, 1); econ_gate := 'PASS';
  END IF;

  -- market_price_support subscore + gate (cross-market converted price is NOT local validation)
  price_gate := CASE WHEN price_sc IN ('OBSERVED','PLATFORM_REPORTED') THEN 'PASS'
                     WHEN price_sc IN ('ESTIMATED','INFERRED') THEN 'WATCH' ELSE 'WATCH' END;
  function_sub := CASE WHEN price_sc IN ('OBSERVED','PLATFORM_REPORTED') THEN 100
                       WHEN price_sc = 'ESTIMATED' THEN 45 WHEN price_sc = 'INFERRED' THEN 30 ELSE NULL END;

  stock_gate := CASE stock_state WHEN 'IN_STOCK' THEN 'PASS' WHEN 'OUT_OF_STOCK' THEN 'FAIL'
                     WHEN 'FACTORY_ONLY' THEN 'WATCH' ELSE 'WATCH' END;   -- UNKNOWN -> WATCH (fail-closed)
  comp_gate := CASE compliance WHEN 'LOW' THEN 'PASS' WHEN 'MEDIUM' THEN 'PASS'
                     WHEN 'HIGH' THEN 'WATCH' WHEN 'CRITICAL' THEN 'FAIL' ELSE 'WATCH' END;
  fulfil_gate := CASE fulfil_usable WHEN 'true' THEN 'PASS' WHEN 'false' THEN 'FAIL' ELSE 'WATCH' END;

  -- assemble component subscores (market-specific; null = UNKNOWN, excluded from denominator)
  comps := jsonb_build_object(
    'buyer_search_intent', jsonb_build_object('subscore', p_evidence->'buyer_search_intent'->>'subscore','weight', W->>'buyer_search_intent'),
    'demand_momentum', jsonb_build_object('subscore', p_evidence->'demand_momentum'->>'subscore','weight', W->>'demand_momentum'),
    'marketplace_validation', jsonb_build_object('subscore', p_evidence->'marketplace_validation'->>'subscore','weight', W->>'marketplace_validation'),
    'competition_saturation_gap', jsonb_build_object('subscore', p_evidence->'competition_saturation_gap'->>'subscore','weight', W->>'competition_saturation_gap'),
    'advertising_activity', jsonb_build_object('subscore', p_evidence->'advertising_activity'->>'subscore','weight', W->>'advertising_activity'),
    'market_price_support', jsonb_build_object('subscore', function_sub,'weight', W->>'market_price_support'),
    'supplier_availability_stock', jsonb_build_object('subscore', p_evidence->'supplier_availability_stock'->>'subscore','weight', W->>'supplier_availability_stock'),
    'landed_economics', jsonb_build_object('subscore', le_sub,'weight', W->>'landed_economics'));

  sc := public.fn_pm_score(comps);
  gates := jsonb_build_object('stock',stock_gate,'economics',econ_gate,'price',price_gate,'compliance',comp_gate,'fulfilment',fulfil_gate);
  dec := public.fn_pm_decision(nullif(sc->>'market_opportunity_score','')::numeric, sc->>'evidence_confidence', gates, p_policy);

  IF p_persist THEN
    INSERT INTO public.product_market_evaluations
      (tenant_id, product_id, country_code, market_currency, component_scores,
       market_opportunity_score, coverage, evidence_confidence, gate_state, market_decision,
       decision_reasons, risk_flags, evidence, stock_state, compliance_risk, economics, is_fixture, provenance)
    VALUES (p_tenant, p_product, p_country, p_market_currency, comps,
       nullif(sc->>'market_opportunity_score','')::numeric, nullif(sc->>'coverage','')::numeric, sc->>'evidence_confidence',
       gates, dec->>'market_decision', dec->'decision_reasons',
       coalesce(p_evidence->'risk_flags','[]'::jsonb), p_evidence, stock_state, compliance,
       econ || jsonb_build_object('ad_reserve',reserve,'contribution_after_reserve',contrib), p_is_fixture,
       jsonb_build_object('score_version','pm_score_v1','engine','fn_evaluate_product_market'))
    ON CONFLICT (tenant_id, product_id, country_code, score_version) DO UPDATE
      SET component_scores=EXCLUDED.component_scores, market_opportunity_score=EXCLUDED.market_opportunity_score,
          coverage=EXCLUDED.coverage, evidence_confidence=EXCLUDED.evidence_confidence, gate_state=EXCLUDED.gate_state,
          market_decision=EXCLUDED.market_decision, decision_reasons=EXCLUDED.decision_reasons, evidence=EXCLUDED.evidence,
          stock_state=EXCLUDED.stock_state, compliance_risk=EXCLUDED.compliance_risk, economics=EXCLUDED.economics,
          evaluation_ts=now()
    RETURNING id INTO row_id;
  END IF;

  RETURN jsonb_build_object(
    'evaluation_id', row_id, 'tenant_id', p_tenant, 'product_id', p_product, 'country_code', p_country,
    'market_currency', p_market_currency, 'component_scores', comps,
    'market_opportunity_score', nullif(sc->>'market_opportunity_score','')::numeric,
    'coverage', nullif(sc->>'coverage','')::numeric, 'evidence_confidence', sc->>'evidence_confidence',
    'gate_state', gates, 'market_decision', dec->>'market_decision', 'decision_reasons', dec->'decision_reasons',
    'economics', econ || jsonb_build_object('ad_reserve',reserve,'contribution_after_reserve',contrib),
    'stock_state', stock_state, 'compliance_risk', compliance, 'is_fixture', p_is_fixture,
    'score_version','pm_score_v1', 'contract','pulse_product_market_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_evaluate_supplier(p_supplier jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_ev jsonb; v_econ jsonb; v_dims jsonb; v_score jsonb; v_suff text; v_gate jsonb; v_risks text[] := '{}';
BEGIN
  v_ev := public.fn_supplier_evidence(p_supplier, p_target_market);
  v_econ := public.fn_supplier_economics(p_supplier, p_selling_price, p_display_currency);
  v_dims := v_ev || jsonb_build_object('economics', v_econ);
  v_score := public.fn_supplier_quality_score(v_dims);
  v_suff := public.fn_supplier_evidence_sufficiency(v_dims);
  v_gate := public.fn_supplier_gate(v_dims, v_score, v_suff, v_econ);
  v_risks := ARRAY(SELECT jsonb_array_elements_text(v_gate->'critical_failures'));
  RETURN jsonb_build_object(
    'supplier_id', p_supplier->>'supplier_id', 'source', p_supplier->>'source',
    'target_market', upper(coalesce(p_target_market,'UNKNOWN')), 'display_currency', p_display_currency,
    'supplier_quality_score', v_score,
    'supplier_evidence_sufficiency', v_suff,
    'supplier_gate', v_gate->>'supplier_gate',
    'gate_detail', v_gate,
    'dimensions', v_dims,
    'economics', v_econ,
    'risks', to_jsonb(v_risks),
    'unknown_factors', v_score->'unknown_dimensions',
    'delivery_evidence', v_dims->'delivery',
    'reliability_evidence', v_dims->'reliability',
    'authenticity_evidence', v_dims->'authenticity',
    'provenance', jsonb_build_object('classification','GLOBAL_SUPPLY_EVIDENCE + TENANT_ECONOMICS'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_evidence_confidence(p_completeness numeric, p_categories integer, p_corroborated boolean, p_conflicts boolean, p_freshness text, p_unknown_critical integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v numeric := 0; notes text[] := '{}';
BEGIN
  v := v + coalesce(p_completeness,0)*40;                    -- 0..40 coverage
  v := v + least(coalesce(p_categories,0),4)/4.0*30;          -- 0..30 independent categories
  IF coalesce(p_corroborated,false) THEN v := v + 15; ELSE notes := array_append(notes,'single_or_uncorroborated_sources'); END IF;
  IF p_freshness = 'FRESH' THEN v := v + 15; ELSIF p_freshness = 'STALE' THEN v := v - 10; notes := array_append(notes,'stale_evidence'); END IF;
  IF coalesce(p_conflicts,false) THEN v := v - 20; notes := array_append(notes,'conflicting_evidence'); END IF;
  v := v - least(coalesce(p_unknown_critical,0),4)*7;        -- unknown critical dims erode confidence
  v := greatest(0, least(100, round(v)));
  RETURN jsonb_build_object('evidence_confidence', v,
    'level', CASE WHEN v>=70 THEN 'HIGH' WHEN v>=45 THEN 'MODERATE' WHEN v>=30 THEN 'LOW' ELSE 'VERY_LOW' END,
    'notes', to_jsonb(notes), 'note','independent of opportunity score; measures how verified the picture is');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_expand_search_queries(p_entity jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_name text; v_brand text; v_lang text; toks text[]; i int; tok text;
  syn jsonb := jsonb_build_object(
    'portable', jsonb_build_array('travel','mini','handheld'),
    'cordless', jsonb_build_array('wireless','rechargeable'),
    'wireless', jsonb_build_array('cordless'),
    'rechargeable', jsonb_build_array('usb'),
    'electric', jsonb_build_array('automatic'),
    'foldable', jsonb_build_array('folding'),
    'espresso', jsonb_build_array('coffee'),
    'maker', jsonb_build_array('machine'),
    'blender', jsonb_build_array('mixer'),
    'light', jsonb_build_array('lamp'));
  out jsonb := '[]'::jsonb; variant text; s text;
BEGIN
  v_name := btrim(regexp_replace(lower(coalesce(p_entity->>'canonical_name','')), '\s+',' ','g'));
  v_brand := nullif(btrim(coalesce(p_entity->>'brand_if_observed','')),'');
  v_lang := coalesce(nullif(btrim(p_entity->>'language'),''),'en');
  IF v_name = '' THEN RETURN out; END IF;
  toks := string_to_array(v_name,' ');

  -- base = DIRECT
  out := out || jsonb_build_array(jsonb_build_object('query',v_name,'relationship','DIRECT_PRODUCT','language',v_lang,'derived',false));
  -- brand + name = CLOSE
  IF v_brand IS NOT NULL THEN
    out := out || jsonb_build_array(jsonb_build_object('query',lower(v_brand)||' '||v_name,'relationship','CLOSE_VARIANT','language',v_lang,'derived',true));
  END IF;
  -- one-token synonym swaps = CLOSE
  FOR i IN 1..array_length(toks,1) LOOP
    tok := toks[i];
    IF syn ? tok THEN
      FOR s IN SELECT jsonb_array_elements_text(syn->tok) LOOP
        variant := btrim(array_to_string(toks[1:i-1],' ')||' '||s||' '||array_to_string(toks[i+1:array_length(toks,1)],' '));
        variant := btrim(regexp_replace(variant,'\s+',' ','g'));
        IF variant <> v_name AND NOT (out @> jsonb_build_array(jsonb_build_object('query',variant,'relationship','CLOSE_VARIANT','language',v_lang,'derived',true))) THEN
          out := out || jsonb_build_array(jsonb_build_object('query',variant,'relationship','CLOSE_VARIANT','language',v_lang,'derived',true));
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- cap at 6 queries
  RETURN (SELECT coalesce(jsonb_agg(e),'[]'::jsonb) FROM (SELECT e FROM jsonb_array_elements(out) e LIMIT 6) z);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_fulfilment_evaluate_option(p_option jsonb, p_market text, p_display_currency text, p_market_price numeric, p_ad_reserve numeric DEFAULT 15, p_variable_costs numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_stock jsonb; v_deliv jsonb; v_price jsonb;
  v_days numeric; v_speed text; v_region text; v_bucket text;
  v_wh_country text; v_test_ready boolean; v_reasons text[] := '{}';
  v_c_comp numeric; v_d_comp numeric; v_s_comp numeric; v_rank numeric;
  v_eea text[] := ARRAY['AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IE','IT','LV','LT','LU','MT','NL','PL','PT','RO','SK','SI','ES','SE','IS','LI','NO','GB','CH'];
BEGIN
  v_stock := public.fn_supplier_stock_state(p_option);
  v_deliv := public.fn_supplier_delivery_state(p_option->'shipping_country_codes', NULL, p_market, p_option->'delivery_estimate');
  v_price := public.fn_candidate_pricing_economics(p_option, p_market_price, p_display_currency, p_ad_reserve, p_variable_costs);

  v_days := coalesce(nullif(btrim(v_deliv->>'est_max_days'),'')::numeric, nullif(btrim(v_deliv->>'days'),'')::numeric);
  v_speed := CASE
    WHEN v_days IS NULL THEN 'UNKNOWN'
    WHEN v_days <= 10 THEN 'FAST'
    WHEN v_days <= 20 THEN 'STANDARD'
    ELSE 'ECONOMY' END;

  v_wh_country := upper(coalesce(v_stock->>'warehouse_country', p_option->>'warehouse_country',''));
  v_region := CASE WHEN v_wh_country = '' THEN 'UNKNOWN'
                   WHEN v_wh_country = ANY(v_eea) THEN 'EEA'
                   ELSE 'NON_EEA' END;

  v_bucket := CASE
    WHEN v_speed='FAST' AND v_region='EEA' THEN 'EU_FAST'
    WHEN v_speed='FAST' THEN 'FAST'
    WHEN v_speed IN ('STANDARD','ECONOMY') THEN 'ECONOMY'
    ELSE 'UNCLASSIFIED' END;

  v_test_ready := (v_stock->>'stock_state'='IN_STOCK')
              AND ((v_price->>'known')::boolean IS TRUE) AND (v_price->>'suggested_action' <> 'AVOID')
              AND ((v_deliv->>'known')::boolean IS TRUE) AND (lower(coalesce(v_deliv->>'supported',''))='true')
              AND (coalesce(v_deliv->>'market_evidence_state','') <> 'OBSERVED_NEGATIVE');

  IF v_stock->>'stock_state' <> 'IN_STOCK' THEN
    v_reasons := array_append(v_reasons, 'stock:'||(v_stock->>'stock_state'));
  END IF;
  IF (v_price->>'known')::boolean IS NOT TRUE THEN
    v_reasons := array_append(v_reasons, 'economics:'||coalesce(v_price->>'reason','unknown'));
  ELSIF v_price->>'suggested_action'='AVOID' THEN
    v_reasons := array_append(v_reasons, 'economics:UNVIABLE');
  END IF;
  IF (v_deliv->>'known')::boolean IS NOT TRUE OR lower(coalesce(v_deliv->>'supported',''))<>'true' THEN
    v_reasons := array_append(v_reasons, 'delivery:'||coalesce(v_deliv->>'market_evidence_state','NO_EVIDENCE'));
  END IF;

  v_c_comp := CASE v_price->>'contribution_band'
                WHEN 'STRONG' THEN 100 WHEN 'MEETS_TARGET' THEN 80 WHEN 'THIN' THEN 45 ELSE 0 END;
  v_d_comp := coalesce(nullif(btrim(v_deliv->>'subscore'),'')::numeric, 0);
  v_s_comp := CASE WHEN v_stock->>'warehouse_ready'='true' THEN 100
                   WHEN v_stock->>'stock_state'='IN_STOCK' THEN 60 ELSE 0 END;
  v_rank := round(0.45*v_c_comp + 0.35*v_d_comp + 0.20*v_s_comp, 1);

  RETURN jsonb_build_object(
    'provider', p_option->>'provider',
    'source_product_id', p_option->>'source_product_id',
    'title', p_option->>'title',
    'market', upper(coalesce(p_market,'')),
    'fulfilment_speed', v_speed,
    'warehouse_region', v_region,
    'warehouse_country', nullif(v_wh_country,''),
    'page_bucket', v_bucket,
    'delivery_min_days', nullif(btrim(v_deliv->>'est_min_days'),'')::numeric,
    'delivery_max_days', v_days,
    'landed_cost', v_price->'landed_cost',
    'projected_contribution', v_price->'projected_contribution',
    'contribution_band', v_price->'contribution_band',
    'test_ready', v_test_ready,
    'blocked_reasons', to_jsonb(v_reasons),
    'rank_score', v_rank,
    'stock', v_stock, 'delivery', v_deliv, 'pricing', v_price);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_fulfilment_rollup(p_evaluated jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_ready jsonb; v_ranked jsonb;
  v_has_fast boolean; v_has_econ boolean; v_has_eu_fast boolean;
  v_avail text; v_gate text;
  v_primary jsonb; v_secondary jsonb; v_prim_family text;
  v_total int := coalesce(jsonb_array_length(p_evaluated),0);
BEGIN
  IF v_total = 0 THEN
    RETURN jsonb_build_object('fulfilment_availability','NO_ACCEPTABLE_SUPPLIER','test_gate','NOT_TEST_ELIGIBLE',
      'reason','NO_LINKED_SUPPLIER','options','[]'::jsonb,'options_count',0);
  END IF;

  SELECT coalesce(jsonb_agg(e ORDER BY (e->>'rank_score')::numeric DESC),'[]'::jsonb)
    INTO v_ready FROM jsonb_array_elements(p_evaluated) e WHERE (e->>'test_ready')::boolean IS TRUE;
  SELECT coalesce(jsonb_agg(e ORDER BY (e->>'rank_score')::numeric DESC),'[]'::jsonb)
    INTO v_ranked FROM jsonb_array_elements(p_evaluated) e;

  v_has_fast    := EXISTS (SELECT 1 FROM jsonb_array_elements(v_ready) e WHERE e->>'page_bucket' IN ('EU_FAST','FAST'));
  v_has_eu_fast := EXISTS (SELECT 1 FROM jsonb_array_elements(v_ready) e WHERE e->>'page_bucket'='EU_FAST');
  v_has_econ    := EXISTS (SELECT 1 FROM jsonb_array_elements(v_ready) e WHERE e->>'page_bucket'='ECONOMY');

  IF jsonb_array_length(v_ready)=0 THEN
    v_avail := 'NO_ACCEPTABLE_SUPPLIER'; v_gate := 'NOT_TEST_ELIGIBLE';
  ELSE
    v_gate := 'TEST_ELIGIBLE';
    v_avail := CASE
      WHEN v_has_fast AND v_has_econ THEN 'BOTH'
      WHEN v_has_eu_fast THEN 'EU_FAST_ONLY'
      WHEN v_has_fast THEN 'FAST_ONLY'
      WHEN v_has_econ THEN 'CJ_ECONOMY_ONLY'
      ELSE 'ACCEPTABLE_UNCLASSIFIED' END;
  END IF;

  -- primary = highest composite rank among test-ready; secondary = best of the OTHER family (fast vs economy)
  IF jsonb_array_length(v_ready) > 0 THEN
    v_primary := v_ready->0;
    v_prim_family := CASE WHEN v_primary->>'page_bucket' IN ('EU_FAST','FAST') THEN 'FAST' ELSE 'ECONOMY' END;
    SELECT e INTO v_secondary FROM jsonb_array_elements(v_ready) e
      WHERE CASE WHEN e->>'page_bucket' IN ('EU_FAST','FAST') THEN 'FAST' ELSE 'ECONOMY' END <> v_prim_family
      ORDER BY (e->>'rank_score')::numeric DESC LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'fulfilment_availability', v_avail,
    'test_gate', v_gate,
    'options_count', v_total,
    'test_ready_count', jsonb_array_length(v_ready),
    'page_fast_available', v_has_fast,
    'page_economy_available', v_has_econ,
    'recommended_primary', v_primary,
    'recommended_secondary', v_secondary,
    'options', v_ranked,
    'selection_note','composite rank (contribution 45% + delivery 35% + stock readiness 20%); cheapest is NOT auto-selected',
    'test_note', CASE WHEN v_gate='TEST_ELIGIBLE'
      THEN 'at least one in-stock, economically viable option with real delivery evidence exists'
      ELSE 'no option passes the hard stock + economics + delivery evidence gate; cannot become production TEST' END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_fx_freshness(p_max_age_hours integer DEFAULT 36)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_fetched timestamptz; v_asof date; v_src text; v_base text; v_rows int; v_age numeric; v_fresh boolean;
BEGIN
  SELECT max(fetched_at) INTO v_fetched FROM public.fx_rates;
  IF v_fetched IS NULL THEN
    RETURN jsonb_build_object('status','NO_FX_DATA','fresh',false,'actionable',true,
      'action','run Pulse — FX Rate Refresher (np2MUp83gaZ3C2pJ)','max_age_hours',p_max_age_hours);
  END IF;
  SELECT base_currency, as_of, source, count(*)
    INTO v_base, v_asof, v_src, v_rows
  FROM public.fx_rates WHERE fetched_at = v_fetched
  GROUP BY base_currency, as_of, source
  ORDER BY count(*) DESC LIMIT 1;
  v_age := round(extract(epoch FROM (now()-v_fetched))/3600.0, 1);
  v_fresh := v_age <= p_max_age_hours;
  RETURN jsonb_build_object(
    'status', CASE WHEN v_fresh THEN 'FRESH' ELSE 'STALE' END,
    'fresh', v_fresh, 'actionable', (NOT v_fresh),
    'latest_fetched_at', v_fetched, 'age_hours', v_age, 'max_age_hours', p_max_age_hours,
    'latest_as_of', v_asof, 'base_currency', v_base, 'provider', v_src, 'rate_count', v_rows,
    'action', CASE WHEN v_fresh THEN NULL
                   ELSE 'FX beyond freshness window; run Pulse — FX Rate Refresher; non-USD economics will fail closed to UNKNOWN until refreshed' END,
    'note','freshness derived from fetched_at (not as_of); daily refresh bumps fetched_at even when ECB as_of is unchanged (weekend/holiday)');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_generate_meta_ad_queries(p_product jsonb, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text := lower(btrim(coalesce(p_product->>'title','')));
  v_mat text := lower(btrim(coalesce(p_product->>'material','')));
  v_meta_state text := public.fn_category_market_state('ADVERTISING', p_market);
  stop text[] := ARRAY['for','and','the','with','a','to','of','set','pack','pcs','new','2026','x','cm','mm'];
  toks text[]; core text; q1 text; q2 text; out jsonb := '[]'::jsonb;
  func_words text[] := ARRAY['repair','patch','holder','organizer','cleaner','cover','protector','stand','mount','cutter','trimmer','massager','dispenser'];
  v_func text;
BEGIN
  -- normalize title -> core 2-4 token product phrase (drop marketing filler)
  toks := ARRAY(SELECT t FROM unnest(regexp_split_to_array(regexp_replace(v_title,'[^a-z0-9 ]',' ','g'),'\s+')) t
                WHERE t <> '' AND t <> ALL(stop) AND length(t) > 2 LIMIT 4);
  core := btrim(array_to_string(toks,' '));
  SELECT f INTO v_func FROM unnest(func_words) f WHERE v_title LIKE '%'||f||'%' LIMIT 1;
  q1 := core;
  q2 := btrim(coalesce(nullif(v_mat,'')||' ','')||coalesce(v_func,''));

  -- specificity: >=2 meaningful tokens = HIGH; 1 = LOW; empty = AMBIGUOUS
  out := out || jsonb_build_array(jsonb_build_object('query',q1,'query_type','normalized_product_phrase',
    'specificity', CASE WHEN array_length(toks,1) >= 3 THEN 'HIGH_SPECIFICITY' WHEN array_length(toks,1) = 2 THEN 'MEDIUM_SPECIFICITY' WHEN array_length(toks,1)=1 THEN 'LOW_SPECIFICITY' ELSE 'AMBIGUOUS' END,
    'generation_reason','core product phrase from title minus marketing filler',
    'accepted', (array_length(toks,1) >= 2),
    'rejection_reason', CASE WHEN array_length(toks,1) >= 2 THEN NULL ELSE 'insufficient_specificity' END));
  IF q2 <> '' AND q2 <> q1 AND array_length(regexp_split_to_array(q2,'\s+'),1) >= 2 THEN
    out := out || jsonb_build_array(jsonb_build_object('query',q2,'query_type','material_plus_function',
      'specificity','MEDIUM_SPECIFICITY','generation_reason','material + functional descriptor','accepted',true,'rejection_reason',NULL));
  END IF;

  RETURN jsonb_build_object('product_title', v_title, 'target_market', upper(btrim(coalesce(p_market,''))),
    'meta_provider_state', v_meta_state,
    'collect_allowed', (v_meta_state IN ('AVAILABLE','PARTIAL')),
    'queries', out,
    'note', CASE WHEN v_meta_state NOT IN ('AVAILABLE','PARTIAL')
                 THEN 'Meta '||v_meta_state||' for this market; no Meta call — router hands back to other providers'
                 ELSE 'product-specific queries only; generic single-term queries rejected' END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_generate_page_copy(p_decision jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text := coalesce(p_context->>'product_title','Product');
  v_pos text := coalesce(p_context->>'positioning', v_title);
  v_cur text := coalesce(p_context->>'display_currency','USD'); v_price text := p_context->>'selling_price';
  v_deliv jsonb := coalesce(p_decision->'supplier_execution'->'delivery','{}'::jsonb);
  v_min text := v_deliv->>'est_min_days'; v_max text := v_deliv->>'est_max_days'; v_method text := v_deliv->>'method';
  v_brand text := coalesce(p_context->>'brand_name', initcap(split_part(v_pos,' ',1))||' Supply Co.');
  v_ship text;
BEGIN
  v_ship := CASE WHEN v_min IS NOT NULL AND v_max IS NOT NULL
    THEN 'Estimated delivery: '||v_min||E'–'||v_max||' days ('||coalesce(v_method,'standard shipping')||'; carrier estimate, not guaranteed).'
    ELSE 'Delivery estimate confirmed at checkout.' END;
  RETURN jsonb_build_object(
   'model_version','pulse_product_page_v1','editable',true,'draft_first',true,'generated_by','deterministic_claim_safe_generator_v1',
   'brand', jsonb_build_object('name', v_brand,'logo','TEXT_MARK_PLACEHOLDER','voice','clear, practical, honest','headline_style','benefit-led, factual',
      'theme_tokens', jsonb_build_object('primary','#111827','accent','#2563eb','bg','#ffffff','text','#1f2937')),
   'announcement','Estimated delivery '||coalesce(v_min||E'–'||v_max||' days','shown at checkout')||' • Draft store (not published)',
   'hero', jsonb_build_object('headline', initcap(v_pos),'subheadline','A practical '||lower(v_pos)||' you can order online.'),
   'product_title', v_title,'positioning', v_pos,
   'short_description','This listing is for a '||lower(v_pos)||'.',
   'benefits', jsonb_build_array('Straightforward '||lower(v_pos),'Ships to '||coalesce(p_decision->>'target_market','your market'),
      'Transparent estimated delivery','New condition, fulfilled from the supplier warehouse'),
   'problem_solution', jsonb_build_object('problem','Shoppers searching for '||lower(v_pos)||' want a clear, no-guesswork option.',
      'solution','This page presents the product with honest details and an estimated delivery window.'),
   'how_it_works', jsonb_build_array('Choose your options','Place your order','Receive within the estimated delivery window'),
   'details', jsonb_build_object('category', p_context->>'category','material', p_context->>'material','note','confirm specifications from supplier data'),
   'shipping', jsonb_build_object('copy', v_ship,'est_min_days', v_min,'est_max_days', v_max,'method', v_method),
   'trust', jsonb_build_object('copy','New condition. Fulfilled from the supplier warehouse. Delivery times are estimates, not guarantees.',
      'authenticity_state', p_decision->'product_trust'->>'gate','supply_confidence', p_decision->>'supply_confidence',
      'disclaimers', jsonb_build_array('No reviews, ratings, or testimonials are shown (none verified).','Delivery is an estimate, not a guarantee.')),
   'price', jsonb_build_object('selling_price', v_price,'currency', v_cur,'source_currency', p_decision->'economics'->>'landed_cost_currency',
      'landed_cost_display', p_decision->'economics'->>'landed_cost_display','offer_note','No discount or crossed-out price shown (no verified prior price).'),
   'faq', jsonb_build_array(
      jsonb_build_object('q','How long is delivery?','a', v_ship),
      jsonb_build_object('q','Where does it ship from?','a','From the supplier warehouse; see the shipping estimate.'),
      jsonb_build_object('q','What condition is the product?','a','New, fulfilled from the supplier warehouse. Delivery times are estimates, not guarantees.')),
   'cta', jsonb_build_object(
      'primary', jsonb_build_object('label','Add to cart','checkout_boundary','CHECKOUT_HANDLED_BY_DESTINATION_STORE','functional',false),
      'secondary', jsonb_build_object('label','See product details','action','SCROLL_TO_DETAILS')),
   'seo', jsonb_build_object('title', left(v_title||' | '||v_brand,60),
      'meta_description', left('Order '||lower(v_pos)||'. Estimated delivery '||coalesce(v_min||E'–'||v_max||' days','shown at checkout')||'.',155),
      'keywords', coalesce(p_context->'seo_keywords', jsonb_build_array(lower(v_pos)))),
   'assets', jsonb_build_object('primary_image', NULL,'gallery','[]'::jsonb,'state','PRODUCT_ASSET_REQUIRED',
      'note','no legitimate product image available; merchant must upload/verify (no fabricated supplier photo)'),
   'copy_provenance', jsonb_build_object('headline','AI_TRANSFORMATION(positioning)','short_description','AI_TRANSFORMATION(positioning)',
      'benefits','AI_TEMPLATE(editable)','shipping','DELIVERY_EVIDENCE(CJ_FREIGHT_CALCULATE)','price','PRODUCT_DECISION_ECONOMICS',
      'trust','PRODUCT_DECISION(product_trust,supply_confidence)','seo','AI_TRANSFORMATION(title,positioning)',
      'brand', CASE WHEN p_context ? 'brand_name' THEN 'BUSINESS_DNA' ELSE 'AI_SUGGESTION_EDITABLE' END),
   'claim_safety', jsonb_build_object('no_reviews_fabricated',true,'no_fake_discount',true,'no_guaranteed_delivery',true,
      'no_urgency_scarcity',true,'no_certifications_or_warranty_claimed',true,'delivery_labeled_estimate',true));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_generate_storefront_runtime(p_user_id uuid, p_gate_inputs jsonb, p_selection_input jsonb, p_context jsonb, p_decision jsonb, p_destination text DEFAULT 'PULSE_HOSTED'::text, p_source_kind text DEFAULT 'REAL'::text, p_product_id uuid DEFAULT NULL::uuid, p_country_code text DEFAULT NULL::text, p_opportunity_decision_id uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_gate jsonb; v_sel jsonb; v_assets jsonb; v_copy jsonb; v_scan jsonb;
  v_family text; v_market text := upper(coalesce(p_decision->>'target_market', p_country_code, ''));
  v_contract jsonb; v_draft jsonb; v_page_id uuid; v_marketing_text text; v_ad_match jsonb;
  v_dest text := upper(coalesce(p_destination,'PULSE_HOSTED'));
BEGIN
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  IF NOT (v_gate->>'test_eligible')::boolean THEN
    IF p_source_kind = 'FIXTURE' THEN
      v_sel := public.fn_select_conversion_template(p_selection_input);
      RETURN jsonb_build_object('status','REFUSED_PRODUCTION_DEV_PREVIEW_ONLY',
        'test_eligible', false, 'generation_state','DEV_PREVIEW_NON_PUBLISHABLE',
        'publication_state','BLOCKED_NON_PUBLISHABLE', 'is_fixture', true,
        'gate', v_gate, 'template_preview', v_sel->>'recommended_template_family',
        'note','Fixture/dev preview only; not eligible; nothing persisted as a real product.');
    END IF;
    RETURN jsonb_build_object('status','REFUSED','test_eligible', false,
      'generation_state','REFUSED','reason_codes', v_gate->'reason_codes',
      'decision_state', v_gate->>'decision_state', 'gate', v_gate,
      'note','Not TEST_ELIGIBLE; no storefront generated. Fail-closed.');
  END IF;

  v_sel := public.fn_select_conversion_template(p_selection_input);
  v_family := v_sel->>'recommended_template_family';
  v_copy := public.fn_generate_page_copy(p_decision, p_context);
  v_assets := public.fn_resolve_storefront_assets(
                p_context->>'supplier', p_context->>'supplier_product_id', p_country_code);

  -- Scan only PERSUASIVE copy surfaces; trust disclaimers/announcement are honest
  -- negations ("estimates, not guarantees") and would false-positive.
  v_marketing_text := concat_ws(' ',
     v_copy->'hero'->>'headline', v_copy->'hero'->>'subheadline', v_copy->>'short_description',
     v_copy->'problem_solution'->>'problem', v_copy->'problem_solution'->>'solution',
     (SELECT string_agg(b,' ') FROM jsonb_array_elements_text(coalesce(v_copy->'benefits','[]'::jsonb)) b));
  v_scan := public.fn_ad_studio_claim_scan(v_marketing_text);

  v_ad_match := coalesce(p_selection_input->'ad_match', jsonb_build_object(
      'state','NO_AD_MATCH_YET',
      'addressable_by', jsonb_build_object('product_id', p_product_id, 'country_code', p_country_code, 'market', v_market),
      'offer_version','v1'));

  v_contract := jsonb_build_object(
    'product_id', p_product_id,
    'country_code', p_country_code,
    'opportunity_decision_id', p_opportunity_decision_id,
    'template_family', v_family,
    'template_version', v_sel->>'template_version',
    'market', v_market,
    'destination', v_dest,
    'source_currency', coalesce(p_decision->'economics'->>'landed_cost_currency', p_context->>'source_currency'),
    'display_currency', p_context->>'display_currency',
    'economics_state', p_decision->'economics'->>'economics_state',
    'ad_match_ref', v_ad_match,
    'sections', v_sel->'sections',
    'hero_variant', v_sel->>'hero_variant',
    'cta_structure', v_sel->'cta_structure',
    'claim_safety', (coalesce(v_copy->'claim_safety','{}'::jsonb)
                     || jsonb_build_object('runtime_claim_scan', v_scan,
                          'claim_scan_clean', (jsonb_array_length(v_scan)=0),
                          'unsafe_sections_editable_placeholder', (jsonb_array_length(v_scan) > 0))),
    'copy_provenance', v_copy->'copy_provenance',
    'supplier_asset_refs', v_assets,
    'assets_state', v_assets->>'state',
    'selection', v_sel,
    'generation_state', 'GENERATED',
    'review_state', 'DRAFT',
    'publication_state', 'UNPUBLISHED',
    'terminology_guard','BEST_FIT_PRE_PERFORMANCE_NOT_PROVEN');

  IF NOT p_persist THEN
    RETURN jsonb_build_object('status','ok_preview','test_eligible',true,'persisted',false,
      'runtime_contract', v_contract, 'gate', v_gate);
  END IF;

  v_draft := public.fn_create_pulse_store_draft(p_user_id, p_decision, p_context, p_source_kind, p_product_id);
  IF coalesce((v_draft->>'created')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','REFUSED_AT_PERSIST','gate',v_gate,'draft',v_draft,
      'note','Eligibility passed but canonical draft creation refused (decision not TEST at persist).');
  END IF;
  v_page_id := (v_draft->>'product_page_id')::uuid;

  UPDATE public.commerce_product_pages SET
    country_code = p_country_code,
    opportunity_decision_id = p_opportunity_decision_id,
    template_family = v_family,
    template_version = v_sel->>'template_version',
    ad_match_ref = v_ad_match,
    supplier_asset_refs = v_assets,
    generation_state = 'GENERATED',
    review_state = 'DRAFT',
    publication_state = 'UNPUBLISHED',
    runtime_contract = v_contract,
    page_model = page_model
      || jsonb_build_object('template_family', v_family, 'template_version', v_sel->>'template_version',
           'sections', v_sel->'sections', 'hero_variant', v_sel->>'hero_variant',
           'assets_runtime', v_assets, 'ad_match_ref', v_ad_match)
      || jsonb_build_object('assets', jsonb_build_object(
            'primary_image', v_assets->'primary_image'->>'source_url',
            'gallery', (SELECT coalesce(jsonb_agg(x->>'source_url'),'[]'::jsonb) FROM jsonb_array_elements(v_assets->'gallery') x),
            'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS_RESOLVED' ELSE 'PRODUCT_ASSET_REQUIRED' END,
            'origin','SOURCE_SUPPLIER','note','rights-clear supplier images; no fabricated replacement')),
    updated_at = now()
  WHERE id = v_page_id;

  RETURN jsonb_build_object('status','ok','test_eligible',true,'persisted',true,
    'product_page_id', v_page_id, 'store_project_id', v_draft->>'store_project_id',
    'template_family', v_family, 'template_version', v_sel->>'template_version',
    'review_state','DRAFT','publication_state','UNPUBLISHED','generation_state','GENERATED',
    'assets_state', v_assets->>'state', 'claim_scan_clean', (jsonb_array_length(v_scan)=0),
    'runtime_contract', v_contract, 'ad_studio_handoff', v_draft->'ad_studio_handoff',
    'preview', v_draft->'preview', 'gate', v_gate);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_global_intelligence_uid()
 RETURNS uuid
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT '00000000-0000-4000-8000-000000000001'::uuid $function$
;

CREATE OR REPLACE FUNCTION public.fn_guard_auth_event_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    RAISE EXCEPTION 'public.auth_event is append-only; UPDATE and DELETE are not permitted.'
        USING ERRCODE = 'P0001';
    RETURN NULL;  -- unreachable; keeps the trigger function well-formed
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_guard_discovery_state_member_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.member_id IS DISTINCT FROM OLD.member_id THEN
        RAISE EXCEPTION 'discovery_state.member_id is immutable.' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_guard_member_protected_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'member.id is immutable.' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
        RAISE EXCEPTION 'member.auth_user_id is immutable.' USING ERRCODE = 'P0001';
    END IF;
    IF current_user IN ('anon', 'authenticated') THEN
        IF NEW.email IS DISTINCT FROM OLD.email THEN
            RAISE EXCEPTION 'member.email cannot be modified from a client context.' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
            RAISE EXCEPTION 'member.account_status cannot be modified from a client context.' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ingest_commerce_event(p_tenant uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_event text := p_payload->>'event_name'; v_eid text := p_payload->>'event_id';
  v_campaign uuid := nullif(p_payload->>'campaign_id','')::uuid; v_owner uuid;
  v_order text := nullif(p_payload->>'order_id',''); v_tid text := p_payload->>'pulse_tid';
  v_cur text := upper(nullif(p_payload->>'currency','')); v_val numeric := nullif(p_payload->>'value','')::numeric;
  v_disp text := 'GBP'; v_money jsonb; v_fx jsonb; v_class text; v_id uuid; v_istest boolean := coalesce((p_payload->>'is_test_fixture')::boolean,false);
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthorized'); END IF;
  IF v_event IS NULL OR v_eid IS NULL THEN RETURN jsonb_build_object('status','rejected','reason','event_name_and_event_id_required'); END IF;

  -- tenant/campaign ownership (never trust browser-supplied tenant blindly)
  IF v_campaign IS NOT NULL THEN
    SELECT tenant_id INTO v_owner FROM public.campaign_builder_drafts WHERE id=v_campaign;
    IF v_owner IS NULL OR v_owner <> p_tenant THEN
      RETURN jsonb_build_object('status','rejected','reason','campaign_not_owned_by_tenant'); END IF;
  END IF;

  -- purchase-level dedup (browser+server same order)
  IF v_event='PURCHASE' AND v_order IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.commerce_events WHERE tenant_id=p_tenant AND event_name='PURCHASE' AND order_id=v_order) THEN
      RETURN jsonb_build_object('status','DEDUP_ORDER','order_id',v_order,'note','canonical purchase already recorded; not double-counted'); END IF;
  END IF;

  -- revenue currency preservation + real FX (never LLM FX)
  IF v_event='PURCHASE' AND v_val IS NOT NULL AND v_cur IS NOT NULL THEN
    v_money := public.normalize_money(v_val, v_cur, v_disp);
    v_fx := public.get_fx_rate(v_cur, v_disp, 168);
  END IF;

  -- attribution classification
  v_class := CASE
    WHEN v_tid IS NOT NULL AND v_campaign IS NOT NULL THEN 'DIRECTLY_ATTRIBUTED'
    WHEN (p_payload->'click_ids') IS NOT NULL AND p_payload->'click_ids' <> '{}'::jsonb THEN 'PLATFORM_ATTRIBUTED'
    WHEN v_tid IS NOT NULL OR (p_payload->>'utm_campaign') IS NOT NULL THEN 'INFERRED'
    ELSE 'UNATTRIBUTED' END;

  INSERT INTO public.commerce_events(event_id,tenant_id,business_id,campaign_id,campaign_execution_id,creative_id,product_id,
    opportunity_id,decision_id,pulse_tid,event_name,event_time,event_source,page_url,destination_id,market,currency,value,order_id,
    session_id,anon_id,click_ids,source_platform,source_adapter,attribution,attribution_class,raw_provider_ref,
    original_amount,original_currency,converted_amount,display_currency,fx_rate,fx_rate_source,fx_rate_timestamp,is_test_fixture,provenance)
  VALUES (v_eid,p_tenant, nullif(p_payload->>'business_id','')::uuid, v_campaign, nullif(p_payload->>'campaign_execution_id','')::uuid,
    nullif(p_payload->>'creative_id','')::uuid, nullif(p_payload->>'product_id','')::uuid,
    nullif(p_payload->>'opportunity_id','')::uuid, nullif(p_payload->>'decision_id','')::uuid, v_tid,
    v_event, coalesce(nullif(p_payload->>'event_time','')::timestamptz, now()), coalesce(p_payload->>'event_source','BROWSER'),
    p_payload->>'page_url', p_payload->>'destination_id', p_payload->>'market', v_cur, v_val, v_order,
    p_payload->>'session_id', p_payload->>'anon_id', coalesce(p_payload->'click_ids','{}'::jsonb),
    p_payload->>'source_platform', p_payload->>'source_adapter', coalesce(p_payload->'attribution','{}'::jsonb), v_class,
    p_payload->>'raw_provider_ref',
    CASE WHEN v_event='PURCHASE' THEN v_val END, CASE WHEN v_event='PURCHASE' THEN v_cur END,
    nullif(v_money->>'converted_amount','')::numeric, CASE WHEN v_money IS NOT NULL THEN v_disp END,
    nullif(v_fx->>'rate','')::numeric, v_fx->>'source', nullif(v_fx->>'fetched_at','')::timestamptz,
    v_istest, coalesce(p_payload->'provenance','{}'::jsonb))
  ON CONFLICT (tenant_id,event_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN RETURN jsonb_build_object('status','DEDUP_EVENT','event_id',v_eid,'note','idempotent; duplicate browser/server event ignored'); END IF;
  RETURN jsonb_build_object('status','INGESTED','id',v_id,'event_name',v_event,'attribution_class',v_class,
    'converted_amount',nullif(v_money->>'converted_amount','')::numeric,'display_currency',CASE WHEN v_money IS NOT NULL THEN v_disp END,
    'is_test_fixture',v_istest);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ingest_ebay_listings(p_product_id uuid, p_marketplace text, p_items jsonb, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_gid uuid := public.fn_global_intelligence_uid();
  v_prod public.commerce_products%rowtype;
  v_name text; v_mkt text := upper(btrim(coalesce(p_marketplace,'')));
  v_iso text; it jsonb; v_rel jsonb; v_match text; v_title text; v_itemid text;
  v_returned int := 0; v_matched int := 0; v_likely int := 0; v_amb int := 0; v_nomatch int := 0;
  v_ingested int := 0; v_seller_seen int := 0; v_details jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('status','not_item_array','note','API/credential issue; marketplace evidence unchanged, never zeroed');
  END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_name := coalesce(v_prod.extended->>'normalized_name', v_prod.title);
  -- derive ISO market from marketplace id (EBAY_US -> US); default UNKNOWN
  v_iso := CASE WHEN v_mkt LIKE 'EBAY\_%' THEN split_part(v_mkt,'_',2) ELSE NULL END;

  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_returned := v_returned + 1;
    IF it ? 'seller' THEN v_seller_seen := v_seller_seen + 1; END IF; -- observed but NOT persisted
    v_title := it->>'title';
    v_rel := public.fn_meta_ad_relevance(v_name, v_title, NULL);
    v_match := v_rel->>'match'; v_itemid := it->>'itemId';
    v_details := v_details || jsonb_build_array(jsonb_build_object('item_id',v_itemid,'match',v_match));
    IF v_match='MATCHED' THEN v_matched:=v_matched+1; ELSIF v_match='LIKELY_MATCH' THEN v_likely:=v_likely+1;
    ELSIF v_match='AMBIGUOUS' THEN v_amb:=v_amb+1; ELSE v_nomatch:=v_nomatch+1; END IF;

    IF v_match IN ('MATCHED','LIKELY_MATCH') AND NOT p_dry_run THEN
      INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,evidence,provenance,confidence,observed_at,source_event_at,dedup_key,visibility)
      VALUES (v_gid, p_product_id, 'MARKETPLACE_ACTIVITY',
        -- PUBLIC-ONLY whitelist; no seller/member identity
        jsonb_build_object('marketplace',v_mkt,'market',v_iso,'item_id',v_itemid,'title',v_title,
          'price', nullif(it->'price'->>'value','')::numeric, 'currency', it->'price'->>'currency',
          'condition', it->>'condition', 'category', (it->'categories'->0->>'categoryName'),
          'item_country', it->'itemLocation'->>'country', 'match', v_match,
          'activity_type','ACTIVE_LISTING',
          'claim_safety','active listing presence only; NOT sales/demand/orders/revenue/conversion/winner'),
        jsonb_build_array(jsonb_build_object('item_id',v_itemid,'item_web_url', it->>'itemWebUrl',
          'image_url', it->'image'->>'imageUrl','observed_at', now())),
        jsonb_build_object('source','EBAY_BROWSE_API','api','buy/browse/v1/item_summary/search',
          'marketplace',v_mkt,'relevance',v_rel,
          'exemption','no_seller_or_member_identifiers_persisted (eBay account-deletion exemption data contract)'),
        coalesce((v_rel->>'relevance_score')::numeric,0.5), now(), NULL, 'ebay:'||v_mkt||':'||v_itemid, 'GLOBAL_SAFE')
      ON CONFLICT (user_id, dedup_key) DO NOTHING;
      IF FOUND THEN v_ingested := v_ingested + 1; END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'marketplace',v_mkt,'market',v_iso,
    'items_returned',v_returned,'MATCHED',v_matched,'LIKELY_MATCH',v_likely,'AMBIGUOUS',v_amb,'NO_MATCH',v_nomatch,
    'ingested_signals',v_ingested,'seller_fields_seen_but_not_persisted',v_seller_seen,
    'marketplace_activity_state', CASE WHEN (v_matched+v_likely)>0 THEN 'OBSERVED' ELSE 'NO_PRODUCT_MATCH' END,
    'claim_safety','MARKETPLACE_ACTIVITY = active listings only; competition/saturation signal, NOT demand/sales',
    'details',v_details);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ingest_meta_ads(p_product_id uuid, p_market text, p_ads jsonb, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_gid uuid := public.fn_global_intelligence_uid(); v_prod public.commerce_products%rowtype;
  v_name text; v_mkt text := upper(btrim(coalesce(p_market,''))); ad jsonb; v_rel jsonb; v_match text;
  v_text text; v_returned int := 0; v_matched int := 0; v_likely int := 0; v_amb int := 0; v_nomatch int := 0; v_ingested int := 0;
  v_pages text[] := '{}'; v_details jsonb := '[]'::jsonb; v_adid text;
BEGIN
  -- auth-error safety: if handed a raw error body / non-array, do not process as 0 matches
  IF jsonb_typeof(p_ads) <> 'array' THEN
    RETURN jsonb_build_object('status','not_ad_array','response_state', public.fn_meta_response_state(coalesce(p_ads,'{}'::jsonb)),
      'note','credential/API operational issue; advertising evidence unchanged, never zeroed');
  END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_name := coalesce(v_prod.extended->>'normalized_name', v_prod.title);
  FOR ad IN SELECT * FROM jsonb_array_elements(p_ads) LOOP
    v_returned := v_returned + 1;
    v_text := coalesce((SELECT string_agg(x,' ') FROM jsonb_array_elements_text(coalesce(ad->'ad_creative_bodies','[]'::jsonb)) x), '');
    v_rel := public.fn_meta_ad_relevance(v_name, v_text, ad->>'page_name');
    v_match := v_rel->>'match'; v_adid := ad->>'id';
    v_details := v_details || jsonb_build_array(jsonb_build_object('ad_id',v_adid,'page_name',ad->>'page_name','match',v_match));
    IF v_match='MATCHED' THEN v_matched:=v_matched+1; ELSIF v_match='LIKELY_MATCH' THEN v_likely:=v_likely+1;
    ELSIF v_match='AMBIGUOUS' THEN v_amb:=v_amb+1; ELSE v_nomatch:=v_nomatch+1; END IF;
    IF v_match IN ('MATCHED','LIKELY_MATCH') THEN
      v_pages := array_append(v_pages, ad->>'page_id');
      IF NOT p_dry_run THEN
        INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,evidence,provenance,confidence,observed_at,source_event_at,dedup_key,visibility)
        VALUES (v_gid, p_product_id, 'ADVERTISING_ACTIVITY',
          jsonb_build_object('market',v_mkt,'advertiser_page',ad->>'page_name','page_id',ad->>'page_id','ad_id',v_adid,'platforms',ad->'publisher_platforms','match',v_match),
          jsonb_build_array(jsonb_build_object('ad_id',v_adid,'snapshot_url', public.fn_sanitize_ad_snapshot_url(ad->>'ad_snapshot_url'),'delivery_start',ad->>'ad_delivery_start_time')),
          jsonb_build_object('source','META_AD_LIBRARY','api_version','v26.0','relevance',v_rel),
          coalesce((v_rel->>'relevance_score')::numeric,0.5), now(), nullif(ad->>'ad_delivery_start_time','')::timestamptz, 'meta:'||v_adid, 'GLOBAL_SAFE')
        ON CONFLICT (user_id, dedup_key) DO NOTHING;
        IF FOUND THEN v_ingested := v_ingested + 1; END IF;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'target_market',v_mkt,
    'ads_returned',v_returned,'MATCHED',v_matched,'LIKELY_MATCH',v_likely,'AMBIGUOUS',v_amb,'NO_MATCH',v_nomatch,
    'distinct_advertisers',(SELECT count(DISTINCT p) FROM unnest(v_pages) p),'ingested_signals',v_ingested,
    'advertising_activity_state', CASE WHEN (v_matched+v_likely)>0 THEN 'OBSERVED' ELSE 'NO_PRODUCT_MATCH' END,'details',v_details);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ingest_search_demand_for_product(p_product_id uuid, p_market text, p_source text, p_keywords jsonb, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_gid uuid := public.fn_global_intelligence_uid();
  v_prod public.commerce_products%rowtype; v_name text; v_mkt text := upper(btrim(coalesce(p_market,'')));
  k jsonb; v_rel jsonb; v_relv text; v_intent text; v_vol numeric;
  v_trans numeric := 0; v_comm numeric := 0; v_total numeric := 0; v_compsum numeric := 0; v_compn int := 0;
  v_cpc_min numeric; v_cpc_max numeric; v_qcount int := 0; v_relcount int := 0;
  v_headline jsonb; v_headvol numeric := -1; v_cvline jsonb; v_cvvol numeric := -1;
  v_hist jsonb; v_season jsonb; v_momentum jsonb;
  v_ts numeric; v_cs numeric; v_vs numeric; v_comps numeric; v_bi numeric; v_band text;
  v_details jsonb := '[]'::jsonb; v_dedup text; v_conf numeric; v_ln_max numeric := ln(50001);
BEGIN
  IF jsonb_typeof(p_keywords) <> 'array' THEN RETURN jsonb_build_object('status','not_keyword_array'); END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_name := coalesce(v_prod.extended->>'normalized_name', v_prod.title);

  FOR k IN SELECT * FROM jsonb_array_elements(p_keywords) LOOP
    v_qcount := v_qcount + 1;
    v_rel := public.fn_classify_search_query_relevance(v_name, k->>'query');
    v_relv := v_rel->>'relevance';
    v_intent := lower(coalesce(k->>'intent_label',''));
    v_vol := CASE WHEN (k->>'search_volume') ~ '^[0-9]+$' THEN (k->>'search_volume')::numeric ELSE NULL END;
    -- Only DIRECT_PRODUCT + CLOSE_VARIANT count toward buyer intent. AMBIGUOUS/INFORMATIONAL/SERVICE/ACCESSORY/IRRELEVANT excluded.
    IF v_relv IN ('DIRECT_PRODUCT','CLOSE_VARIANT') THEN
      v_relcount := v_relcount + 1; v_total := v_total + coalesce(v_vol,0);
      IF v_intent='transactional' THEN v_trans := v_trans + coalesce(v_vol,0);
      ELSIF v_intent='commercial' THEN v_comm := v_comm + coalesce(v_vol,0); END IF;
      IF (k->>'competition_index') ~ '^[0-9]+' THEN v_compsum := v_compsum + (k->>'competition_index')::numeric; v_compn := v_compn+1; END IF;
      IF (k->>'cpc') ~ '^[0-9]' THEN
        v_cpc_min := least(coalesce(v_cpc_min,(k->>'cpc')::numeric),(k->>'cpc')::numeric);
        v_cpc_max := greatest(coalesce(v_cpc_max,(k->>'cpc')::numeric),(k->>'cpc')::numeric);
      END IF;
      IF v_relv='DIRECT_PRODUCT' AND coalesce(v_vol,0) > v_headvol THEN v_headvol := coalesce(v_vol,0); v_headline := k;
      ELSIF v_relv='CLOSE_VARIANT' AND coalesce(v_vol,0) > v_cvvol THEN v_cvvol := coalesce(v_vol,0); v_cvline := k; END IF;
    END IF;
    v_details := v_details || jsonb_build_array(jsonb_build_object('query',k->>'query','relevance',v_relv,'intent',v_intent,
      'search_volume',v_vol,'competition_index',k->>'competition_index','cpc',k->>'cpc'));
  END LOOP;

  v_headline := coalesce(v_headline, v_cvline);
  IF v_headline IS NULL THEN
    RETURN jsonb_build_object('status','no_product_relevant_query','dry_run',p_dry_run,'query_count',v_qcount,'details',v_details);
  END IF;

  v_hist := v_headline->'monthly_history';
  v_season := public.fn_classify_seasonality(v_hist);
  v_momentum := public.fn_search_momentum(v_hist);

  v_ts := least(100, round(100.0 * ln(1+v_trans) / v_ln_max));
  v_cs := least(100, round(100.0 * ln(1+v_comm) / v_ln_max));
  v_vs := least(100, greatest(0, round(100.0 * ln(1+v_total) / v_ln_max)
            + CASE WHEN v_momentum->>'direction'='RISING' THEN 10 WHEN v_momentum->>'direction'='FALLING' THEN -10 ELSE 0 END));
  v_comps := CASE WHEN v_compn>0 THEN round(v_compsum/v_compn) ELSE NULL END;
  v_bi := round(0.40*v_ts + 0.25*v_cs + 0.20*v_vs + 0.15*coalesce(v_comps,0));
  v_band := CASE WHEN v_bi>=85 THEN 'EXCEPTIONAL' WHEN v_bi>=75 THEN 'HIGH' WHEN v_bi>=60 THEN 'GOOD' WHEN v_bi>=40 THEN 'MODERATE' ELSE 'LOW' END;
  v_conf := least(0.80, 0.40 + CASE WHEN jsonb_typeof(v_hist)='array' AND jsonb_array_length(v_hist)>=6 THEN 0.20 ELSE 0 END
                              + CASE WHEN v_relcount>=3 THEN 0.20 ELSE 0 END);
  v_dedup := 'search:'||p_product_id::text||':'||v_mkt||':search_demand';

  IF NOT p_dry_run THEN
    INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,evidence,provenance,confidence,observed_at,source_event_at,dedup_key,visibility)
    VALUES (v_gid, p_product_id, 'SEARCH_DEMAND',
      jsonb_build_object('market',v_mkt,'source_platform',p_source,'headline_query',v_headline->>'query',
        'buyer_intent_score',v_bi,'buyer_intent_band',v_band,
        'subscores',jsonb_build_object('transactional',v_ts,'commercial',v_cs,'volume_growth',v_vs,'advertiser_competition',v_comps),
        'transactional_volume_est',v_trans,'commercial_volume_est',v_comm,'total_relevant_volume_est',v_total,
        'competition_index_avg',v_comps,'cpc_min',v_cpc_min,'cpc_max',v_cpc_max,'cpc_currency','USD',
        'seasonality',v_season,'search_momentum',v_momentum,'relevant_query_count',v_relcount,'query_count',v_qcount,
        'relevance_classifier','fn_classify_search_query_relevance',
        'claim_safety','search interest ESTIMATED (Google-Ads-derived); intent INFERRED; CPC PLATFORM_REPORTED; NOT sales/orders/revenue/conversion'),
      v_details,
      jsonb_build_object('source',p_source,'derivation','GOOGLE_ADS_via_DATAFORSEO','volume','ESTIMATED','intent','INFERRED','cpc','PLATFORM_REPORTED'),
      v_conf, now(), NULL, v_dedup, 'GLOBAL_SAFE')
    ON CONFLICT (user_id, dedup_key) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'market',v_mkt,'headline_query',v_headline->>'query',
    'buyer_intent_score',v_bi,'buyer_intent_band',v_band,
    'subscores',jsonb_build_object('transactional',v_ts,'commercial',v_cs,'volume_growth',v_vs,'advertiser_competition',v_comps),
    'transactional_volume_est',v_trans,'commercial_volume_est',v_comm,'total_relevant_volume_est',v_total,
    'seasonality',v_season->>'class','momentum',v_momentum->>'direction',
    'relevant_query_count',v_relcount,'confidence',v_conf,'details',v_details);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ingest_supplier_product_assets(p_supplier_row uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  r record; prov text; spid text; primary_url text; gallery jsonb; gcount int := 0;
  vid text; has_video boolean; obs timestamptz; g text; inserted int := 0;
  product_has_image boolean; resolved boolean; renderable boolean;
BEGIN
  SELECT * INTO r FROM public.commerce_supplier_products WHERE id=p_supplier_row;
  IF r.id IS NULL THEN RETURN jsonb_build_object('error','SUPPLIER_ROW_NOT_FOUND'); END IF;
  prov := upper(coalesce(r.source,'UNKNOWN'));
  spid := coalesce(r.source_product_id, r.raw->>'pid', r.id::text);
  primary_url := coalesce(nullif(r.image_url,''), r.raw->>'productImage');
  gallery := CASE WHEN jsonb_typeof(r.raw->'productImageSet')='array' THEN r.raw->'productImageSet' ELSE NULL END;
  vid := coalesce(r.supplier_enrichment->'variant'->>'vid', NULL);
  has_video := coalesce((r.raw->>'isVideo')::boolean, false);
  obs := coalesce(r.enrichment_observed_at, r.last_seen_at, r.updated_at, now());

  IF p_persist THEN
    DELETE FROM public.supplier_product_assets WHERE supplier=prov AND supplier_product_id=spid;

    IF primary_url IS NOT NULL THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,asset_identity,
        rights_state,availability,source_url,original_source,is_primary,cache_state,observed_at,provenance)
      VALUES (prov,spid,r.title,'PRIMARY_IMAGE','SUPPLIER_OWN',
        CASE WHEN prov='CJDROPSHIPPING' THEN 'SUPPLIER_PROVIDED' ELSE 'UNKNOWN' END,'AVAILABLE',primary_url,
        r.source,true,'ORIGIN_HOTLINK',obs,
        jsonb_build_object('supplier_product_id',spid,'field','productImage','note','supplier-owned primary image; production caches to Pulse object storage'));
      inserted := inserted+1;
    ELSE
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'IMAGE_UNAVAILABLE','UNAVAILABLE','NO_PRIMARY_IMAGE_IN_SUPPLIER_FEED',r.source,obs);
    END IF;

    -- GALLERY (where the supplier exposes it; else honest unavailable)
    IF gallery IS NOT NULL THEN
      FOR g IN SELECT * FROM jsonb_array_elements_text(gallery) LOOP
        INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,asset_identity,rights_state,availability,source_url,original_source,observed_at,provenance)
        VALUES (prov,spid,r.title,'GALLERY_IMAGE','SUPPLIER_OWN',CASE WHEN prov='CJDROPSHIPPING' THEN 'SUPPLIER_PROVIDED' ELSE 'UNKNOWN' END,'AVAILABLE',g,r.source,obs,jsonb_build_object('field','productImageSet'));
        gcount := gcount+1;
      END LOOP;
    ELSE
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'GALLERY_IMAGE','UNAVAILABLE','GALLERY_NOT_IN_SOURCE_CACHE_REQUIRES_SUPPLIER_DETAIL_FETCH',r.source,obs);
    END IF;

    IF vid IS NOT NULL THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,supplier_variant_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at,provenance)
      VALUES (prov,spid,vid,r.title,'VARIANT_IMAGE','UNAVAILABLE','VARIANT_IMAGE_NOT_IN_SOURCE_CACHE_REQUIRES_SUPPLIER_DETAIL_FETCH',r.source,obs,
        jsonb_build_object('variant', r.supplier_enrichment->'variant'));
    END IF;

    IF has_video THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'VIDEO','UNAVAILABLE','VIDEO_FLAGGED_BUT_URL_NOT_IN_SOURCE_CACHE',r.source,obs);
    END IF;
  END IF;

  product_has_image := (primary_url IS NOT NULL);
  resolved := product_has_image;
  renderable := product_has_image;
  RETURN jsonb_build_object(
    'supplier',prov,'supplier_product_id',spid,'title',r.title,
    'primary_image', primary_url, 'gallery_count', gcount, 'variant_id', vid, 'video_flagged', has_video,
    'assets_written', inserted,
    'flags', jsonb_build_object(
      'PRODUCT_HAS_IMAGE', product_has_image,
      'IMAGE_RESOLVED_BY_PULSE', resolved,
      'IMAGE_RENDERABLE_IN_PULSE', renderable,
      'IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE', (product_has_image AND prov='CJDROPSHIPPING')),
    'note','SOURCE product assets only; separate from generated creative and competitor reference. Original supplier URL + rights preserved for Pulse object-storage caching.',
    'contract','pulse_supplier_product_asset_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_is_sellable_product_entity(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_norm text;
  v_tokens text[];
  v_wc int;
  v_reasons text[] := ARRAY[]::text[];
  v_has_noun boolean;
  v_has_cat boolean;
  v_family text;
  tok text;
  tier1 text[] := ARRAY['innovation','evolution','landscape','funding','venture','capital','startup','startups',
    'ecosystem','dynamics','advancement','adoption','transformation','revolution','geopolitics','inflation',
    'recession','marketing','strategy','governance','ethics','ethical','societal','sustainability','impact',
    'challenges','trend','trends','trending','viral','growth','valuation','valuations','disruption'];
  tier2 text[] := ARRAY['ai','ml','llm','technology','tech','market','markets','industry','economy','economic',
    'business','fitness','wellness','lifestyle','summer','winter','autumn','spring','season','seasonal',
    'software','saas','cloud','crypto','cryptocurrency','blockchain','web3','fintech','intelligence','digital',
    'platform','solutions','services','applications','development','enterprise','automation','analytics','media'];
  multiword_abstract text[] := ARRAY['artificial intelligence','machine learning','venture capital','social media',
    'private equity','supply chain','digital transformation','market evolution','business growth','large language model'];
  product_nouns text[] := ARRAY['blender','mount','holder','feeder','mask','maker','thermometer','remover','lamp',
    'light','bottle','brush','trimmer','clipper','humidifier','purifier','organizer','organiser','dispenser',
    'charger','stand','case','cover','grinder','kettle','warmer','cooler','fan','pump','scale','speaker','earbuds',
    'headphones','headset','watch','strap','cushion','pillow','blanket','mat','rack','backpack','wallet','tumbler',
    'mug','jar','knife','peeler','slicer','opener','sharpener','scrubber','mop','vacuum','cleaner','diffuser',
    'massager','roller','curler','straightener','dryer','razor','shaver','epilator','tweezers','comb','mirror',
    'tracker','doorbell','bulb','adapter','cable','tripod','gimbal','projector','printer','scanner','keyboard',
    'stylus','planner','journal','frame','clock','vase','planter','basket','hanger','shelf','caddy','tray',
    'coaster','leash','collar','harness','bowl','stroller','carrier','fountain','steamer','toaster','fryer',
    'cooker','whisk','grater','timer','shredder','stapler','nightlight'];
  category_only text[] := ARRAY['coffee','tea','shoes','sneakers','footwear','skincare','makeup','cosmetics',
    'clothing','apparel','accessories','accessory','electronics','gadgets','supplements','vitamins','jewelry',
    'jewellery','furniture','decor','toys','tools','beauty','fashion','kitchenware','homeware','stationery',
    'snacks','beverages','activewear','watches','bags','handbags','sunglasses','perfume','fragrance','haircare',
    'petcare','babycare','grooming','gifts'];
  generic_mod text[] := ARRAY['the','a','an','new','best','top','premium','pro','2023','2024','2025','2026',
    'upgraded','latest','hot','sale','deal','amazing','great'];
BEGIN
  v_norm := lower(coalesce(p_name,''));
  v_norm := regexp_replace(v_norm, '[^a-z0-9]+', ' ', 'g');
  v_norm := btrim(regexp_replace(v_norm, '\s+', ' ', 'g'));
  IF v_norm = '' THEN
    RETURN jsonb_build_object('verdict','REJECT','reasons',jsonb_build_array('empty'),'normalized_name',NULL);
  END IF;
  v_tokens := string_to_array(v_norm, ' ');
  v_wc := array_length(v_tokens,1);
  v_has_noun := EXISTS (SELECT 1 FROM unnest(v_tokens) t WHERE t = ANY(product_nouns));
  v_has_cat  := EXISTS (SELECT 1 FROM unnest(v_tokens) t WHERE t = ANY(category_only));

  FOREACH tok IN ARRAY multiword_abstract LOOP
    IF position(tok in v_norm) > 0 THEN v_reasons := array_append(v_reasons, 'abstract_phrase:'||tok); END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM unnest(v_tokens) t WHERE t = ANY(tier1)) THEN
    v_reasons := array_append(v_reasons, 'macro_theme');
  END IF;
  IF NOT v_has_noun AND EXISTS (SELECT 1 FROM unnest(v_tokens) t WHERE t = ANY(tier2)) THEN
    v_reasons := array_append(v_reasons, 'abstract_topic_no_product_noun');
  END IF;
  IF v_wc > 8 THEN v_reasons := array_append(v_reasons, 'too_long'); END IF;

  IF array_length(v_reasons,1) > 0 THEN
    RETURN jsonb_build_object('verdict','REJECT','reasons',to_jsonb(v_reasons),'normalized_name',v_norm);
  END IF;

  IF v_has_noun AND v_wc >= 2 THEN
    SELECT string_agg(t, '-' ORDER BY t) INTO v_family
      FROM (SELECT DISTINCT t FROM unnest(v_tokens) t WHERE t <> ALL(generic_mod)) s;
    RETURN jsonb_build_object('verdict','ACCEPT','reasons',jsonb_build_array('concrete_product_noun_with_modifier'),
      'normalized_name',v_norm,'product_family_key',v_family);
  END IF;

  IF v_has_noun AND v_wc = 1 THEN
    RETURN jsonb_build_object('verdict','AMBIGUOUS','reasons',jsonb_build_array('bare_product_noun_needs_context'),'normalized_name',v_norm);
  END IF;
  IF v_has_cat THEN
    RETURN jsonb_build_object('verdict','AMBIGUOUS','reasons',jsonb_build_array('bare_category_needs_context'),'normalized_name',v_norm);
  END IF;
  RETURN jsonb_build_object('verdict','AMBIGUOUS','reasons',jsonb_build_array('insufficient_product_identity'),'normalized_name',v_norm);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_is_supported_market(p_market text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT upper(btrim(coalesce(p_market,''))) ~ '^[A-Z]{2}$'; $function$
;

CREATE OR REPLACE FUNCTION public.fn_learn_diagnose(p_eval jsonb, p_policy jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  ps jsonb := p_eval->'performance_snapshot';
  spend numeric := nullif(ps->>'spend','')::numeric;
  impr numeric := nullif(ps->>'impressions','')::numeric;
  clicks numeric := nullif(ps->>'clicks','')::numeric;
  ctr numeric := nullif(ps->>'ctr','')::numeric;
  lpv numeric := nullif(ps->>'landing_page_views','')::numeric;
  atc numeric := nullif(ps->>'add_to_cart','')::numeric;
  ic numeric := nullif(ps->>'initiate_checkout','')::numeric;
  purchases numeric := nullif(ps->>'purchases','')::numeric;
  be_cpa numeric := nullif(p_eval->'economics'->>'break_even_cpa','')::numeric;
  caa numeric := nullif(p_eval->>'contribution_after_ads','')::numeric;
  decision text := p_eval->>'decision';
  is_fixture boolean := coalesce((p_eval->'evidence_quality'->>'is_fixture')::boolean,false);
  supplier text := coalesce(p_eval->'provenance'->'inputs'->>'supplier_status','UNKNOWN');
  min_impr numeric := coalesce(nullif(p_policy->>'min_impressions','')::numeric,1000);
  low_ctr numeric := coalesce(nullif(p_policy->>'low_ctr','')::numeric,0.008);
  lpv_low numeric := coalesce(nullif(p_policy->>'lpv_rate_low','')::numeric,0.6);
  atc_low numeric := coalesce(nullif(p_policy->>'atc_rate_low','')::numeric,0.10);
  ic_low numeric := coalesce(nullif(p_policy->>'ic_rate_low','')::numeric,0.5);
  pur_low numeric := coalesce(nullif(p_policy->>'pur_rate_low','')::numeric,0.5);
  min_pur numeric := coalesce(nullif(p_policy->>'min_purchases_decision','')::numeric,5);
  f jsonb := '[]'::jsonb; conf text; has_strong boolean := false; has_neg boolean := false; has_friction boolean := false;
BEGIN
  conf := CASE WHEN is_fixture THEN 'FIXTURE_NONE' ELSE 'LOW' END;
  -- derive contribution locally if the decision engine did not compute it (sub-threshold)
  IF caa IS NULL AND be_cpa IS NOT NULL AND purchases IS NOT NULL THEN
    caa := round(purchases * be_cpa - coalesce(spend,0), 2);
  END IF;

  IF impr IS NOT NULL AND impr >= min_impr AND ctr IS NOT NULL AND ctr < low_ctr THEN
    has_friction := true;
    f := f || jsonb_build_array(jsonb_build_object('code','HIGH_IMPRESSIONS_LOW_CTR','learning_type','HYPOTHESIS',
      'observation','High impressions with low click-through','hypothesis','Possible creative/hook/audience mismatch',
      'evidence',jsonb_build_object('impressions',impr,'ctr',ctr,'threshold',low_ctr),'confidence',conf));
  END IF;
  IF ctr IS NOT NULL AND ctr >= low_ctr AND clicks IS NOT NULL AND clicks > 0 AND lpv IS NOT NULL AND lpv/clicks < lpv_low THEN
    has_friction := true;
    f := f || jsonb_build_array(jsonb_build_object('code','GOOD_CTR_LOW_LANDING_PAGE_VIEW','learning_type','HYPOTHESIS',
      'observation','Clicks not reaching landing page','hypothesis','Possible destination/load/intent mismatch',
      'evidence',jsonb_build_object('clicks',clicks,'landing_page_views',lpv,'rate',round(lpv/clicks,4)),'confidence',conf));
  END IF;
  IF lpv IS NOT NULL AND lpv > 0 AND atc IS NOT NULL AND atc/lpv < atc_low THEN
    has_friction := true;
    f := f || jsonb_build_array(jsonb_build_object('code','GOOD_TRAFFIC_LOW_ADD_TO_CART','learning_type','HYPOTHESIS',
      'observation','Traffic not adding to cart','hypothesis','Possible product/offer/page mismatch',
      'evidence',jsonb_build_object('landing_page_views',lpv,'add_to_cart',atc,'rate',round(atc/lpv,4)),'confidence',conf));
  END IF;
  IF atc IS NOT NULL AND atc > 0 AND ic IS NOT NULL AND ic/atc < ic_low THEN
    has_friction := true;
    f := f || jsonb_build_array(jsonb_build_object('code','ADD_TO_CART_LOW_CHECKOUT','learning_type','HYPOTHESIS',
      'observation','Carts not initiating checkout','hypothesis','Possible pricing/shipping/trust friction',
      'evidence',jsonb_build_object('add_to_cart',atc,'initiate_checkout',ic,'rate',round(ic/atc,4)),'confidence',conf));
  END IF;
  IF ic IS NOT NULL AND ic > 0 AND purchases IS NOT NULL AND purchases/ic < pur_low THEN
    has_friction := true;
    f := f || jsonb_build_array(jsonb_build_object('code','CHECKOUT_LOW_PURCHASE','learning_type','HYPOTHESIS',
      'observation','Checkouts not completing purchase','hypothesis','Possible checkout/payment/trust friction',
      'evidence',jsonb_build_object('initiate_checkout',ic,'purchases',purchases,'rate',round(purchases/ic,4)),'confidence',conf));
  END IF;
  IF purchases IS NOT NULL AND purchases > 0 AND caa IS NOT NULL AND caa < 0 THEN
    has_neg := true;
    f := f || jsonb_build_array(jsonb_build_object('code','PURCHASES_NEGATIVE_CONTRIBUTION','learning_type','DERIVED_FINDING',
      'observation','Purchases occur but contribution after ads is negative','hypothesis','Economics failure (CPA above break-even)',
      'evidence',jsonb_build_object('purchases',purchases,'contribution_after_ads',caa),'confidence',conf));
  END IF;
  IF caa IS NOT NULL AND caa > 0 AND purchases IS NOT NULL AND purchases < min_pur THEN
    f := f || jsonb_build_array(jsonb_build_object('code','POSITIVE_CONTRIBUTION_INSUFFICIENT_SAMPLE','learning_type','DERIVED_FINDING',
      'observation','Positive contribution but sample below threshold','hypothesis','Continue controlled testing before scaling',
      'evidence',jsonb_build_object('purchases',purchases,'contribution_after_ads',caa,'min_sample',min_pur),'confidence',conf));
  END IF;
  IF decision = 'SCALE_CANDIDATE' THEN
    has_strong := true;
    f := f || jsonb_build_array(jsonb_build_object('code','STRONG_VERIFIED_ECONOMICS','learning_type','DERIVED_FINDING',
      'observation','Positive contribution with sufficient evidence','hypothesis','Scale candidate subject to authorization and real-evidence gates',
      'evidence',jsonb_build_object('decision',decision,'contribution_after_ads',caa,'is_fixture',is_fixture),
      'confidence', CASE WHEN is_fixture THEN 'FIXTURE_NONE' ELSE 'MEDIUM' END));
  END IF;
  IF supplier = 'CRITICAL' THEN
    f := f || jsonb_build_array(jsonb_build_object('code','SUPPLIER_CRITICAL_RISK','learning_type','DERIVED_FINDING',
      'observation','Supplier/fulfilment critical status','hypothesis','Scale is blocked until supplier risk resolved',
      'evidence',jsonb_build_object('supplier_status',supplier),'confidence',conf));
  END IF;
  IF has_strong AND (has_neg OR has_friction) THEN
    f := f || jsonb_build_array(jsonb_build_object('code','CONFLICTING_EVIDENCE','learning_type','DERIVED_FINDING',
      'observation','Strong economic signal alongside a funnel/economics contradiction','hypothesis','Do not act on a single overconfident conclusion',
      'evidence',jsonb_build_object('has_strong',true,'has_negative',has_neg,'has_funnel_friction',has_friction),'confidence','LOW'));
  END IF;
  RETURN f;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_learn_evaluate(p_tenant uuid, p_snapshot_id uuid, p_policy jsonb DEFAULT '{}'::jsonb, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  eval jsonb; diag jsonb; recs jsonb; is_fixture boolean; src text; d jsonb; r jsonb;
  exec_id uuid; plat text; win jsonb;
BEGIN
  eval := public.fn_perf_evaluate(p_tenant, p_snapshot_id, p_policy);
  IF (eval->>'error') IS NOT NULL THEN RETURN eval; END IF;   -- cross_tenant / not found handled here

  diag := public.fn_learn_diagnose(eval, p_policy);
  recs := public.fn_learn_recommend(eval, diag);
  is_fixture := coalesce((eval->'evidence_quality'->>'is_fixture')::boolean,false);
  src := eval->'evidence_quality'->>'source_class';
  exec_id := nullif(eval->>'campaign_execution_id','')::uuid;
  plat := eval->'provenance'->>'platform';
  win := jsonb_build_object('window_start', eval->'provenance'->>'window_start','window_end', eval->'provenance'->>'window_end');

  IF p_persist THEN
    FOR d IN SELECT * FROM jsonb_array_elements(diag) LOOP
      INSERT INTO public.performance_learnings(tenant_id, performance_snapshot_id, campaign_execution_id,
        learning_type, code, observation, hypothesis, evidence, evidence_quality, confidence,
        is_fixture, platform, time_window, provenance)
      VALUES (p_tenant, p_snapshot_id, exec_id, d->>'learning_type', d->>'code', d->>'observation', d->>'hypothesis',
        d->'evidence', src, d->>'confidence', is_fixture, plat, win, jsonb_build_object('engine','pulse_perf_learn_v1'));
    END LOOP;
    FOR r IN SELECT * FROM jsonb_array_elements(recs) LOOP
      INSERT INTO public.performance_learnings(tenant_id, performance_snapshot_id, campaign_execution_id,
        learning_type, code, recommended_action, action_scope, observation, evidence, evidence_quality, confidence,
        execution_authorization_required, executable, is_fixture, platform, time_window, provenance)
      VALUES (p_tenant, p_snapshot_id, exec_id, 'RECOMMENDATION', r->>'action', r->>'action', 'CAMPAIGN', r->>'reason',
        r->'evidence', src, r->>'confidence', true, false, is_fixture, plat, win,
        jsonb_build_object('expected_learning_objective', r->>'expected_learning_objective','risk', r->>'risk'));
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'snapshot_id', p_snapshot_id, 'tenant_id', p_tenant,
    'decision', eval->>'decision',
    'diagnostics', diag,
    'recommendations', recs,
    'evidence_quality', eval->'evidence_quality',
    'is_fixture', is_fixture,
    'executable', false,          -- learn/recommend only; never executes
    'winner_eligible', false,     -- WINNER is post-launch real only; never here
    'persisted', p_persist,
    'contract', 'pulse_perf_learn_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_learn_recommend(p_eval jsonb, p_diag jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  is_fixture boolean := coalesce((p_eval->'evidence_quality'->>'is_fixture')::boolean,false);
  d jsonb; code text; recs jsonb := '[]'::jsonb; seen text[] := '{}';
  conflicting boolean := false;
  base_conf text;
  FUNCTION_add text;
BEGIN
  -- detect conflicting evidence first
  FOR d IN SELECT * FROM jsonb_array_elements(p_diag) LOOP
    IF d->>'code' = 'CONFLICTING_EVIDENCE' THEN conflicting := true; END IF;
  END LOOP;

  FOR d IN SELECT * FROM jsonb_array_elements(p_diag) LOOP
    code := d->>'code';
    base_conf := CASE WHEN is_fixture THEN 'FIXTURE_NONE' ELSE coalesce(d->>'confidence','LOW') END;
    -- helper via inline appends per code
    IF code = 'HIGH_IMPRESSIONS_LOW_CTR' THEN
      recs := recs || jsonb_build_array(
        jsonb_build_object('action','TEST_NEW_HOOK','reason','High impressions but low CTR','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Identify a hook that lifts CTR','risk','LOW','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','TEST_NEW_ANGLE','reason','High impressions but low CTR','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Find a stronger message angle','risk','LOW','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','REFINE_AUDIENCE','reason','Low CTR may indicate audience mismatch','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Reach a more responsive audience','risk','MEDIUM','execution_authorization_required',true,'executable',false));
    ELSIF code = 'GOOD_CTR_LOW_LANDING_PAGE_VIEW' THEN
      recs := recs || jsonb_build_array(jsonb_build_object('action','IMPROVE_PRODUCT_PAGE','reason','Clicks not reaching the page (load/destination)','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Reduce click-to-view drop-off','risk','LOW','execution_authorization_required',true,'executable',false));
    ELSIF code = 'GOOD_TRAFFIC_LOW_ADD_TO_CART' THEN
      recs := recs || jsonb_build_array(
        jsonb_build_object('action','IMPROVE_PRODUCT_PAGE','reason','Traffic not adding to cart','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Improve page/product fit','risk','LOW','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','REFINE_OFFER','reason','Weak add-to-cart may be offer-driven','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Test offer framing','risk','MEDIUM','execution_authorization_required',true,'executable',false));
    ELSIF code = 'ADD_TO_CART_LOW_CHECKOUT' THEN
      recs := recs || jsonb_build_array(
        jsonb_build_object('action','REVIEW_PRICE','reason','Carts not checking out (pricing/shipping/trust)','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Test price/shipping proposition','risk','MEDIUM','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','REFINE_OFFER','reason','Checkout friction may be offer-driven','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Test offer/shipping framing','risk','MEDIUM','execution_authorization_required',true,'executable',false));
    ELSIF code = 'CHECKOUT_LOW_PURCHASE' THEN
      recs := recs || jsonb_build_array(jsonb_build_object('action','IMPROVE_PRODUCT_PAGE','reason','Checkouts not completing (checkout/payment/trust)','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Reduce checkout abandonment','risk','MEDIUM','execution_authorization_required',true,'executable',false));
    ELSIF code = 'PURCHASES_NEGATIVE_CONTRIBUTION' THEN
      recs := recs || jsonb_build_array(
        jsonb_build_object('action','REVIEW_PRICE','reason','Negative contribution after ads','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Restore positive unit economics','risk','MEDIUM','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','REVIEW_SUPPLIER','reason','Cost side may be too high','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Lower landed cost','risk','MEDIUM','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','PAUSE_CANDIDATE','reason','Structurally negative economics','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Stop loss pending review','risk','LOW','execution_authorization_required',true,'executable',false));
    ELSIF code = 'POSITIVE_CONTRIBUTION_INSUFFICIENT_SAMPLE' THEN
      recs := recs || jsonb_build_array(jsonb_build_object('action','CONTINUE_TEST','reason','Positive but sample below threshold','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Accumulate evidence before scaling','risk','LOW','execution_authorization_required',true,'executable',false));
    ELSIF code = 'STRONG_VERIFIED_ECONOMICS' AND NOT conflicting THEN
      recs := recs || jsonb_build_array(jsonb_build_object('action','SCALE_CANDIDATE','reason','Positive contribution with sufficient evidence','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Validate scale under authority gate','risk','MEDIUM','execution_authorization_required',true,'executable',false,'note',CASE WHEN is_fixture THEN 'FIXTURE_ONLY_NON_EXECUTABLE' ELSE 'requires_real_verified_evidence_and_authority' END));
    ELSIF code = 'SUPPLIER_CRITICAL_RISK' THEN
      recs := recs || jsonb_build_array(
        jsonb_build_object('action','REVIEW_SUPPLIER','reason','Supplier critical status','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Resolve fulfilment risk','risk','HIGH','execution_authorization_required',true,'executable',false),
        jsonb_build_object('action','PAUSE_CANDIDATE','reason','Cannot scale under supplier critical risk','evidence',d->'evidence','confidence',base_conf,'expected_learning_objective','Prevent scaling into fulfilment failure','risk','LOW','execution_authorization_required',true,'executable',false));
    END IF;
  END LOOP;

  -- conflicting or empty -> conservative CONTINUE_TEST
  IF conflicting OR jsonb_array_length(recs) = 0 THEN
    recs := recs || jsonb_build_array(jsonb_build_object('action','CONTINUE_TEST','reason',
      CASE WHEN conflicting THEN 'Conflicting evidence; avoid overconfident action' ELSE 'Insufficient diagnostic signal' END,
      'evidence','{}'::jsonb,'confidence','LOW','expected_learning_objective','Gather clearer evidence','risk','LOW','execution_authorization_required',true,'executable',false));
  END IF;
  RETURN recs;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_learning_memory_active(p_tenant uuid, p_include_fixture boolean DEFAULT false)
 RETURNS TABLE(id uuid, statement text, market text, platform text, confidence text, source_class text, is_fixture boolean, is_stale boolean, stale_after timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT m.id, m.statement, m.market, m.platform, m.confidence, m.source_class, m.is_fixture,
         (m.stale_after IS NOT NULL AND now() > m.stale_after) AS is_stale, m.stale_after
  FROM public.performance_learning_memory m
  WHERE m.tenant_id = p_tenant
    AND m.superseded = false
    AND (p_include_fixture OR m.is_fixture = false);
$function$
;

CREATE OR REPLACE FUNCTION public.fn_learning_memory_note(p_tenant uuid, p_product uuid, p_market text, p_platform text, p_statement text, p_sample jsonb DEFAULT '{}'::jsonb, p_confidence text DEFAULT 'LOW'::text, p_source_class text DEFAULT 'UNKNOWN'::text, p_window_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_window_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_is_fixture boolean DEFAULT false, p_ttl_days integer DEFAULT 90)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.performance_learning_memory
    (tenant_id, product_id, market, platform, statement, sample, confidence, source_class,
     window_start, window_end, is_fixture, stale_after)
  VALUES (p_tenant, p_product, p_market, p_platform, p_statement, p_sample, p_confidence, p_source_class,
     p_window_start, p_window_end, p_is_fixture,
     CASE WHEN p_ttl_days IS NULL THEN NULL ELSE now() + make_interval(days => p_ttl_days) END)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_link_candidate_supplier(p_product_id uuid, p_provider text, p_source_product_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_prov text := public.fn_supplier_provider_canon(p_provider);
  v_spid text := btrim(coalesce(p_source_product_id,''));
  v_sup public.commerce_supplier_products%rowtype;
  v_ref jsonb;
  v_refs jsonb;
  v_ext jsonb;
  v_updated int;
BEGIN
  IF v_prov='' OR v_spid='' THEN
    RETURN jsonb_build_object('status','missing_provider_or_source_product_id');
  END IF;

  SELECT * INTO v_sup FROM public.commerce_supplier_products
    WHERE source_product_id=v_spid AND public.fn_supplier_provider_canon(source)=v_prov LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','supplier_row_not_found','provider',v_prov,'source_product_id',v_spid,
      'note','normalize+persist the supplier product (commerce_supplier_products.source=<provider>) before linking');
  END IF;

  SELECT coalesce(extended,'{}'::jsonb) INTO v_ext FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','product_not_found');
  END IF;

  v_ref := jsonb_build_object('provider',v_prov,'source_product_id',v_spid,
                              'supplier_row_id',v_sup.id,'linked_at',now());

  -- one ref per provider: drop any existing same-provider entry, keep the rest, append the new one
  SELECT coalesce(jsonb_agg(e),'[]'::jsonb) INTO v_refs
    FROM jsonb_array_elements(coalesce(v_ext->'supplier_refs','[]'::jsonb)) e
    WHERE upper(coalesce(e->>'provider','')) <> v_prov;
  v_refs := v_refs || jsonb_build_array(v_ref);

  UPDATE public.commerce_products
    SET extended = coalesce(extended,'{}'::jsonb)
        || jsonb_build_object('supplier_refs', v_refs)
        || jsonb_build_object('supplier_ref', v_ref)
        || CASE WHEN v_prov='CJ' THEN jsonb_build_object('cj_source_product_id', v_spid) ELSE '{}'::jsonb END
    WHERE id=p_product_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated=0 THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  RETURN jsonb_build_object('status','ok','provider',v_prov,'source_product_id',v_spid,
    'linked_product',p_product_id,'supplier_refs',v_refs);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_log_auth_event(p_member_id uuid, p_event_type text, p_metadata jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO public.auth_event (member_id, event_type, metadata)
    VALUES (p_member_id, p_event_type, p_metadata)
    RETURNING id INTO v_id;   -- occurred_at intentionally omitted: table DEFAULT now() is authoritative
    RETURN v_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_market_advantage_score(p_dims jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT public.fn_weighted_over_observed(p_dims, jsonb_build_object(
    'offer_gap',25,'creative_gap',20,'audience_gap',15,'price_value_gap',15,'geographic_gap',15,'speed_to_market',10));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_market_candidacy_screen(p_tenant uuid, p_product_id uuid, p_selling_markets text[] DEFAULT NULL::text[], p_shortlist_threshold numeric DEFAULT 55)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb; has_demand boolean;
BEGIN
  -- one cheap product-level demand check (already-held signals), applied as a market-agnostic bonus
  SELECT EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.product_id=p_product_id) INTO has_demand;

  WITH scored AS (
    SELECT u.country_code, u.country_name, u.region, u.default_currency, u.status,
      u.evidence_coverage, u.advertising_intelligence_supported,
      -- existing local price evidence for THIS product in THIS market (already fetched)
      EXISTS(SELECT 1 FROM public.market_price_observations mpo
              WHERE mpo.product_id=p_product_id AND mpo.market=u.country_code) AS has_local_price,
      -- already deep-evaluated?
      EXISTS(SELECT 1 FROM public.product_market_evaluations e
              WHERE e.product_id=p_product_id AND e.country_code=u.country_code
                AND (e.tenant_id=p_tenant OR e.is_fixture)) AS already_evaluated,
      (p_selling_markets IS NULL OR u.country_code = ANY(p_selling_markets)) AS within_selling
    FROM public.ecommerce_market_universe u
    WHERE u.status IN ('ELIGIBLE','LIMITED_EVIDENCE')
  ),
  cand AS (
    SELECT *,
      least(100, round(
          CASE status WHEN 'ELIGIBLE' THEN 40 WHEN 'LIMITED_EVIDENCE' THEN 20 ELSE 0 END
        + evidence_coverage*25
        + CASE WHEN advertising_intelligence_supported='AVAILABLE' THEN 10 ELSE 0 END
        + CASE WHEN has_local_price THEN 15 ELSE 0 END
        + CASE WHEN has_demand THEN 10 ELSE 0 END
      ,1)) AS candidacy
    FROM scored
  )
  SELECT jsonb_build_object(
    'contract','pulse_market_candidacy_screen_v1',
    'product_id', p_product_id,
    'universe_screened', (SELECT count(*) FROM cand),
    'selling_market_constraint', to_jsonb(p_selling_markets),
    'shortlist', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'country', country_code,'name',country_name,'region',region,'currency',default_currency,
        'candidacy', candidacy,'status',status,'coverage',evidence_coverage,
        'advertising', advertising_intelligence_supported,'has_local_price',has_local_price,
        'already_evaluated', already_evaluated,'within_selling_markets',within_selling)
        ORDER BY candidacy DESC, country_code)
      FROM cand WHERE candidacy >= p_shortlist_threshold AND status='ELIGIBLE'),'[]'::jsonb),
    'shortlist_size', (SELECT count(*) FROM cand WHERE candidacy >= p_shortlist_threshold AND status='ELIGIBLE'),
    'ranked_all', coalesce((SELECT jsonb_agg(jsonb_build_object('country',country_code,'candidacy',candidacy,'status',status)
        ORDER BY candidacy DESC, country_code) FROM cand),'[]'::jsonb),
    'weighting', jsonb_build_object('base_eligible',40,'base_limited',20,'coverage_x',25,'advertising',10,'local_price',15,'demand_signal',10,'cap',100),
    'cost', jsonb_build_object('external_api_calls',0,'note','Stage A uses only already-held signals; deep validation (Stage B) is where external calls are spent'),
    'policy','screen is candidacy only; never replaces Product Opportunity Score/Confidence/Sweet Spot/Headroom; UNKNOWN evidence is never treated as favorable')
  INTO result;
  RETURN result;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_market_comparison(p_tenant uuid, p_product_id uuid, p_countries text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (e.country_code) e.country_code, e.market_currency, e.market_opportunity_score,
      e.evidence_confidence, e.market_decision, e.component_scores, e.economics, e.evidence, e.stock_state
    FROM public.product_market_evaluations e
    WHERE e.product_id=p_product_id AND e.country_code = ANY(p_countries) AND e.tenant_id=p_tenant
    ORDER BY e.country_code, e.evaluation_ts DESC
  )
  SELECT jsonb_build_object('contract','pulse_market_comparison_v1','product_id',p_product_id,'countries',to_jsonb(p_countries),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('country', c,
        'evaluation_state', CASE WHEN ev.country_code IS NOT NULL THEN 'EVALUATED'
             WHEN EXISTS(SELECT 1 FROM public.ecommerce_market_universe u WHERE u.country_code=c AND u.status='ELIGIBLE') THEN 'ANALYSIS_REQUIRED'
             WHEN EXISTS(SELECT 1 FROM public.ecommerce_market_universe u WHERE u.country_code=c AND u.status='LIMITED_EVIDENCE') THEN 'LIMITED_EVIDENCE' ELSE 'UNSUPPORTED' END,
        'decision', ev.market_decision,'score', ev.market_opportunity_score,'confidence', ev.evidence_confidence,
        'buyer_intent', ev.component_scores->'buyer_search_intent'->'subscore',
        'competition_saturation_gap', ev.component_scores->'competition_saturation_gap'->'subscore',
        'local_price', ev.evidence->'observed_market_price','currency', ev.market_currency,'stock_state', ev.stock_state,
        'contribution_after_reserve', ev.economics->'contribution_after_reserve','break_even_cpa', ev.economics->'break_even_cpa')
        ORDER BY c) FROM unnest(p_countries) c LEFT JOIN ev ON ev.country_code=c),'[]'::jsonb),
    'note','same product, independent per-country evaluations; evidence never transferred across markets')
  INTO result; RETURN result;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_market_supplier_match(p_spec jsonb, p_sup_title text, p_sup_category text, p_sup_ref text DEFAULT NULL::text, p_shared_identifier boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  traw text; ttoks text[]; fullraw text;
  noun text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'product_noun','[]'::jsonb)) x);
  sub_any text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_subtype_any','[]'::jsonb)) x);
  attr_all text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_attr_all','[]'::jsonb)) x);
  excl text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'excluded_subtype','[]'::jsonb)) x);
  brand text := lower(coalesce(p_spec->>'brand',''));
  cat text := lower(coalesce(p_spec->>'category',''));
  noun_hit boolean := false; sub_hit boolean; attr_ok boolean; excl_hit boolean := false; brand_hit boolean := false;
  cls text; ph text; a text; missing int := 0;
BEGIN
  IF p_sup_title IS NULL OR length(trim(p_sup_title)) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','NO_SUPPLIER_TITLE');
  END IF;
  IF cardinality(noun) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SPEC_MISSING_PRODUCT_NOUN');
  END IF;

  -- TITLE-scoped normalized text (product identity lives in the title, not the category path)
  traw := lower(p_sup_title);
  traw := regexp_replace(traw, 'night[ -]?light', 'nightlight', 'g');
  traw := regexp_replace(traw, 'projection', 'projector', 'g');
  traw := regexp_replace(traw, 'wi[ -]?fi', 'wifi', 'g');
  ttoks := public.fn_text_tokens(traw);
  -- excluded-subtype scans title + category (a taxonomy word can legitimately exclude)
  fullraw := traw || ' ' || lower(coalesce(p_sup_category,''));

  IF cardinality(ttoks) < 2 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SUPPLIER_TITLE_TOO_SPARSE');
  END IF;

  noun_hit := (SELECT bool_or(n = ANY(ttoks) OR position(n in traw) > 0) FROM unnest(noun) n);
  IF cardinality(excl) > 0 THEN
    FOREACH ph IN ARRAY excl LOOP IF position(ph in fullraw) > 0 THEN excl_hit := true; END IF; END LOOP;
  END IF;
  sub_hit := (cardinality(sub_any) = 0)
             OR (SELECT bool_or(s = ANY(ttoks) OR position(s in traw) > 0) FROM unnest(sub_any) s);
  IF cardinality(attr_all) = 0 THEN attr_ok := true;
  ELSE
    FOREACH a IN ARRAY attr_all LOOP IF NOT (a = ANY(ttoks) OR position(a in traw) > 0) THEN missing := missing + 1; END IF; END LOOP;
    attr_ok := (missing = 0);
  END IF;
  IF brand <> '' AND position(brand in traw) > 0 THEN brand_hit := true; END IF;

  IF p_shared_identifier THEN
    cls := 'EXACT_CONFIRMED';
  ELSIF NOT noun_hit THEN
    cls := CASE WHEN cat <> '' AND cat = lower(coalesce(p_sup_category,'')) THEN 'CATEGORY_ONLY' ELSE 'UNRELATED' END;
  ELSIF excl_hit THEN
    cls := 'CATEGORY_ONLY';
  ELSIF sub_hit AND attr_ok THEN
    cls := CASE WHEN brand_hit THEN 'EXACT_CONFIRMED' ELSE 'STRONG_SAME_PRODUCT' END;
  ELSE
    cls := 'CLOSE_COMPARABLE';
  END IF;

  RETURN jsonb_build_object(
    'market_supplier_match', cls,
    'reason', CASE cls
        WHEN 'EXACT_CONFIRMED' THEN CASE WHEN p_shared_identifier THEN 'SHARED_PRODUCT_IDENTIFIER' ELSE 'BRAND_PLUS_SUBTYPE_ATTRS' END
        WHEN 'STRONG_SAME_PRODUCT' THEN 'TITLE_PRODUCT_NOUN_PLUS_SUBTYPE_PLUS_ATTRS_NO_EXCLUDED'
        WHEN 'CLOSE_COMPARABLE' THEN 'TITLE_NOUN_MATCH_SUBTYPE_OR_ATTR_UNPROVEN'
        WHEN 'CATEGORY_ONLY' THEN CASE WHEN excl_hit THEN 'EXCLUDED_SUBTYPE_PRESENT' ELSE 'SAME_CATEGORY_DIFFERENT_PRODUCT' END
        ELSE 'NO_PRODUCT_NOUN_MATCH_IN_TITLE' END,
    'evidence', jsonb_build_object(
        'noun_hit', noun_hit, 'subtype_hit', sub_hit, 'attrs_ok', attr_ok,
        'excluded_subtype_hit', excl_hit, 'brand_hit', brand_hit,
        'shared_identifier', p_shared_identifier, 'supplier_ref', p_sup_ref),
    'note','Product noun/subtype/attrs matched against SUPPLIER TITLE only; category path scanned for excluded subtypes. EXACT_CONFIRMED needs shared identifier or brand+subtype+attrs; unbranded same-type match is STRONG_SAME_PRODUCT.');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_market_timing(p_trend jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE st text := coalesce(p_trend->>'state','NOT_OBSERVED');
        comparable boolean := coalesce((p_trend->>'comparable_periods')::boolean,false);
        g numeric := nullif(p_trend->>'growth_pct','')::numeric;
        stage text := upper(coalesce(p_trend->>'stage',''));
        v_timing text; v_band text;
BEGIN
  IF st <> 'OBSERVED' OR NOT comparable OR g IS NULL THEN
    RETURN jsonb_build_object('market_timing','UNKNOWN','known',false,'reason','no_comparable_reliable_periods');
  END IF;
  IF stage = 'SATURATING' THEN v_timing := 'SATURATING';
  ELSIF stage = 'TOO_EARLY' THEN v_timing := 'TOO_EARLY';
  ELSIF g < 0 THEN v_timing := 'DECLINING';
  ELSIF g < 10 THEN v_timing := 'MATURE';
  ELSIF g < 20 THEN v_timing := 'EMERGING';
  ELSIF g < 50 THEN v_timing := 'ACCELERATING';
  ELSE v_timing := 'STRONG_WINDOW';
  END IF;
  v_band := CASE WHEN g < 10 THEN 'stable' WHEN g < 20 THEN 'emerging' WHEN g < 50 THEN 'trending'
                 WHEN g <= 100 THEN 'strong_acceleration' ELSE 'breakout' END;
  RETURN jsonb_build_object('market_timing',v_timing,'known',true,'growth_pct',g,'growth_band',v_band,
    'provenance','PLATFORM_REPORTED','note','directional; based on comparable-period velocity, not raw volume');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_market_universe_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE affected int; result jsonb;
  -- weights for evidence_coverage (documented): search .30 marketplace .30 supplier .20 advertising .20
BEGIN
  WITH cap AS (
    -- resolve availability of a source for a market: prefer market-specific, else '*'
    SELECT u.country_code,
      (SELECT availability FROM public.provider_capability_registry r
        WHERE r.source='DATAFORSEO' AND r.evidence_category='SEARCH_DEMAND' AND r.market IN (u.country_code,'*')
        ORDER BY (r.market=u.country_code) DESC LIMIT 1) AS search_av,
      (SELECT availability FROM public.provider_capability_registry r
        WHERE r.source='EBAY' AND r.evidence_category='MARKETPLACE' AND r.market IN (u.country_code,'*')
        ORDER BY (r.market=u.country_code) DESC LIMIT 1) AS mkt_av_specific,
      (SELECT count(*) FROM public.provider_capability_registry r
        WHERE r.source='EBAY' AND r.evidence_category='MARKETPLACE' AND r.market=u.country_code AND r.availability='AVAILABLE') AS mkt_specific_rows,
      (SELECT availability FROM public.provider_capability_registry r
        WHERE r.source='CJ' AND r.evidence_category='SUPPLIER' AND r.market IN (u.country_code,'*')
        ORDER BY (r.market=u.country_code) DESC LIMIT 1) AS sup_av,
      (SELECT count(*) FROM public.provider_capability_registry r
        WHERE r.source='META_AD_LIBRARY' AND r.evidence_category='ADVERTISING' AND r.market=u.country_code AND r.availability='AVAILABLE') AS meta_rows,
      (u.default_currency='USD' OR EXISTS(SELECT 1 FROM public.fx_rates f WHERE f.quote_currency=u.default_currency)) AS cur_ok
    FROM public.ecommerce_market_universe u WHERE NOT u.is_operator_config
  ),
  derived AS (
    SELECT country_code,
      CASE WHEN search_av='AVAILABLE' THEN 'AVAILABLE' WHEN search_av='SOURCE_BLOCKED' THEN 'BLOCKED' ELSE 'UNSUPPORTED' END AS search_s,
      -- marketplace AVAILABLE only where a market-specific eBay row exists (documented marketplace)
      CASE WHEN mkt_specific_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS mkt_s,
      CASE WHEN sup_av='AVAILABLE' THEN 'AVAILABLE' ELSE 'UNKNOWN' END AS sup_s,
      CASE WHEN meta_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS adv_s,
      CASE WHEN meta_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS exec_s,
      cur_ok
    FROM cap
  ),
  scored AS (
    SELECT country_code, search_s, mkt_s, sup_s, adv_s, exec_s, cur_ok,
      round( (CASE WHEN search_s='AVAILABLE' THEN 0.30 ELSE 0 END
            + CASE WHEN mkt_s='AVAILABLE' THEN 0.30 ELSE 0 END
            + CASE WHEN sup_s='AVAILABLE' THEN 0.20 ELSE 0 END
            + CASE WHEN adv_s='AVAILABLE' THEN 0.20 ELSE 0 END)::numeric, 2) AS cov,
      (search_s='AVAILABLE' AND mkt_s='AVAILABLE' AND sup_s='AVAILABLE' AND cur_ok) AS eligible
    FROM derived
  )
  UPDATE public.ecommerce_market_universe u SET
    currency_supported = s.cur_ok,
    supplier_supported = s.sup_s,
    search_intelligence_supported = s.search_s,
    marketplace_intelligence_supported = s.mkt_s,
    advertising_intelligence_supported = s.adv_s,
    campaign_execution_supported = s.exec_s,
    ecommerce_eligible = s.eligible,
    evidence_coverage = s.cov,
    status = CASE
               WHEN s.eligible THEN 'ELIGIBLE'
               WHEN s.search_s='AVAILABLE' AND s.sup_s='AVAILABLE' AND s.cur_ok THEN 'LIMITED_EVIDENCE'
               WHEN s.search_s='UNSUPPORTED' AND s.mkt_s='UNSUPPORTED' THEN 'UNSUPPORTED'
               ELSE 'UNKNOWN' END,
    basis = jsonb_build_object(
      'derived_from','provider_capability_registry+fx_rates',
      'weights', jsonb_build_object('search',0.30,'marketplace',0.30,'supplier',0.20,'advertising',0.20),
      'note','capability-derived eligibility (Pulse can evaluate) NOT demand; demand is product-specific (Stage B)',
      'dependency','authoritative global ecommerce-eligibility dataset not held by Pulse; universe limited to verified-coverage markets'),
    updated_at = now()
  FROM scored s WHERE s.country_code=u.country_code;
  GET DIAGNOSTICS affected = ROW_COUNT;
  SELECT jsonb_build_object(
    'synced', affected,
    'eligible', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='ELIGIBLE'),
    'limited_evidence', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='LIMITED_EVIDENCE'),
    'unsupported', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='UNSUPPORTED'),
    'unknown', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='UNKNOWN'),
    'universe_size', (SELECT count(*) FROM public.ecommerce_market_universe),
    'external_dependency','AUTHORITATIVE_GLOBAL_ECOMMERCE_ELIGIBILITY_DATASET (not held; universe is capability-derived + configurable)'
  ) INTO result;
  RETURN result;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_approve_asset(p_asset_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m public.media_assets%rowtype;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF m.generation_status IN ('MOCK_FIXTURE','BLOCKED_EXTERNAL_PROVIDER','FAILED') THEN
    RETURN jsonb_build_object('status','blocked_not_production_asset','generation_status',m.generation_status);
  END IF;
  IF m.rights_state IN ('UNKNOWN','PROHIBITED') THEN
    RETURN jsonb_build_object('status','blocked_rights','rights_state',m.rights_state);
  END IF;
  UPDATE public.media_assets SET approval_state='APPROVED', is_launch_safe=true, updated_at=now() WHERE id=p_asset_id;
  RETURN jsonb_build_object('status','APPROVED','asset_id',p_asset_id,'is_launch_safe',true,
    'note','MEDIA approval only — separate from creative-strategy, campaign, spend and activation authorities');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_build_storyboard(p_angle_id uuid, p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; fast boolean; sb jsonb;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  fast := (p_platform='TIKTOK_FEED');
  sb := jsonb_build_array(
    jsonb_build_object('scene_number',1,'duration_target',CASE WHEN fast THEN 2 ELSE 3 END,
      'visual_action', coalesce(a.video_hook,a.hook),
      'motion_instruction', CASE WHEN fast THEN 'Native handheld; jump-cut; on-screen hook text in first second' ELSE 'Clean reveal; hook text overlay; product enters frame' END,
      'text_overlay', a.hook,'voiceover', coalesce(a.video_hook,a.hook),'transition','hard cut'),
    jsonb_build_object('scene_number',2,'duration_target',CASE WHEN fast THEN 3 ELSE 5 END,
      'visual_action','Show the product being used to address: '||coalesce(a.customer_problem,'the task'),
      'motion_instruction', CASE WHEN fast THEN 'Fast POV demonstration' ELSE 'Steady demonstration, medium shots' END,
      'text_overlay', a.headline,'voiceover', a.primary_copy,'transition','cut'),
    jsonb_build_object('scene_number',3,'duration_target',CASE WHEN fast THEN 3 ELSE 4 END,
      'visual_action','Show the calmer outcome / result',
      'motion_instruction','Outcome beauty shot','text_overlay', coalesce(a.supporting_copy,''),'voiceover','', 'transition','cut'),
    jsonb_build_object('scene_number',4,'duration_target',2,
      'visual_action','End card with product + CTA',
      'motion_instruction','Hold on product; CTA text','text_overlay', a.cta,'voiceover', a.cta,'transition','end'));
  RETURN sb;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_campaign_safety_gate(p_tenant uuid, p_asset_ids jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_rejected jsonb; v_ok jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('asset_id',m.id,'reason',
      CASE WHEN m.generation_status='MOCK_FIXTURE' THEN 'MOCK_FIXTURE'
           WHEN m.generation_status IN ('BLOCKED_EXTERNAL_PROVIDER','FAILED') THEN m.generation_status
           WHEN m.rights_state IN ('UNKNOWN','PROHIBITED') THEN 'RIGHTS_'||m.rights_state
           WHEN m.approval_state<>'APPROVED' OR NOT m.is_launch_safe THEN 'NOT_APPROVED'
           ELSE 'OTHER' END)),'[]'::jsonb)
    INTO v_rejected
  FROM public.media_assets m
  WHERE m.tenant_id=p_tenant AND m.id IN (SELECT (jsonb_array_elements_text(p_asset_ids))::uuid)
    AND (m.generation_status IN ('MOCK_FIXTURE','BLOCKED_EXTERNAL_PROVIDER','FAILED')
         OR m.rights_state IN ('UNKNOWN','PROHIBITED')
         OR m.approval_state<>'APPROVED' OR NOT m.is_launch_safe);

  SELECT coalesce(jsonb_agg(m.id),'[]'::jsonb) INTO v_ok
  FROM public.media_assets m
  WHERE m.tenant_id=p_tenant AND m.id IN (SELECT (jsonb_array_elements_text(p_asset_ids))::uuid)
    AND m.generation_status='GENERATED' AND m.rights_state NOT IN ('UNKNOWN','PROHIBITED')
    AND m.approval_state='APPROVED' AND m.is_launch_safe;

  RETURN jsonb_build_object('gate', CASE WHEN jsonb_array_length(v_rejected)=0 THEN 'PASS' ELSE 'REJECTED' END,
    'rejected',v_rejected,'accepted',v_ok,'activation','NOT_AUTHORIZED','spend_authorization',0);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_complete_image_real(p_job_id uuid, p_tenant uuid, p_provider text, p_provider_job_id text, p_storage_ref text, p_mime text, p_width integer, p_height integer, p_actual_cost numeric, p_cost_currency text, p_product_id uuid, p_country_code text, p_source_asset_refs jsonb, p_prompt text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; v_asset uuid; v_prov jsonb;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF p_provider IS NULL OR p_provider='' OR p_provider='MOCK' THEN
    RETURN jsonb_build_object('status','REAL_PROVIDER_REQUIRED','note','a real provider is required; MOCK cannot complete a real asset');
  END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  v_prov := coalesce(p_provenance,'{}'::jsonb)
    || jsonb_build_object('generated', true, 'provider', p_provider, 'provider_job_id', p_provider_job_id,
         'prompt', p_prompt, 'source_asset_refs', coalesce(p_source_asset_refs,'[]'::jsonb),
         'generation_mode', 'IMAGE_EDIT_FROM_PRODUCT_ASSET',
         'note','REAL provider-generated asset; product-preserving edit of a rights-clear source asset. Requires human approval before launch.');

  INSERT INTO public.media_assets(tenant_id, product_id, creative_id, source_asset_id, media_type, source_type,
    provider, provider_job_id, rights_state, generation_status, approval_state, mime_type, width, height,
    aspect_ratio, storage_ref, spec_ref, provenance, is_launch_safe,
    country_code, generation_mode, usage_permission, cost_amount, cost_currency, source_asset_refs,
    creative_strategy_ref, ad_variant_ref)
  VALUES (p_tenant, p_product_id, j.static_creative_id, NULL, 'IMAGE', 'PULSE_GENERATED_IMAGE',
    p_provider, p_provider_job_id, 'GENERATED', 'GENERATED', 'IN_REVIEW', coalesce(p_mime,'image/png'),
    p_width, p_height, coalesce(j.aspect_ratio,'1:1'), p_storage_ref,
    jsonb_build_object('prompt', p_prompt, 'static_creative_spec', j.static_creative_spec), v_prov, false,
    p_country_code, 'IMAGE_EDIT_FROM_PRODUCT_ASSET', 'INTERNAL_ADVERTISING_TEST', p_actual_cost,
    coalesce(p_cost_currency,'USD'), coalesce(p_source_asset_refs,'[]'::jsonb),
    a.brief_id, j.static_creative_id)
  RETURNING id INTO v_asset;

  UPDATE public.media_image_jobs
     SET status='GENERATED_REVIEW_REQUIRED', provider=p_provider, provider_job_id=p_provider_job_id,
         output_asset_refs=jsonb_build_array(v_asset), actual_cost=p_actual_cost,
         cost_currency=coalesce(p_cost_currency,'USD'), updated_at=now()
   WHERE id=p_job_id;

  INSERT INTO public.media_job_costs(tenant_id, job_id, operation_type, provider, estimated_cost, actual_cost, currency)
  VALUES (p_tenant, p_job_id, 'IMAGE_GENERATION_REAL', p_provider, coalesce(j.estimated_cost,0), p_actual_cost, coalesce(p_cost_currency,'USD'));

  RETURN jsonb_build_object('status','GENERATED_REAL','asset_id',v_asset,'job_id',p_job_id,
    'is_launch_safe',false,'approval_state','IN_REVIEW','provider',p_provider,'actual_cost',p_actual_cost,'cost_currency',coalesce(p_cost_currency,'USD'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_create_image_job(p_tenant uuid, p_angle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype; v_provider text; v_status text; v_id uuid; v_sc public.ad_studio_static_creatives%rowtype;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  SELECT * INTO v_sc FROM public.ad_studio_static_creatives WHERE angle_id=p_angle_id LIMIT 1;
  v_provider := public.fn_media_provider_for('IMAGE');
  v_status := CASE WHEN v_provider IS NULL THEN 'BLOCKED_EXTERNAL_PROVIDER' ELSE 'READY' END;

  INSERT INTO public.media_image_jobs(tenant_id,angle_id,static_creative_id,input_asset_refs,product_facts,visual_concept,
    static_creative_spec,brand_context,platform,aspect_ratio,safe_area,generation_instructions,provider,status,
    estimated_cost,cost_currency,provenance)
  VALUES (p_tenant,p_angle_id,v_sc.id,coalesce(b.product_assets,'[]'::jsonb),
    jsonb_build_object('product_name',b.product_name,'features',b.product_features),
    a.visual_concept, coalesce(to_jsonb(v_sc),'{}'::jsonb), coalesce(v_sc.brand_context,'{}'::jsonb),
    'META', coalesce(v_sc.aspect_ratio,'1:1'), coalesce(v_sc.safe_area,'20%'),
    a.static_creative_brief, v_provider, v_status, 0, coalesce(b.market_currency,'EUR'),
    jsonb_build_object('brief_id',b.id,'angle_id',a.id))
  RETURNING id INTO v_id;

  INSERT INTO public.media_job_costs(tenant_id,job_id,operation_type,provider,estimated_cost,currency)
  VALUES (p_tenant,v_id,'IMAGE_GENERATION',v_provider,0,coalesce(b.market_currency,'EUR'));

  RETURN jsonb_build_object('status',v_status,'job_id',v_id,'provider',coalesce(v_provider,'NONE_CONFIGURED'),
    'note',CASE WHEN v_provider IS NULL THEN 'no image provider configured (BLOCKED_EXTERNAL_IMAGE_PROVIDER); use mock path for architecture verification' ELSE 'ready to dispatch' END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_create_video_job(p_tenant uuid, p_angle_id uuid, p_source_image_asset_id uuid, p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; src public.media_assets%rowtype; v_provider text; v_status text; v_id uuid;
  v_sb jsonb; v_scene jsonb; v_scan jsonb; v_all_scan jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO src FROM public.media_assets WHERE id=p_source_image_asset_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','source_asset_not_found'); END IF;
  IF src.rights_state IN ('UNKNOWN','PROHIBITED') THEN
    RETURN jsonb_build_object('status','blocked_rights','rights_state',src.rights_state,
      'note','source image rights UNKNOWN/PROHIBITED cannot seed a video creative');
  END IF;

  v_sb := public.fn_media_build_storyboard(p_angle_id,p_platform);
  v_provider := public.fn_media_provider_for('VIDEO');
  v_status := CASE WHEN v_provider IS NULL THEN 'BLOCKED_EXTERNAL_PROVIDER' ELSE 'READY' END;

  INSERT INTO public.media_video_jobs(tenant_id,angle_id,source_image_asset_id,product_facts,video_hook,script,storyboard,
    platform,duration_target,aspect_ratio,motion_instructions,text_overlays,cta,provider,status,estimated_cost,cost_currency,provenance)
  VALUES (p_tenant,p_angle_id,p_source_image_asset_id,'{}'::jsonb,a.video_hook,a.video_script,v_sb,
    p_platform, CASE WHEN p_platform='TIKTOK_FEED' THEN 12 ELSE 15 END, '9:16',
    'derived from storyboard', jsonb_build_array(a.hook,a.headline,a.cta), a.cta, v_provider, v_status, 0, 'EUR',
    jsonb_build_object('angle_id',a.id,'source_image_asset_id',p_source_image_asset_id,'source_lineage',src.provenance))
  RETURNING id INTO v_id;

  -- persist scenes + claim-scan overlays
  FOR v_scene IN SELECT * FROM jsonb_array_elements(v_sb) LOOP
    v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ', v_scene->>'text_overlay', v_scene->>'voiceover'));
    v_all_scan := v_all_scan || v_scan;
    INSERT INTO public.media_video_scenes(video_job_id,tenant_id,scene_number,duration_target,source_asset_ref,visual_action,motion_instruction,text_overlay,voiceover,transition,claim_violations)
    VALUES (v_id,p_tenant,(v_scene->>'scene_number')::int,(v_scene->>'duration_target')::numeric,p_source_image_asset_id,
      v_scene->>'visual_action',v_scene->>'motion_instruction',v_scene->>'text_overlay',v_scene->>'voiceover',v_scene->>'transition',v_scan);
  END LOOP;

  UPDATE public.media_video_jobs SET claim_violations=v_all_scan WHERE id=v_id;
  INSERT INTO public.media_job_costs(tenant_id,job_id,operation_type,provider,estimated_cost,currency)
  VALUES (p_tenant,v_id,'IMAGE_TO_VIDEO',v_provider,0,'EUR');

  RETURN jsonb_build_object('status',v_status,'video_job_id',v_id,'provider',coalesce(v_provider,'NONE_CONFIGURED'),
    'platform',p_platform,'scenes',jsonb_array_length(v_sb),'source_lineage_preserved',(src.provenance IS NOT NULL),
    'claim_violations',v_all_scan);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_creative_live_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_pass int:=0; v_fail int:=0; v_fails jsonb:='[]'::jsonb; v_reg jsonb; v_provider text;
BEGIN
  v_provider := public.fn_media_provider_for('VIDEO');
  IF v_provider IS NULL THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('video_provider_unexpectedly_present'::text); END IF;

  v_reg := public.fn_media_register_provider('SELFTEST_PROVIDER','IMAGE','{"modes":["edit"]}'::jsonb,
             '{"model":"x","api_key":"SHOULD_BE_STRIPPED","endpoint":"https://e"}'::jsonb);
  IF (v_reg->>'status')='REGISTERED' AND (v_reg->>'stored_secret')='false'
     AND NOT EXISTS (SELECT 1 FROM public.media_providers WHERE name='SELFTEST_PROVIDER' AND (config ? 'api_key'))
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('register_did_not_strip_secret'::text); END IF;

  IF (SELECT (public.fn_media_complete_image_real(gen_random_uuid(),'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'MOCK',NULL,NULL,NULL,NULL,NULL,0,'USD',NULL,'US','[]'::jsonb,'p'))->>'status') IN ('REAL_PROVIDER_REQUIRED','not_found_or_forbidden')
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('real_completion_accepted_mock'::text); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.media_assets WHERE generation_status='MOCK_FIXTURE' AND is_launch_safe) THEN
    v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('mock_fixture_marked_launch_safe'::text); END IF;

  DELETE FROM public.media_providers WHERE name='SELFTEST_PROVIDER';

  RETURN jsonb_build_object('passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,'failures',v_fails);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_generation_result(p_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m public.media_assets%rowtype; j public.media_image_jobs%rowtype;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  SELECT * INTO j FROM public.media_image_jobs WHERE output_asset_refs @> to_jsonb(array[p_asset_id::text]) LIMIT 1;
  RETURN jsonb_build_object(
    'status','OK',
    'provider', m.provider,
    'provider_job_id', m.provider_job_id,
    'media_type', m.media_type,
    'generation_mode', m.generation_mode,
    'source_asset_refs', coalesce(m.source_asset_refs,'[]'::jsonb),
    'specification_ref', m.spec_ref,
    'product_id', m.product_id,
    'country_code', m.country_code,
    'creative_strategy_ref', m.creative_strategy_ref,
    'ad_variant_ref', m.ad_variant_ref,
    'origin_kind', CASE WHEN m.rights_state='GENERATED' OR m.source_type ILIKE '%GENERATED%' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
    'rights_state', m.rights_state,
    'usage_permission', m.usage_permission,
    'generation_timestamp', m.created_at,
    'storage_ref', m.storage_ref,
    'mime_type', m.mime_type,
    'dimensions', jsonb_build_object('width', m.width, 'height', m.height, 'aspect_ratio', m.aspect_ratio),
    'duration', m.duration,
    'cost_amount', m.cost_amount,
    'cost_currency', m.cost_currency,
    'generation_status', m.generation_status,
    'approval_state', m.approval_state,
    'is_launch_safe', m.is_launch_safe,
    'failure_reason', coalesce(m.failure_reason, j.error_state),
    'provenance', m.provenance,
    'contract_complete', (m.provider IS NOT NULL AND m.media_type IS NOT NULL AND m.storage_ref IS NOT NULL
       AND m.rights_state IS NOT NULL AND m.product_id IS NOT NULL AND m.country_code IS NOT NULL
       AND m.cost_currency IS NOT NULL AND m.provenance IS NOT NULL));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_mock_complete_image(p_job_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE j public.media_image_jobs%rowtype; v_asset uuid;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  INSERT INTO public.media_assets(tenant_id,product_id,creative_id,media_type,source_type,provider,provider_job_id,
    rights_state,generation_status,approval_state,mime_type,width,height,aspect_ratio,storage_ref,spec_ref,provenance,is_launch_safe)
  VALUES (p_tenant,(j.provenance->>'product_id')::uuid,j.angle_id,'IMAGE','PULSE_GENERATED_IMAGE','MOCK','mock-'||p_job_id,
    'GENERATED','MOCK_FIXTURE','DRAFT','image/png',1080,1080,coalesce(j.aspect_ratio,'1:1'),
    'mock://image/'||p_job_id||'.png', j.static_creative_spec,
    jsonb_build_object('mock',true,'job_id',p_job_id,'note','MOCK_FIXTURE — architecture verification only, NOT a production launch asset'), false)
  RETURNING id INTO v_asset;
  UPDATE public.media_image_jobs SET status='REVIEW_REQUIRED', output_asset_refs=jsonb_build_array(v_asset),
    actual_cost=0, updated_at=now() WHERE id=p_job_id;
  RETURN jsonb_build_object('status','MOCK_FIXTURE','job_id',p_job_id,'asset_id',v_asset,'is_launch_safe',false);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_provider_for(p_type text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT name FROM public.media_providers
   WHERE enabled AND (media_type=p_type OR media_type='BOTH') ORDER BY created_at LIMIT 1;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_media_register_provider(p_name text, p_media_type text, p_capability jsonb DEFAULT '{}'::jsonb, p_config jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_clean jsonb; v_id uuid; k text;
BEGIN
  IF p_media_type NOT IN ('IMAGE','VIDEO','BOTH') THEN
    RETURN jsonb_build_object('status','INVALID_MEDIA_TYPE');
  END IF;
  v_clean := coalesce(p_config,'{}'::jsonb);
  FOR k IN SELECT jsonb_object_keys(v_clean) LOOP
    IF lower(k) ~ '(api[_-]?key|apikey|secret|token|authorization|password|bearer|private[_-]?key)' THEN
      v_clean := v_clean - k;
    END IF;
  END LOOP;
  v_clean := jsonb_set(v_clean, '{capability}', coalesce(p_capability,'{}'::jsonb), true);
  v_clean := jsonb_set(v_clean, '{secret_storage}', to_jsonb('server_side_only: secret lives in the n8n credential / edge-function env, never in this row'::text), true);

  INSERT INTO public.media_providers(name, media_type, enabled, config)
  VALUES (p_name, p_media_type, true, v_clean)
  ON CONFLICT (name) DO UPDATE SET media_type=excluded.media_type, enabled=true, config=excluded.config
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','REGISTERED','provider_id',v_id,'name',p_name,'media_type',p_media_type,
    'stored_secret', false, 'config_keys', (SELECT jsonb_agg(kk) FROM jsonb_object_keys(v_clean) kk));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_register_source_asset(p_tenant uuid, p_product_id uuid, p_creative_id uuid, p_source_type text, p_rights_state text, p_storage_ref text, p_mime text DEFAULT NULL::text, p_aspect text DEFAULT NULL::text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_id uuid;
BEGIN
  IF p_tenant IS NULL THEN RAISE EXCEPTION 'tenant_required'; END IF;
  INSERT INTO public.media_assets(tenant_id,product_id,creative_id,media_type,source_type,rights_state,generation_status,storage_ref,mime_type,aspect_ratio,provenance,is_launch_safe)
  VALUES (p_tenant,p_product_id,p_creative_id,'IMAGE',p_source_type,coalesce(p_rights_state,'UNKNOWN'),'GENERATED',p_storage_ref,p_mime,p_aspect,coalesce(p_provenance,'{}'::jsonb),
    false)  -- launch-safety is only granted at approval
  RETURNING id INTO v_id; RETURN v_id;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_replace_asset(p_angle_id uuid, p_tenant uuid, p_new_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; v_invalidated boolean := false;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  UPDATE public.ad_studio_static_creatives SET product_asset_refs = jsonb_build_array(p_new_asset_id),
    generation_status='GENERATED', asset_url='asset://'||p_new_asset_id
    WHERE angle_id=p_angle_id;
  IF a.review_state='APPROVED' THEN
    UPDATE public.ad_studio_angles SET review_state='REVIEW_REQUIRED', approved_fingerprint=NULL, approved_at=NULL, updated_at=now()
      WHERE id=p_angle_id;
    v_invalidated := true;
  END IF;
  RETURN jsonb_build_object('status','ok','downstream_approval_invalidated',v_invalidated);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_media_retry_image_job(p_job_id uuid, p_tenant uuid, p_error text DEFAULT 'provider_unavailable'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE j public.media_image_jobs%rowtype;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF p_error NOT IN ('rate_limit','provider_unavailable','invalid_asset','unsupported_format','content_policy_failure','timeout','unknown_provider_error') THEN
    p_error := 'unknown_provider_error';
  END IF;
  IF j.retry_count >= j.max_retries THEN
    UPDATE public.media_image_jobs SET status='FAILED', error_state=p_error||' (max_retries_exhausted)', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','FAILED','retry_count',j.retry_count,'note','max retries exhausted; will not retry again (no infinite loop)');
  END IF;
  UPDATE public.media_image_jobs SET retry_count=retry_count+1, error_state=p_error,
    status=CASE WHEN public.fn_media_provider_for('IMAGE') IS NULL THEN 'BLOCKED_EXTERNAL_PROVIDER' ELSE 'QUEUED' END, updated_at=now()
    WHERE id=p_job_id;
  RETURN jsonb_build_object('status','RETRY_SCHEDULED','retry_count',j.retry_count+1,'max_retries',j.max_retries,'error',p_error);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_member_actions_canonical_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
  IF NEW.status IS NULL OR NEW.status = 'suggested' THEN
    NEW.status := 'open';
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_meta_ad_library_market_state(p_market text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE WHEN upper(btrim(coalesce(p_market,''))) = ANY (ARRAY[
    'AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IE','IT','LV','LT','LU','MT','NL',
    'PL','PT','RO','SK','SI','ES','SE','IS','LI','NO','GB','UK'])
    THEN 'AVAILABLE' ELSE 'SOURCE_UNSUPPORTED' END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_meta_ad_relevance(p_product_name text, p_ad_text text, p_page_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE c jsonb := public.fn_classify_ad_product_match(p_product_name, p_ad_text, p_page_name); v text := c->>'match'; m text;
BEGIN
  m := CASE v WHEN 'EXACT_OR_CLOSE_MATCH' THEN 'MATCHED' WHEN 'RELATED' THEN 'LIKELY_MATCH'
              WHEN 'AMBIGUOUS' THEN 'AMBIGUOUS' ELSE 'NO_MATCH' END; -- ACCESSORY, IRRELEVANT -> NO_MATCH
  RETURN jsonb_build_object('match', m, 'classifier_verdict', v, 'basis', c->>'basis',
    'relevance_score', coalesce((c->>'overlap')::numeric, CASE WHEN v='EXACT_OR_CLOSE_MATCH' THEN 1.0 ELSE NULL END),
    'conflicting_evidence', CASE WHEN v='ACCESSORY' THEN 'accessory_not_product' WHEN v='IRRELEVANT' THEN 'no_meaningful_overlap' ELSE NULL END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_meta_execution_fingerprint(p_draft_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT md5(concat_ws('|',
    coalesce(pp->'meta'->'campaigns'->0->'ad_sets'->0->>'daily_budget',''),
    coalesce(pp->'meta'->'campaigns'->0->>'spend_cap',''),
    coalesce(pp->'meta'->>'currency',''),
    coalesce(pp->'meta'->'campaigns'->0->>'objective',''),
    coalesce(pp->'meta'->'campaigns'->0->'ad_sets'->0->'targeting'->'geo_locations'->>'countries',''),
    coalesce(pp->'meta'->'campaigns'->0->'ads'->0->'creative'->>'link','')
  ))
  FROM (SELECT platform_payloads AS pp FROM public.marketing_campaign_drafts WHERE id = p_draft_id) s;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_meta_pixel_config(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    -- Unified Meta dataset: the same id serves Pixel (browser) and CAPI (server).
    'pixel_id', v_cfg.dataset_id,
    'dataset_id', v_cfg.dataset_id,
    'graph_version', 'v26.0',
    'tenant_behavioral_tracking', COALESCE(v_track, false),
    -- Pixel should only be loaded when the tenant master switch allows it AND the
    -- storefront has captured per-visitor consent (client-side gate, not returned here).
    'load_pixel_allowed', COALESCE(v_track, false),
    'supported_events', jsonb_build_array(
      'PageView','ViewContent','Search','AddToCart','InitiateCheckout','AddPaymentInfo','Purchase'),
    -- Dedup contract: browser fbq(..., {eventID}) MUST equal the server CAPI event_id.
    'event_id_contract', 'pulse_<uuid>; identical value used for browser Pixel eventID and server CAPI event_id',
    'server_emit_endpoint', 'edge:meta-capi-adapter?mode=emit',
    'notes', 'No access token is ever exposed to the browser. Purchase must originate from a verified order source.'
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_meta_response_state(p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE code int := nullif(p_body->'error'->>'code','')::int; sub int := nullif(p_body->'error'->>'error_subcode','')::int;
BEGIN
  IF p_body ? 'error' THEN
    IF code = 190 THEN
      RETURN jsonb_build_object('ok',false,'error_class','CREDENTIAL_EXPIRED','provider_state','TEMPORARILY_UNAVAILABLE',
        'operational', true, 'action','refresh Ad Library user token in n8n credential Pulse Meta Ad Library User',
        'note','token expired -> provider operational issue, NOT negative advertising evidence, NOT market unsupported');
    ELSIF code = 10 AND sub = 2332002 THEN
      RETURN jsonb_build_object('ok',false,'error_class','ADS_LIBRARY_AUTHORIZATION','provider_state','SOURCE_BLOCKED',
        'operational', true, 'action','complete facebook.com/ads/library/api authorization');
    ELSIF code IN (4,17,32,613) OR sub = 2446079 THEN
      RETURN jsonb_build_object('ok',false,'error_class','RATE_LIMIT','provider_state','TEMPORARILY_UNAVAILABLE','operational',true,'action','back off and retry later');
    ELSE
      RETURN jsonb_build_object('ok',false,'error_class','OTHER_AUTH_OR_API','provider_state','TEMPORARILY_UNAVAILABLE','operational',true,
        'error_code',code,'error_subcode',sub);
    END IF;
  END IF;
  IF jsonb_typeof(p_body->'data') = 'array' THEN
    RETURN jsonb_build_object('ok',true,'provider_state','AVAILABLE','ads_count', jsonb_array_length(p_body->'data'));
  END IF;
  RETURN jsonb_build_object('ok',false,'error_class','UNRECOGNIZED_RESPONSE','provider_state','UNKNOWN','operational',true);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_monday_top_opportunities(p_tenant uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE ready jsonb; watch jsonb; scanned int;
BEGIN
  WITH best AS (
    SELECT DISTINCT ON (d.product_id) d.*, cp.title AS product_name, cp.category,
      pme.evidence->'observed_market_price' AS price_obj,
      coalesce(pme.evidence->'supplier_identity'->>'match_class','UNKNOWN') AS sup_match
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id=d.product_id
    LEFT JOIN public.product_market_evaluations pme
      ON pme.tenant_id=d.tenant_id AND pme.product_id=d.product_id AND pme.country_code=d.country_code
    WHERE d.tenant_id=p_tenant AND d.is_fixture=false AND d.decision<>'AVOID' AND d.product_opportunity_score IS NOT NULL
    ORDER BY d.product_id,
      CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END,
      CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      d.product_opportunity_score DESC
  ),
  ranked AS (
    SELECT b.*, CASE WHEN b.metric_scope='LOCAL' THEN 0 ELSE 1 END AS price_rank,
      -- read the persisted resolved SOURCE image (identity/rights aware); no re-resolution by category
      (SELECT to_jsonb(pai) FROM public.product_asset_intelligence pai
        WHERE pai.tenant_id=b.tenant_id AND pai.product_id=b.product_id AND pai.is_primary
        ORDER BY pai.created_at DESC LIMIT 1) AS asset
    FROM best b
  ),
  ord AS (
    SELECT r.*, row_number() OVER (ORDER BY
      CASE r.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END, r.price_rank,
      CASE r.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE r.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      r.product_opportunity_score DESC) AS rk
    FROM ranked r
  ),
  capped AS (SELECT * FROM ord WHERE rk <= p_limit),
  cards AS (
    SELECT decision, jsonb_build_object(
      'product_id', product_id, 'product', product_name, 'category', category,
      'best_market', country_code, 'decision', decision, 'lifecycle', lifecycle_state,
      'product_confidence', product_confidence, 'product_opportunity_score', product_opportunity_score,
      'saturation', saturation_state->>'level',
      'market_price', CASE WHEN price_obj->>'amount' IS NOT NULL
          THEN (price_obj->>'amount')||' '||coalesce(price_obj->>'currency','') ELSE 'UNKNOWN (no local price observed)' END,
      'market_price_scope', metric_scope,
      'supplier_match', CASE WHEN sup_match='EXACT_PRODUCT' THEN 'EXACT' ELSE coalesce(nullif(sup_match,'UNKNOWN'),'unresolved') END,
      'advertising_headroom', advertising_headroom->>'state', 'opportunity_sweet_spot', opportunity_sweet_spot->>'state',
      'image', CASE WHEN asset IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',asset->>'source_url','identity_state',asset->>'identity_state',
                   'rights_state',asset->>'rights_state','hero_eligible',(asset->>'hero_eligible')::boolean,
                   'source',asset->>'source','asset_type',asset->>'asset_type',
                   'note', CASE WHEN (asset->>'hero_eligible')::boolean THEN 'exact-product supplier image'
                           ELSE 'comparable supplier image ('||(asset->>'identity_state')||') — NOT the exact candidate; shown as reference' END)
                 ELSE jsonb_build_object('available',false,'reason','IMAGE_UNAVAILABLE — no legitimate exact/comparable supplier image resolved') END,
      'why', 'Real demand'||CASE WHEN metric_scope='LOCAL' THEN ' + validated local price' ELSE '' END||
             '; held for '||coalesce((SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(decision_blockers) x LIMIT 2) z),'—'),
      'action', CASE WHEN decision='TEST' THEN 'View Opportunity (Build Product Page eligible)' ELSE 'View Opportunity (launch actions locked)' END
    ) AS card, rk
    FROM capped
  )
  SELECT coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='WATCH'),'[]'::jsonb)
  INTO ready, watch;
  SELECT count(*) INTO scanned FROM public.product_opportunity_decisions WHERE tenant_id=p_tenant AND is_fixture=false;
  RETURN jsonb_build_object('tenant_id', p_tenant, 'generated_at', now(),
    'ready_to_test', ready, 'watchlist', watch,
    'ready_to_test_count', jsonb_array_length(ready), 'watchlist_count', jsonb_array_length(watch),
    'total_opportunities', jsonb_array_length(ready)+jsonb_array_length(watch),
    'limit', p_limit, 'product_market_rows_scanned', scanned,
    'discovery_policy', jsonb_build_object('max_portfolio', p_limit,
      'stop_conditions', jsonb_build_array('source_candidate_exhaustion','configured_max_candidate_scan','sufficient_qualified_portfolio'),
      'min_evidence_quality','real Product x Market decision, non-AVOID, real demand evidence; no gate lowered to fill slots',
      'note','fewer than the limit is expected when few candidates meet evidence quality; AVOID never enters the portfolio'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','READY_TO_TEST are launch-eligible only after downstream gates; WATCHLIST are emerging, not launch-ready; WINNER is post-performance only.',
    'contract','pulse_monday_top_opportunities_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_normalize_source_platform(p_raw text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE lower(btrim(coalesce(p_raw,'')))
    WHEN 'google_trends' THEN 'google_trends'
    WHEN 'google_news' THEN 'google_news'
    WHEN 'news' THEN 'google_news'
    WHEN 'industry_blog' THEN 'industry_blog'
    WHEN 'blog' THEN 'industry_blog'
    WHEN 'reddit' THEN 'reddit'
    WHEN 'youtube' THEN 'youtube'
    WHEN 'youtube_trending' THEN 'youtube'
    WHEN 'hacker_news' THEN 'hacker_news'
    WHEN 'tiktok' THEN 'tiktok'
    WHEN 'facebook' THEN 'facebook'
    WHEN 'instagram' THEN 'instagram'
    WHEN 'amazon' THEN 'amazon'
    WHEN 'aliexpress' THEN 'aliexpress'
    WHEN 'temu' THEN 'temu'
    WHEN 'shopify_store' THEN 'shopify_store'
    WHEN 'supplier' THEN 'supplier'
    WHEN 'multi_source_trends' THEN 'multi_source_trends'
    WHEN 'global_trends' THEN 'global_trends'
    ELSE 'other'
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_opportunity_band(p_score numeric)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_score IS NULL THEN jsonb_build_object('band','INSUFFICIENT_EVIDENCE','ordinal',NULL)
    WHEN p_score < 40 THEN jsonb_build_object('band','AVOID','ordinal',0)
    WHEN p_score < 55 THEN jsonb_build_object('band','WEAK_WATCH','ordinal',1)
    WHEN p_score < 70 THEN jsonb_build_object('band','TRENDING_WATCH','ordinal',2)
    WHEN p_score < 80 THEN jsonb_build_object('band','STRONG_TEST','ordinal',3)
    WHEN p_score < 90 THEN jsonb_build_object('band','HIGH_CONFIDENCE_TEST','ordinal',4)
    ELSE jsonb_build_object('band','EXCEPTIONAL_TEST_CANDIDATE','ordinal',5)
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_opportunity_score_v2(p_dims jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT public.fn_weighted_over_observed(p_dims, jsonb_build_object(
    'buyer_intent_demand',20,'trend_velocity_timing',15,'social_viral',10,'marketplace_validation',10,
    'advertising_validation',10,'competition_saturation_gap',10,'economics_profit',15,'supply_delivery',10));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_own_country_evaluation_state(p_product_id uuid, p_country text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  RETURN public.fn_country_evaluation_state(v_app, p_product_id, p_country) || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_own_market_comparison(p_product_id uuid, p_countries text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  RETURN public.fn_market_comparison(v_app, p_product_id, p_countries) || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_own_product_country_explorer(p_product_id uuid, p_selling_markets text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid; v_core jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  v_core := public.fn_product_country_explorer(v_app, p_product_id, p_selling_markets);
  RETURN v_core || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pause_all_advertising(p_actor uuid, p_tenant uuid, p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_auth int; v_act int;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  UPDATE public.spend_reservations sr SET status='RELEASED', released_at=now()
    FROM public.marketing_spend_authority a
    WHERE sr.authority_id=a.id AND a.tenant_id=p_tenant AND a.platform=upper(p_platform) AND sr.status='RESERVED';
  UPDATE public.marketing_spend_authority SET status='REVOKED', revoked_at=now(), reserved=0
    WHERE tenant_id=p_tenant AND platform=upper(p_platform) AND status IN ('ACTIVE','DRAFT','PENDING_APPROVAL');
  GET DIAGNOSTICS v_auth = ROW_COUNT;
  UPDATE public.activation_authorizations SET status='INVALIDATED'
    WHERE tenant_id=p_tenant AND platform=upper(p_platform) AND status='ISSUED';
  GET DIAGNOSTICS v_act = ROW_COUNT;
  PERFORM public.fn_authority_audit(p_tenant,'PAUSE_ALL_REQUESTED',p_actor,NULL,NULL,NULL,
    jsonb_build_object('authorities_revoked',v_auth,'activations_invalidated',v_act),'emergency',NULL);
  RETURN jsonb_build_object('status','PAUSED_ALL','authorities_frozen',v_auth,'activations_invalidated',v_act,
    'note','future launches blocked; already-active campaigns require a platform pause request (not performed in this unit)');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_perf_commerce_join(p_tenant uuid, p_execution_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'observed_purchases', COALESCE(count(*) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')), 0),
    'observed_revenue', COALESCE(sum(ce.value) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')), NULL),
    'observed_revenue_currency', max(ce.currency) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')),
    'attribution_known', bool_or(ce.attribution_class IS NOT NULL AND ce.attribution_class NOT IN ('UNATTRIBUTED','UNKNOWN')),
    'source_class', CASE WHEN count(*) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')) > 0
                         THEN 'REAL_OBSERVED' ELSE 'UNKNOWN' END
  )
  FROM public.commerce_events ce
  WHERE ce.tenant_id = p_tenant
    AND ce.campaign_execution_id = p_execution_id
    AND ce.is_test_fixture = false;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_perf_decision(p_metrics jsonb, p_derived jsonb, p_economics jsonb, p_context jsonb, p_policy jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  spend numeric := nullif(p_metrics->>'spend','')::numeric;
  impressions numeric := nullif(p_metrics->>'impressions','')::numeric;
  clicks numeric := coalesce(nullif(p_metrics->>'clicks','')::numeric,0);
  purchases numeric := coalesce(nullif(p_metrics->>'purchases','')::numeric,0);
  be_cpa numeric := nullif(p_economics->>'break_even_cpa','')::numeric;
  sell numeric := nullif(p_economics->>'selling_price','')::numeric;
  econ_state text := coalesce(p_economics->>'economics_state','UNKNOWN');
  is_fixture boolean := coalesce((p_context->>'is_fixture')::boolean,false);
  src text := coalesce(p_context->>'source_class','UNKNOWN');
  psv boolean := coalesce((p_context->>'purchase_source_verified')::boolean,false);
  supplier text := coalesce(p_context->>'supplier_status','UNKNOWN');
  attr_known boolean := coalesce((p_context->>'attribution_known')::boolean,false);
  min_impr numeric := coalesce(nullif(p_policy->>'min_impressions','')::numeric,1000);
  min_clicks numeric := coalesce(nullif(p_policy->>'min_clicks_conversion','')::numeric,50);
  min_pur numeric := coalesce(nullif(p_policy->>'min_purchases_decision','')::numeric,5);
  decision text; reasons text[] := '{}'; risks text[] := '{}';
  caa numeric; be_roas numeric; fixture_only boolean; executable boolean; winner_eligible boolean;
  confidence text; roas_verified boolean;
BEGIN
  fixture_only := is_fixture OR src = 'FIXTURE';
  be_roas := CASE WHEN be_cpa IS NULL OR be_cpa <= 0 OR sell IS NULL THEN NULL ELSE round(sell/be_cpa,4) END;
  roas_verified := psv AND NOT fixture_only AND src = 'REAL_OBSERVED';

  IF spend IS NULL OR impressions IS NULL OR (coalesce(spend,0) <= 0 AND coalesce(impressions,0) <= 0) THEN
    decision := 'INSUFFICIENT_DATA'; reasons := array_append(reasons,'NO_DELIVERY');
  ELSIF impressions > 0 AND clicks = 0 THEN
    decision := 'INSUFFICIENT_DATA'; reasons := array_append(reasons,'DELIVERY_BUT_NO_ENGAGEMENT');
  ELSIF purchases = 0 THEN
    IF clicks >= min_clicks THEN
      decision := 'IMPROVE'; reasons := array_append(reasons,'TRAFFIC_NO_CONVERSION');
    ELSE
      decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'INSUFFICIENT_TRAFFIC_FOR_CONVERSION_READ');
    END IF;
  ELSIF purchases < min_pur THEN
    decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'PURCHASES_BELOW_SAMPLE_THRESHOLD');
  ELSE
    IF econ_state = 'UNKNOWN' OR be_cpa IS NULL THEN
      decision := 'IMPROVE'; reasons := array_append(reasons,'UNKNOWN_ECONOMICS_CANNOT_VERIFY_CONTRIBUTION');
      risks := array_append(risks,'UNKNOWN_ECONOMICS');
    ELSE
      caa := round(purchases * be_cpa - coalesce(spend,0), 2);
      IF abs(caa) <= 0.10 * coalesce(spend,0) THEN
        decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'BREAK_EVEN_BAND');
      ELSIF caa < 0 AND coalesce(spend,0) > 2 * purchases * be_cpa THEN
        decision := 'STOP'; reasons := array_append(reasons,'NEGATIVE_CONTRIBUTION_STRUCTURAL');
        risks := array_append(risks,'NEGATIVE_CONTRIBUTION');
      ELSIF caa < 0 THEN
        decision := 'IMPROVE'; reasons := array_append(reasons,'NEGATIVE_CONTRIBUTION_SALVAGEABLE');
        risks := array_append(risks,'NEGATIVE_CONTRIBUTION');
      ELSE
        IF supplier = 'CRITICAL' THEN
          decision := 'IMPROVE'; reasons := array_append(reasons,'POSITIVE_CONTRIBUTION_BUT_SUPPLIER_CRITICAL');
          risks := array_append(risks,'SUPPLIER_CRITICAL_BLOCKS_SCALE');
        ELSE
          decision := 'SCALE_CANDIDATE'; reasons := array_append(reasons,'POSITIVE_CONTRIBUTION_SUFFICIENT_EVIDENCE');
        END IF;
      END IF;
    END IF;
  END IF;

  IF fixture_only THEN risks := array_append(risks,'FIXTURE_ONLY_NON_EXECUTABLE'); END IF;
  IF NOT psv THEN risks := array_append(risks,'PURCHASE_SOURCE_UNVERIFIED'); END IF;
  IF (p_derived->>'roas') IS NOT NULL AND NOT roas_verified THEN risks := array_append(risks,'ROAS_UNVERIFIED'); END IF;
  IF NOT attr_known THEN risks := array_append(risks,'ATTRIBUTION_UNKNOWN'); END IF;

  executable := (decision = 'SCALE_CANDIDATE') AND NOT fixture_only AND psv
                AND src = 'REAL_OBSERVED' AND supplier = 'OK' AND attr_known;
  winner_eligible := false;

  confidence := CASE
    WHEN fixture_only THEN 'FIXTURE_NONE'
    WHEN decision = 'INSUFFICIENT_DATA' THEN 'NONE'
    WHEN purchases >= min_pur AND psv AND src='REAL_OBSERVED' THEN 'MEDIUM'
    WHEN purchases > 0 THEN 'LOW'
    ELSE 'LOW' END;

  RETURN jsonb_build_object(
    'decision', decision,
    'decision_reasons', to_jsonb(reasons),
    'risk_flags', to_jsonb(risks),
    'contribution_after_ads', caa,
    'break_even_roas', be_roas,
    'roas_verified', roas_verified,
    'fixture_only', fixture_only,
    'executable', executable,
    'winner_eligible', winner_eligible,
    'confidence', confidence,
    'policy_applied', jsonb_build_object('min_impressions',min_impr,'min_clicks_conversion',min_clicks,'min_purchases_decision',min_pur)
  );
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_perf_derive_metrics(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  spend numeric := nullif(p->>'spend','')::numeric;
  impressions numeric := nullif(p->>'impressions','')::numeric;
  clicks numeric := nullif(p->>'clicks','')::numeric;
  link_clicks numeric := nullif(p->>'link_clicks','')::numeric;
  purchases numeric := nullif(p->>'purchases','')::numeric;
  revenue numeric := nullif(p->>'revenue','')::numeric;
  eng numeric := coalesce(nullif(p->>'link_clicks','')::numeric, nullif(p->>'clicks','')::numeric);
BEGIN
  RETURN jsonb_build_object(
    'ctr',  CASE WHEN impressions IS NULL OR impressions = 0 OR clicks IS NULL THEN NULL ELSE round(clicks/impressions,6) END,
    'cpc',  CASE WHEN clicks IS NULL OR clicks = 0 OR spend IS NULL THEN NULL ELSE round(spend/clicks,4) END,
    'cpm',  CASE WHEN impressions IS NULL OR impressions = 0 OR spend IS NULL THEN NULL ELSE round(spend/impressions*1000,4) END,
    'purchase_conversion_rate', CASE WHEN eng IS NULL OR eng = 0 OR purchases IS NULL THEN NULL ELSE round(purchases/eng,6) END,
    'cpa',  CASE WHEN purchases IS NULL OR purchases = 0 OR spend IS NULL THEN NULL ELSE round(spend/purchases,4) END,
    'roas', CASE WHEN spend IS NULL OR spend = 0 OR revenue IS NULL THEN NULL ELSE round(revenue/spend,4) END,
    'denominators_note','all ratios return NULL on zero/unknown denominators (never divide-by-zero, never 0-filled)'
  );
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_perf_evaluate(p_tenant uuid, p_snapshot_id uuid, p_policy jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  s public.campaign_performance_snapshots%ROWTYPE;
  ei jsonb; econ jsonb; metrics jsonb; derived jsonb; ctx jsonb; decision jsonb; joinj jsonb;
  actions jsonb; obs_pur numeric; obs_rev numeric;
BEGIN
  SELECT * INTO s FROM public.campaign_performance_snapshots WHERE id = p_snapshot_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','snapshot_not_found'); END IF;
  IF s.tenant_id <> p_tenant THEN RETURN jsonb_build_object('error','cross_tenant_denied'); END IF;

  -- economics (reuse fn_economics_breakeven); inputs live in provenance.economics_inputs
  ei := s.provenance->'economics_inputs';
  IF ei IS NULL THEN
    econ := jsonb_build_object('economics_state','UNKNOWN','known',false,'reason','no_economics_inputs');
  ELSE
    econ := public.fn_economics_breakeven(
      nullif(ei->>'selling_price','')::numeric,
      nullif(ei->>'landed_cost','')::numeric,
      ei->>'landed_currency',
      coalesce(ei->>'display_currency','GBP'),
      ei->'fees');
  END IF;

  -- real observed purchases/revenue override for non-fixture snapshots with an execution
  obs_pur := s.purchases; obs_rev := s.revenue;
  IF NOT s.is_fixture AND s.campaign_execution_id IS NOT NULL THEN
    joinj := public.fn_perf_commerce_join(p_tenant, s.campaign_execution_id);
    obs_pur := nullif(joinj->>'observed_purchases','')::numeric;
    obs_rev := nullif(joinj->>'observed_revenue','')::numeric;
  END IF;

  metrics := jsonb_build_object(
    'spend', s.spend, 'impressions', s.impressions, 'reach', s.reach, 'frequency', s.frequency,
    'clicks', s.clicks, 'link_clicks', s.link_clicks, 'landing_page_views', s.landing_page_views,
    'add_to_cart', s.add_to_cart, 'initiate_checkout', s.initiate_checkout,
    'purchases', obs_pur, 'revenue', obs_rev,
    'spend_currency', s.spend_currency, 'revenue_currency', s.revenue_currency);

  derived := public.fn_perf_derive_metrics(metrics);

  ctx := jsonb_build_object(
    'is_fixture', s.is_fixture,
    'source_class', s.source_class,
    'purchase_source_verified', s.purchase_source_verified,
    'supplier_status', coalesce(s.provenance->>'supplier_status','UNKNOWN'),
    'attribution_known', coalesce((joinj->>'attribution_known')::boolean,
                                  coalesce((s.provenance->>'attribution_known')::boolean,false)));

  decision := public.fn_perf_decision(metrics, derived, econ, ctx, p_policy);

  actions := CASE decision->>'decision'
    WHEN 'INSUFFICIENT_DATA' THEN jsonb_build_array('AWAIT_DELIVERY_OR_EXTEND_OBSERVATION_WINDOW')
    WHEN 'CONTINUE_TEST'     THEN jsonb_build_array('CONTINUE_GATHERING_EVIDENCE')
    WHEN 'IMPROVE'           THEN jsonb_build_array('ITERATE_CREATIVE_TARGETING_OR_OFFER')
    WHEN 'STOP'              THEN jsonb_build_array('STOP_PENDING_REVIEW_requires_separate_authority_gate')
    WHEN 'SCALE_CANDIDATE'   THEN jsonb_build_array('REVIEW_FOR_SCALE_AUTHORIZATION_requires_separate_spend_activation_gate')
    ELSE jsonb_build_array('NO_ACTION') END;

  RETURN jsonb_build_object(
    'snapshot_id', s.id, 'tenant_id', s.tenant_id,
    'campaign_execution_id', s.campaign_execution_id, 'level', s.level,
    'performance_snapshot', metrics || derived,
    'economics', econ,
    'commerce_join', joinj,
    'evidence_quality', jsonb_build_object(
      'source_class', s.source_class, 'is_fixture', s.is_fixture,
      'purchase_source_verified', s.purchase_source_verified,
      'sample_purchases', obs_pur, 'attribution_known', ctx->'attribution_known'),
    'decision', decision->>'decision',
    'decision_reasons', decision->'decision_reasons',
    'risk_flags', decision->'risk_flags',
    'confidence', decision->>'confidence',
    'contribution_after_ads', decision->'contribution_after_ads',
    'break_even_roas', decision->'break_even_roas',
    'roas_verified', decision->'roas_verified',
    'fixture_only', decision->'fixture_only',
    'winner_eligible', decision->'winner_eligible',
    'recommended_actions', actions,
    'executable', decision->'executable',
    'provenance', jsonb_build_object('source_class', s.source_class, 'platform', s.platform,
      'window_start', s.window_start, 'window_end', s.window_end, 'inputs', s.provenance),
    'contract', 'pulse_perf_intel_v1'
  );
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_performance_handoff(p_tenant uuid, p_cb_campaign_id uuid, p_include_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts; v_vc int; v_atc int; v_ic int; v_pur int; v_rev numeric; v_cur text;
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_campaign_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT
    count(*) FILTER (WHERE event_name='VIEW_CONTENT'),
    count(*) FILTER (WHERE event_name='ADD_TO_CART'),
    count(*) FILTER (WHERE event_name='INITIATE_CHECKOUT'),
    count(*) FILTER (WHERE event_name='PURCHASE'),
    coalesce(sum(converted_amount) FILTER (WHERE event_name='PURCHASE'),0)
  INTO v_vc,v_atc,v_ic,v_pur,v_rev
  FROM public.commerce_events
  WHERE tenant_id=p_tenant AND campaign_id=p_cb_campaign_id AND (p_include_test OR NOT is_test_fixture);

  RETURN jsonb_build_object(
    'contract', public.fn_postlaunch_metrics_contract()->>'contract_version',
    'campaign_id',p_cb_campaign_id,
    'metrics', jsonb_build_object(
      'spend', jsonb_build_object('value',NULL,'state','UNKNOWN','note','no ad-platform spend data (Meta tracking blocked)'),
      'impressions', jsonb_build_object('value',NULL,'state','UNKNOWN'),
      'clicks', jsonb_build_object('value',NULL,'state','UNKNOWN'),
      'view_content', jsonb_build_object('value',v_vc,'state','OBSERVED'),
      'add_to_cart', jsonb_build_object('value',v_atc,'state','OBSERVED'),
      'checkout', jsonb_build_object('value',v_ic,'state','OBSERVED'),
      'purchases', jsonb_build_object('value',v_pur,'state','OBSERVED'),
      'revenue', jsonb_build_object('value',v_rev,'currency','GBP','state', CASE WHEN v_pur>0 THEN 'CALCULATED' ELSE 'UNKNOWN' END),
      'cpa', jsonb_build_object('value',NULL,'state','UNKNOWN','note','requires spend'),
      'roas', jsonb_build_object('value',NULL,'state','UNKNOWN','note','requires spend')),
    'break_even_context', jsonb_build_object(
      'note','compare actual CPA vs product break-even CPA (no universal ROAS threshold)',
      'campaign_market',c.campaign_target_market,'budget',c.budget),
    'included_test_fixtures',p_include_test);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pm_decision(p_score numeric, p_confidence text, p_gates jsonb, p_policy jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  test_min numeric := coalesce(nullif(p_policy->>'test_min','')::numeric,70);
  watch_min numeric := coalesce(nullif(p_policy->>'watch_min','')::numeric,45);
  gk text; gv text; has_fail boolean := false; has_watch boolean := false;
  reasons text[] := '{}'; decision text;
BEGIN
  FOR gk, gv IN SELECT key, value::text FROM jsonb_each_text(p_gates) LOOP
    IF gv = 'FAIL' THEN has_fail := true; reasons := array_append(reasons, 'GATE_FAIL_'||upper(gk)); END IF;
    IF gv = 'WATCH' THEN has_watch := true; reasons := array_append(reasons, 'GATE_WATCH_'||upper(gk)); END IF;
  END LOOP;

  IF has_fail THEN
    decision := 'AVOID';
  ELSIF has_watch THEN
    decision := 'WATCH'; reasons := array_append(reasons,'CANNOT_TEST_UNTIL_GATES_RESOLVE');
  ELSIF p_score IS NULL THEN
    decision := 'WATCH'; reasons := array_append(reasons,'NO_SCORE_INSUFFICIENT_EVIDENCE');
  ELSIF p_score >= test_min AND p_confidence IN ('MEDIUM','HIGH') THEN
    decision := 'TEST'; reasons := array_append(reasons,'SCORE_AND_GATES_AND_CONFIDENCE_PASS');
  ELSIF p_score >= watch_min THEN
    decision := 'WATCH'; reasons := array_append(reasons, CASE WHEN p_confidence NOT IN ('MEDIUM','HIGH') THEN 'SCORE_OK_BUT_LOW_CONFIDENCE' ELSE 'SCORE_BELOW_TEST_THRESHOLD' END);
  ELSE
    decision := 'AVOID'; reasons := array_append(reasons,'SCORE_BELOW_WATCH_THRESHOLD');
  END IF;
  RETURN jsonb_build_object('market_decision', decision, 'decision_reasons', to_jsonb(reasons),
    'policy', jsonb_build_object('test_min',test_min,'watch_min',watch_min));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pm_monday_block(p_tenant uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH r AS (SELECT public.fn_rank_product_markets(p_tenant, p_product) AS j)
  SELECT jsonb_build_object(
    'best_market_to_test', (j->>'recommended_market'),
    'best_market_decision', (j->>'recommended_decision'),
    'best_market_is_test', (j->'recommended_is_test'),
    'market_score', (j#>'{markets,0,market_score}'),
    'why_this_market', (j#>'{markets,0,reason_for_rank}'),
    'confidence', (j#>'{markets,0,confidence}'),
    'alternative_markets', (SELECT jsonb_agg(m) FROM jsonb_array_elements(j->'markets') m WHERE (m->>'rank')::int > 1),
    'key_market_metrics', (j#>'{markets,0}'),
    'risks', (j#>'{markets,0,risks}'),
    'contract', 'pulse_monday_market_block_v1',
    'schedule_note', 'Monday-only cadence unchanged; no new recurring workflow.'
  ) FROM r;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_pm_score(p_components jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  k text; v jsonb; w numeric; s numeric;
  wsum numeric := 0; wknown numeric := 0; acc numeric := 0; total_w numeric := 0;
  coverage numeric; conf text;
BEGIN
  FOR k, v IN SELECT * FROM jsonb_each(p_components) LOOP
    w := coalesce(nullif(v->>'weight','')::numeric,0);
    total_w := total_w + w;
    s := nullif(v->>'subscore','')::numeric;   -- null = UNKNOWN
    IF s IS NOT NULL THEN
      wknown := wknown + w;
      acc := acc + w * s;
    END IF;
  END LOOP;
  coverage := CASE WHEN total_w = 0 THEN 0 ELSE round(wknown/total_w, 4) END;
  conf := CASE WHEN coverage >= 0.75 THEN 'HIGH' WHEN coverage >= 0.5 THEN 'MEDIUM'
               WHEN coverage >= 0.35 THEN 'LOW' ELSE 'NONE' END;
  RETURN jsonb_build_object(
    'market_opportunity_score', CASE WHEN wknown = 0 THEN NULL ELSE round(acc/wknown, 1) END,
    'coverage', coverage,
    'evidence_confidence', conf,
    'known_weight', wknown, 'total_weight', total_w);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pmc_evaluate(p_tenant uuid, p_product uuid, p_country text, p_market_currency text, p_competitors jsonb, p_pme_id uuid DEFAULT NULL::uuid, p_policy jsonb DEFAULT '{}'::jsonb, p_is_fixture boolean DEFAULT false, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c jsonb; mc text; plat text; pcur text; psc text; pctry text; pamt numeric; norm jsonb;
  direct int := 0; category int := 0; unrelated int := 0;
  total_ads int := 0; listings int := 0;
  local_prices numeric[] := '{}'; advertisers text[] := '{}'; platforms text[] := '{}'; patterns text[] := '{}';
  offers_present boolean := false;
  sat_points numeric; sat_level text; sat_conf text;
  med numeric; lo numeric; hi numeric; sample int;
  gaps jsonb := '[]'::jsonb;
  comp_sub numeric; adv_sub numeric; price_sub numeric; ev_conf text;
  ad_platform_count int;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(p_competitors) LOOP
    mc := coalesce(c->>'match_class','UNRELATED');
    plat := c->>'platform';
    pamt := nullif(c->'price'->>'amount','')::numeric;
    pcur := c->'price'->>'currency';
    psc := coalesce(c->'price'->>'source_class','UNKNOWN');
    pctry := coalesce(c->'price'->>'country', p_country);

    IF mc = 'UNRELATED' THEN unrelated := unrelated + 1;
    ELSIF mc = 'CATEGORY_COMPETITOR' THEN category := category + 1;
    ELSE direct := direct + 1;  -- EXACT_PRODUCT or CLOSE_COMPARABLE
    END IF;

    -- normalize price provenance (converted != local validation; excluded from local median below)
    norm := NULL;
    IF pamt IS NOT NULL AND pcur IS NOT NULL THEN
      norm := public.normalize_money(pamt, pcur, coalesce(p_market_currency, pcur));
    END IF;

    -- local median inputs: DIRECT only, local country, local currency, OBSERVED/PLATFORM_REPORTED only
    IF mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND pctry = p_country
       AND pcur = p_market_currency AND psc IN ('OBSERVED','PLATFORM_REPORTED') AND pamt IS NOT NULL THEN
      local_prices := array_append(local_prices, pamt);
    END IF;

    -- advertising: observable only, DIRECT competitors
    IF mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND coalesce((c->>'observable_ad_count')::int,0) > 0 THEN
      total_ads := total_ads + (c->>'observable_ad_count')::int;
      IF c->>'competitor_identity' IS NOT NULL THEN advertisers := array_append(advertisers, c->>'competitor_identity'); END IF;
      IF plat IS NOT NULL THEN platforms := array_append(platforms, plat); END IF;
      IF c->>'creative_pattern' IS NOT NULL THEN patterns := array_append(patterns, c->>'creative_pattern'); END IF;
      IF c->>'offer_pattern' IS NOT NULL THEN offers_present := true; END IF;
    END IF;
    IF mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND coalesce(c->>'competitor_kind','') = 'MARKETPLACE_LISTING' THEN
      listings := listings + 1;
    END IF;

    IF p_persist THEN
      INSERT INTO public.product_market_competitors
        (tenant_id, product_id, product_market_evaluation_id, country_code, competitor_kind,
         competitor_identity, competitor_ref, competitor_product_ref, observed_product_url,
         match_class, match_confidence, match_evidence, platform, price_original, price_currency,
         price_source_class, price_normalized, price_observed_at, ad_platform, observable_ad_count,
         ad_status, ad_window, creative_pattern, offer_pattern, cta_pattern, marketplace_presence,
         source, source_reference, evidence_class, observed_at, confidence, is_fixture, provenance)
      VALUES (p_tenant, p_product, p_pme_id, p_country, c->>'competitor_kind',
         c->>'competitor_identity', c->>'competitor_ref', c->>'competitor_product_ref', c->>'observed_product_url',
         mc, c->>'match_confidence', coalesce(c->'match_evidence','{}'::jsonb), plat, pamt, pcur,
         psc, norm, nullif(c->>'price_observed_at','')::timestamptz, c->>'ad_platform', (c->>'observable_ad_count')::int,
         c->>'ad_status', coalesce(c->'ad_window','{}'::jsonb), c->>'creative_pattern', c->>'offer_pattern', c->>'cta_pattern',
         coalesce(c->'marketplace_presence','{}'::jsonb), c->>'source', c->>'source_reference',
         coalesce(c->>'evidence_class','UNKNOWN'), nullif(c->>'observed_at','')::timestamptz, c->>'confidence',
         p_is_fixture, jsonb_build_object('engine','fn_pmc_evaluate'));
    END IF;
  END LOOP;

  -- local price stats (only from qualifying local observations)
  sample := array_length(local_prices,1);
  IF sample IS NOT NULL AND sample > 0 THEN
    SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY v))::numeric,2), min(v), max(v)
      INTO med, lo, hi FROM unnest(local_prices) v;
  END IF;

  -- deterministic saturation
  ad_platform_count := (SELECT count(DISTINCT p) FROM unnest(platforms) p);
  sat_points := least(100, direct*15 + total_ads*4 + listings*1.5);
  IF direct=0 AND total_ads=0 AND listings=0 THEN sat_level := 'UNKNOWN';
  ELSIF sat_points < 20 THEN sat_level := 'LOW';
  ELSIF sat_points < 45 THEN sat_level := 'MODERATE';
  ELSIF sat_points < 70 THEN sat_level := 'HIGH';
  ELSE sat_level := 'VERY_HIGH'; END IF;
  sat_conf := CASE WHEN direct>0 AND (total_ads>0 OR listings>0) THEN 'HIGH'
                   WHEN direct>0 OR total_ads>0 OR listings>0 THEN 'MEDIUM' ELSE 'LOW' END;

  -- evidence-backed gaps
  IF total_ads > 0 AND array_length(patterns,1) IS NOT NULL
     AND NOT ('PROBLEM_SOLUTION' = ANY(patterns)) THEN
    gaps := gaps || jsonb_build_array(jsonb_build_object('gap_type','CREATIVE_ANGLE_GAP',
      'evidence', jsonb_build_object('observed_patterns', to_jsonb(patterns)),
      'confidence','MEDIUM','why_it_matters','No observed competitor uses a problem-solution angle; an evidence-based angle may differentiate.'));
  END IF;
  IF sample IS NOT NULL AND sample >= 3 AND med > 0 AND (hi-lo)/med < 0.25 THEN
    gaps := gaps || jsonb_build_array(jsonb_build_object('gap_type','PRICE_POSITIONING_GAP',
      'evidence', jsonb_build_object('median',med,'range',jsonb_build_array(lo,hi),'sample',sample),
      'confidence','MEDIUM','why_it_matters','Prices are tightly compressed; a differentiated positioning band may be open.'));
  END IF;
  IF total_ads > 0 AND ad_platform_count = 1 THEN
    gaps := gaps || jsonb_build_array(jsonb_build_object('gap_type','PLATFORM_GAP',
      'evidence', jsonb_build_object('platforms', to_jsonb(platforms)),
      'confidence','LOW','why_it_matters','Observed advertising concentrates on a single platform family.'));
  END IF;
  IF direct > 0 AND NOT offers_present THEN
    gaps := gaps || jsonb_build_array(jsonb_build_object('gap_type','OFFER_GAP',
      'evidence', jsonb_build_object('direct_competitors',direct,'offers_observed',false),
      'confidence','LOW','why_it_matters','No explicit competitor offer pattern observed.'));
  END IF;

  -- score-component adapter (exposed for pm_score engine; weights unchanged)
  comp_sub := CASE sat_level WHEN 'LOW' THEN 85 WHEN 'MODERATE' THEN 65 WHEN 'HIGH' THEN 40
                             WHEN 'VERY_HIGH' THEN 20 ELSE NULL END;
  IF comp_sub IS NOT NULL AND jsonb_array_length(gaps) > 0 THEN comp_sub := least(100, comp_sub + 8); END IF;
  adv_sub := CASE WHEN total_ads = 0 AND direct = 0 THEN NULL
                  WHEN total_ads = 0 THEN 25
                  WHEN total_ads BETWEEN 1 AND 5 THEN 60
                  WHEN total_ads BETWEEN 6 AND 15 THEN 78 ELSE 68 END;
  price_sub := CASE WHEN sample IS NOT NULL AND sample >= 3 THEN 100
                    WHEN sample IS NOT NULL AND sample >= 1 THEN 60 ELSE NULL END;
  ev_conf := sat_conf;

  RETURN jsonb_build_object(
    'product_id', p_product, 'country_code', p_country, 'product_market_evaluation_id', p_pme_id,
    'market_currency', p_market_currency,
    'competitor_counts', jsonb_build_object('direct', direct, 'category', category, 'unrelated_excluded', unrelated),
    'competition', jsonb_build_object('level', sat_level, 'confidence', sat_conf, 'saturation_points', sat_points,
        'note','direct = EXACT_PRODUCT + CLOSE_COMPARABLE only; CATEGORY_COMPETITOR and UNRELATED excluded from direct metrics'),
    'market_price', jsonb_build_object('median', med, 'range', CASE WHEN sample>0 THEN jsonb_build_array(lo,hi) ELSE NULL END,
        'sample', coalesce(sample,0), 'currency', p_market_currency,
        'provenance','local OBSERVED/PLATFORM_REPORTED direct matches only; converted foreign prices excluded'),
    'advertising', jsonb_build_object('observable_ads', total_ads, 'advertiser_diversity', (SELECT count(DISTINCT a) FROM unnest(advertisers) a),
        'platforms', to_jsonb((SELECT array_agg(DISTINCT p) FROM unnest(platforms) p)),
        'creative_patterns', to_jsonb((SELECT array_agg(DISTINCT p) FROM unnest(patterns) p)),
        'metrics_safety','observable ad counts only; NOT sales/revenue/ROAS/conversion; no winning-ad claims'),
    'marketplace', jsonb_build_object('direct_listings', listings),
    'opportunity_gaps', gaps,
    'score_components', jsonb_build_object('competition_saturation_gap', comp_sub, 'advertising_activity', adv_sub,
        'market_price_support', price_sub, 'evidence_confidence', ev_conf),
    'is_fixture', p_is_fixture, 'contract','pulse_product_market_competitor_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pmc_monday_block(p_tenant uuid, p_product uuid, p_country text, p_market_currency text DEFAULT 'EUR'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH s AS (SELECT public.fn_pmc_summary(p_tenant, p_product, p_country, p_market_currency) AS j)
  SELECT jsonb_build_object(
    'who_is_selling_it', (SELECT jsonb_agg(DISTINCT c.competitor_identity) FROM public.product_market_competitors c
        WHERE c.tenant_id=p_tenant AND c.product_id=p_product AND c.country_code=p_country
          AND c.match_class IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND c.competitor_identity IS NOT NULL),
    'where', (j->'advertising'->'platforms'),
    'observed_prices', (j->'market_price'),
    'competition_level', (j#>'{competition,level}'),
    'observable_ad_activity', (j->'advertising'->'observable_ads'),
    'advertising_platforms', (j->'advertising'->'platforms'),
    'creative_offer_patterns', (j->'advertising'->'creative_patterns'),
    'opportunity_gaps', (j->'opportunity_gaps'),
    'evidence_confidence', (j#>'{competition,confidence}'),
    'metrics_safety', 'observable only; never sales/revenue/ROAS/winning-ad',
    'schedule_note', 'Monday-only cadence unchanged; no new recurring workflow.',
    'contract', 'pulse_monday_competitor_block_v1') FROM s;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_pmc_summary(p_tenant uuid, p_product uuid, p_country text, p_market_currency text DEFAULT 'EUR'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE arr jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'competitor_kind', competitor_kind, 'competitor_identity', competitor_identity,
      'competitor_ref', competitor_ref, 'platform', platform, 'match_class', match_class,
      'match_confidence', match_confidence,
      'price', jsonb_build_object('amount', price_original, 'currency', price_currency,
               'source_class', price_source_class, 'country', country_code),
      'observable_ad_count', observable_ad_count, 'creative_pattern', creative_pattern,
      'offer_pattern', offer_pattern, 'cta_pattern', cta_pattern, 'evidence_class', evidence_class)), '[]'::jsonb)
    INTO arr
  FROM public.product_market_competitors
  WHERE tenant_id = p_tenant AND product_id = p_product AND country_code = p_country;

  RETURN public.fn_pmc_evaluate(p_tenant, p_product, p_country, p_market_currency, arr, NULL, '{}'::jsonb, false, false);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pod_evaluate(p_tenant uuid, p_product uuid, p_country text, p_score_version text DEFAULT 'pod_v1'::text, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  pme record; plat record;
  market_score numeric; platform_score numeric; product_score numeric;
  competitor_score numeric; supplier_score numeric;
  market_conf text; platform_conf text := NULL;
  g_stock text; g_price text; g_econ text; g_comp text; g_fulf text;
  price_src text; metric_scope text;
  comp_input jsonb; comp jsonb; score numeric; coverage numeric;
  band text; decision text; lifecycle text; action_gate text;
  has_fail boolean := false; has_watch boolean := false;
  dblock text[] := '{}'; eblock text[] := '{}'; reasons text[] := '{}';
  bec numeric; econ_state text; contrib_reserve numeric;
  cpa jsonb; overall_conf text; component_scores jsonb; hard_gates jsonb;
  exec_ready text := NULL; tier_of int;
  sat jsonb; sat_level text; sat_conf text; sat_points numeric; sat_gaps jsonb; has_gap boolean;
  sat_gate text; pc_tier int; product_confidence text;
  c10 numeric; c15 numeric; c20 numeric; ah_state text; compression boolean := false;
  ss_state text; demand_present boolean;
  saturation_state jsonb; advertising_headroom jsonb; opportunity_sweet_spot jsonb;
BEGIN
  SELECT * INTO pme FROM public.product_market_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country
  ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;
  IF pme.id IS NULL THEN
    RETURN jsonb_build_object('tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,
      'score_version',p_score_version,'decision','INSUFFICIENT_EVIDENCE','opportunity_band','INSUFFICIENT',
      'product_opportunity_score',NULL,'reason','NO_PRODUCT_MARKET_EVALUATION_FOR_COUNTRY',
      'note','A unified decision requires a country-specific market evaluation; global evaluation is never used.',
      'contract','pulse_product_opportunity_decision_v1');
  END IF;
  market_score := pme.market_opportunity_score; market_conf := pme.evidence_confidence;
  g_stock := coalesce(pme.gate_state->>'stock','UNKNOWN'); g_price := coalesce(pme.gate_state->>'price','UNKNOWN');
  g_econ := coalesce(pme.gate_state->>'economics','UNKNOWN'); g_comp := coalesce(pme.gate_state->>'compliance','UNKNOWN');
  g_fulf := coalesce(pme.gate_state->>'fulfilment','UNKNOWN');
  price_src := coalesce(pme.evidence->'observed_market_price'->>'source_class', pme.component_scores->'market_price_support'->>'source_class');
  metric_scope := CASE WHEN price_src IN ('OBSERVED','PLATFORM_REPORTED') THEN 'LOCAL'
    WHEN price_src='INFERRED' THEN 'CROSS_MARKET_REFERENCE' WHEN price_src='ESTIMATED' THEN 'LOCAL_UNVALIDATED'
    WHEN g_price='PASS' THEN 'LOCAL' ELSE 'LOCAL_UNVALIDATED' END;
  SELECT * INTO plat FROM public.product_market_platform_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country AND recommendation NOT IN ('INSUFFICIENT_EVIDENCE','AVOID')
  ORDER BY CASE evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END, platform_fit_score DESC NULLS LAST, platform ASC LIMIT 1;
  IF plat.id IS NOT NULL THEN platform_score := plat.platform_fit_score; platform_conf := plat.evidence_confidence; exec_ready := plat.execution_readiness; END IF;

  sat := public.fn_pmc_summary(p_tenant, p_product, p_country, coalesce(pme.market_currency,'EUR'));
  sat_level := coalesce(sat->'competition'->>'level','UNKNOWN'); sat_conf := sat->'competition'->>'confidence';
  sat_points := nullif(sat->'competition'->>'saturation_points','')::numeric;
  sat_gaps := coalesce(sat->'opportunity_gaps','[]'::jsonb); has_gap := jsonb_array_length(sat_gaps) > 0;

  product_score := (SELECT avg(x) FROM (VALUES ((pme.component_scores->'marketplace_validation'->>'subscore')::numeric),
      ((pme.component_scores->'demand_momentum'->>'subscore')::numeric),((pme.component_scores->'buyer_search_intent'->>'subscore')::numeric)) v(x));
  competitor_score := (pme.component_scores->'competition_saturation_gap'->>'subscore')::numeric;
  supplier_score := (SELECT avg(x) FROM (VALUES ((pme.component_scores->'supplier_availability_stock'->>'subscore')::numeric),
      ((pme.component_scores->'landed_economics'->>'subscore')::numeric)) v(x));
  demand_present := (pme.component_scores->'buyer_search_intent'->>'subscore') IS NOT NULL OR (pme.component_scores->'demand_momentum'->>'subscore') IS NOT NULL;

  component_scores := jsonb_build_object(
    'product', jsonb_build_object('subscore',product_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','note','product-intrinsic demand/validation signals (diagnostic)'),
    'market', jsonb_build_object('subscore',market_score,'confidence',market_conf,'source_ref',pme.id,'scope',metric_scope,'note','authoritative product x market composite'),
    'platform', CASE WHEN platform_score IS NULL THEN jsonb_build_object('subscore',NULL,'confidence','NONE','source_ref',NULL,'scope','LOCAL','note','no eligible acquisition-channel evidence for this market')
      ELSE jsonb_build_object('subscore',platform_score,'confidence',platform_conf,'source_ref',plat.id,'scope','LOCAL','platform',plat.platform) END,
    'competitor', jsonb_build_object('subscore',competitor_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','saturation_level',sat_level,'note','competitor saturation/gap signal (folded into market score)'),
    'supplier', jsonb_build_object('subscore',supplier_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','note','supplier availability + landed economics (folded into market score)'));

  comp_input := jsonb_build_object('market_dimension',jsonb_build_object('weight',70,'subscore',market_score),
    'platform_dimension', CASE WHEN platform_score IS NULL THEN jsonb_build_object('weight',30) ELSE jsonb_build_object('weight',30,'subscore',platform_score) END);
  comp := public.fn_pm_score(comp_input);
  score := nullif(comp->>'market_opportunity_score','')::numeric; coverage := nullif(comp->>'coverage','')::numeric;

  tier_of := CASE market_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;
  IF platform_conf IS NOT NULL THEN tier_of := least(tier_of, CASE platform_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END); END IF;
  IF metric_scope <> 'LOCAL' THEN tier_of := least(tier_of,2); END IF;
  IF platform_score IS NULL THEN tier_of := least(tier_of,2); END IF;
  overall_conf := CASE tier_of WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' WHEN 1 THEN 'LOW' ELSE 'NONE' END;

  pc_tier := CASE WHEN coalesce(pme.coverage,0)>=0.75 THEN 3 WHEN coalesce(pme.coverage,0)>=0.5 THEN 2 ELSE 1 END;
  IF metric_scope <> 'LOCAL' THEN pc_tier := least(pc_tier,2); END IF;
  IF sat_level='UNKNOWN' THEN pc_tier := least(pc_tier,2); END IF;
  IF g_stock<>'PASS' THEN pc_tier := least(pc_tier,1); END IF;
  IF g_econ<>'PASS' THEN pc_tier := least(pc_tier,1); END IF;
  IF market_conf IN ('NONE','LOW') THEN pc_tier := least(pc_tier,1); END IF;
  product_confidence := CASE pc_tier WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' ELSE 'LOW' END;

  bec := nullif(pme.economics->>'break_even_cpa','')::numeric; econ_state := pme.economics->>'economics_state';
  contrib_reserve := nullif(pme.economics->>'contribution_after_reserve','')::numeric;
  IF bec IS NOT NULL THEN c10:=round(bec-10,2); c15:=round(bec-15,2); c20:=round(bec-20,2); END IF;
  IF bec IS NULL OR metric_scope<>'LOCAL' OR sat_level='UNKNOWN' THEN ah_state:='INSUFFICIENT_EVIDENCE';
  ELSIF c20>=10 AND sat_level IN ('LOW','MODERATE') THEN ah_state:='STRONG';
  ELSIF c15>=5 AND sat_level<>'VERY_HIGH' THEN ah_state:='PROMISING';
  ELSE ah_state:='WEAK'; END IF;
  IF sat_gaps @> '[{"gap_type":"PRICE_POSITIONING_GAP"}]'::jsonb THEN
    ah_state := CASE ah_state WHEN 'STRONG' THEN 'PROMISING' WHEN 'PROMISING' THEN 'WEAK' ELSE ah_state END;
    compression := true; END IF;   -- price compression downgrades headroom one tier

  IF g_stock='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'SUPPLIER_OUT_OF_STOCK');
  ELSIF g_stock='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'SUPPLIER_STOCK_UNKNOWN'); END IF;
  IF g_econ='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'ECONOMICS_NEGATIVE_CONTRIBUTION');
  ELSIF g_econ='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'ECONOMICS_UNKNOWN'); END IF;
  IF g_price='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'MARKET_PRICE_INVALID');
  ELSIF g_price='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'MARKET_PRICE_NOT_LOCALLY_VALIDATED'); END IF;
  IF g_comp='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'COMPLIANCE_CRITICAL');
  ELSIF g_comp='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'COMPLIANCE_UNVERIFIED'); END IF;
  IF g_fulf='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'FULFILMENT_ROUTE_MISSING');
  ELSIF g_fulf='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'FULFILMENT_ROUTE_UNCONFIRMED'); END IF;

  sat_gate := CASE WHEN sat_level='VERY_HIGH' THEN 'WATCH'
    WHEN sat_level='HIGH' AND has_gap AND ah_state IN ('STRONG','PROMISING') THEN 'PASS'
    WHEN sat_level='HIGH' THEN 'WATCH' WHEN sat_level='UNKNOWN' THEN 'WATCH' ELSE 'PASS' END;
  IF sat_gate='WATCH' THEN has_watch:=true;
    dblock := array_append(dblock, CASE WHEN sat_level='VERY_HIGH' THEN 'MARKET_SATURATION_VERY_HIGH'
      WHEN sat_level='HIGH' THEN 'MARKET_SATURATION_HIGH_NO_DEFENSIBLE_GAP' ELSE 'MARKET_SATURATION_UNKNOWN_FAIL_CLOSED' END);
  ELSIF sat_level='HIGH' THEN reasons := array_append(reasons,'HIGH_SATURATION_BOUNDED_EXCEPTION_GAP_AND_HEADROOM'); END IF;

  hard_gates := jsonb_build_object('supplier',g_stock,'market_price',g_price,'economics',g_econ,'compliance',g_comp,'fulfilment',g_fulf,'saturation',sat_gate);

  IF exec_ready='BLOCKED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_API_BLOCKED');
  ELSIF exec_ready='NOT_CONNECTED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_NOT_CONNECTED'); END IF;
  IF platform_score IS NULL THEN eblock:=array_append(eblock,'NO_EXECUTABLE_PLATFORM_IDENTIFIED'); END IF;

  band := CASE WHEN score IS NULL THEN 'INSUFFICIENT' WHEN score<40 THEN 'AVOID' WHEN score<55 THEN 'WATCH'
    WHEN score<70 THEN 'TRENDING_WATCH' WHEN score<80 THEN 'STRONG_TEST' WHEN score<90 THEN 'HIGH_CONFIDENCE_TEST' ELSE 'EXCEPTIONAL' END;

  IF has_fail THEN decision:='AVOID'; reasons:=array_append(reasons,'HARD_GATE_FAIL_OVERRIDES_SCORE');
  ELSIF has_watch THEN decision:='WATCH'; reasons:=array_append(reasons,'CANNOT_TEST_UNTIL_GATES_RESOLVE');
  ELSIF score IS NULL THEN decision:='WATCH'; reasons:=array_append(reasons,'NO_SCORE_INSUFFICIENT_EVIDENCE');
  ELSIF score>=70 AND overall_conf IN ('MEDIUM','HIGH') THEN decision:='TEST'; reasons:=array_append(reasons,'SCORE_GATES_CONFIDENCE_PASS');
  ELSIF score>=40 THEN decision:='WATCH'; reasons:=array_append(reasons, CASE WHEN score>=70 THEN 'SCORE_OK_BUT_LOW_CONFIDENCE' ELSE 'SCORE_BELOW_TEST_THRESHOLD' END);
  ELSE decision:='AVOID'; reasons:=array_append(reasons,'SCORE_BELOW_WATCH_THRESHOLD'); END IF;

  lifecycle := CASE WHEN decision='AVOID' THEN 'AVOID'
    WHEN decision='WATCH' THEN CASE WHEN band IN ('TRENDING_WATCH','STRONG_TEST','HIGH_CONFIDENCE_TEST','EXCEPTIONAL') THEN 'TRENDING_WATCH' ELSE 'WATCH' END
    WHEN decision='TEST' AND band IN ('HIGH_CONFIDENCE_TEST','EXCEPTIONAL') AND overall_conf='HIGH' AND platform_score IS NOT NULL THEN 'HIGH_CONFIDENCE_TEST'
    ELSE 'STRONG_TEST_CANDIDATE' END;
  action_gate := CASE WHEN decision='AVOID' THEN 'NO_ACTION' WHEN decision='WATCH' THEN 'MONITOR_GATHER_EVIDENCE'
    WHEN array_length(eblock,1) IS NOT NULL THEN 'DECISION_TEST_EXECUTION_BLOCKED' ELSE 'ELIGIBLE_FOR_LAUNCH_PREP' END;

  cpa := (SELECT jsonb_object_agg(k,v) FROM (SELECT 'cpa_'||c::text AS k,
      CASE WHEN bec IS NULL THEN jsonb_build_object('contribution',NULL,'state','UNKNOWN')
           ELSE jsonb_build_object('contribution',round(bec-c,2),'state',CASE WHEN bec-c>=15 THEN 'VIABLE' WHEN bec-c>=0 THEN 'THIN' ELSE 'NEGATIVE' END) END AS v
      FROM (VALUES (10),(15),(20)) t(c)) s);

  IF sat_level='UNKNOWN' OR metric_scope<>'LOCAL' OR bec IS NULL OR score IS NULL THEN ss_state:='INSUFFICIENT_EVIDENCE';
  ELSIF sat_level IN ('LOW','MODERATE') AND g_stock='PASS' AND g_price='PASS' AND g_econ='PASS' AND ah_state IN ('STRONG','PROMISING') AND product_confidence='HIGH' AND score>=70 AND demand_present THEN ss_state:='STRONG';
  ELSIF sat_level IN ('LOW','MODERATE','HIGH') AND g_stock='PASS' AND g_econ='PASS' AND ah_state<>'WEAK' AND product_confidence IN ('HIGH','MEDIUM') AND score>=55 THEN ss_state:='PROMISING';
  ELSE ss_state:='WEAK'; END IF;

  saturation_state := jsonb_build_object('level',sat_level,'confidence',sat_conf,'saturation_points',sat_points,'has_defensible_gap',has_gap,
    'source','product_market_competitors','evidence_class','OBSERVED','product',p_product,'country',p_country,
    'note','competition state for THIS product x country; demand never overrides saturation; counts are not CPC/CPA/ROAS');
  advertising_headroom := jsonb_build_object('state',ah_state,'price_compression',compression,
    'cpa_stress',jsonb_build_object('cpa_10',c10,'cpa_15',c15,'cpa_20',c20),'break_even_cpa',bec,'saturation_context',sat_level,
    'product',p_product,'country',p_country,'note','EUR 10/15/20 are stress scenarios, not CPA forecasts; competition is NOT converted to bid/CPC/CPA cost');
  opportunity_sweet_spot := jsonb_build_object('state',ss_state,'product',p_product,'country',p_country,
    'components',jsonb_build_object('demand_present',demand_present,'saturation',sat_level,'supplier_stock',g_stock,'local_price',metric_scope,
      'economics',econ_state,'advertising_headroom',ah_state,'product_confidence',product_confidence,'opportunity_score',score),
    'note','combination of demand + manageable saturation + usable supplier/stock + defensible local price + viable economics + headroom + confidence; not a single score');

  reasons := array_append(reasons,'BAND_'||band); reasons := array_append(reasons,'METRIC_SCOPE_'||metric_scope);
  reasons := array_append(reasons,'PRODUCT_CONFIDENCE_'||product_confidence); reasons := array_append(reasons,'SATURATION_'||sat_level);
  reasons := array_append(reasons,'HEADROOM_'||ah_state); reasons := array_append(reasons,'SWEET_SPOT_'||ss_state);
  IF compression THEN reasons := array_append(reasons,'PRICE_COMPRESSION_DOWNGRADED_HEADROOM'); END IF;
  IF metric_scope<>'LOCAL' THEN reasons := array_append(reasons,'PRICE_IS_CROSS_MARKET_REFERENCE_NOT_LOCAL_VALIDATION'); END IF;

  IF p_persist THEN
    INSERT INTO public.product_opportunity_decisions AS d (
      tenant_id, product_id, country_code, market_currency, score_version, product_market_evaluation_id, primary_platform, primary_platform_evaluation_id, lineage,
      component_scores, product_opportunity_score, coverage, opportunity_band, overall_evidence_confidence, product_confidence, decision, lifecycle_state, metric_scope,
      saturation_state, advertising_headroom, opportunity_sweet_spot, hard_gates, decision_blockers, execution_blockers, action_gating,
      economics_ref, cpa_scenarios, decision_reasons, is_fixture, provenance)
    VALUES (p_tenant, p_product, p_country, pme.market_currency, p_score_version, pme.id, plat.platform, plat.id,
      jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id,'competitor_rows',(SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country),'evaluated_at',now(),'snapshot',true),
      component_scores, score, coverage, band, overall_conf, product_confidence, decision, lifecycle, metric_scope,
      saturation_state, advertising_headroom, opportunity_sweet_spot, hard_gates, to_jsonb(dblock), to_jsonb(eblock), action_gate,
      jsonb_build_object('pme_id',pme.id,'economics_state',econ_state,'break_even_cpa',bec,'contribution_after_reserve',contrib_reserve),
      cpa, to_jsonb(reasons), pme.is_fixture,
      jsonb_build_object('engine','pod_v1','built_from',jsonb_build_array('product_market_evaluations','product_market_platform_evaluations','product_market_competitors')))
    ON CONFLICT (tenant_id, product_id, country_code, score_version) DO UPDATE SET
      market_currency=excluded.market_currency, product_market_evaluation_id=excluded.product_market_evaluation_id, primary_platform=excluded.primary_platform,
      primary_platform_evaluation_id=excluded.primary_platform_evaluation_id, lineage=excluded.lineage, component_scores=excluded.component_scores,
      product_opportunity_score=excluded.product_opportunity_score, coverage=excluded.coverage, opportunity_band=excluded.opportunity_band,
      overall_evidence_confidence=excluded.overall_evidence_confidence, product_confidence=excluded.product_confidence, decision=excluded.decision,
      lifecycle_state=excluded.lifecycle_state, metric_scope=excluded.metric_scope, saturation_state=excluded.saturation_state,
      advertising_headroom=excluded.advertising_headroom, opportunity_sweet_spot=excluded.opportunity_sweet_spot, hard_gates=excluded.hard_gates,
      decision_blockers=excluded.decision_blockers, execution_blockers=excluded.execution_blockers, action_gating=excluded.action_gating,
      economics_ref=excluded.economics_ref, cpa_scenarios=excluded.cpa_scenarios, decision_reasons=excluded.decision_reasons,
      is_fixture=excluded.is_fixture, provenance=excluded.provenance, created_at=now();
  END IF;

  RETURN jsonb_build_object('tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,'market_currency',pme.market_currency,'score_version',p_score_version,
    'product_opportunity_score',score,'coverage',coverage,'opportunity_band',band,'overall_evidence_confidence',overall_conf,'product_confidence',product_confidence,
    'decision',decision,'lifecycle_state',lifecycle,'metric_scope',metric_scope,'component_scores',component_scores,
    'saturation_state',saturation_state,'advertising_headroom',advertising_headroom,'opportunity_sweet_spot',opportunity_sweet_spot,
    'primary_platform',plat.platform,'primary_execution_readiness',exec_ready,'hard_gates',hard_gates,'decision_blockers',to_jsonb(dblock),'execution_blockers',to_jsonb(eblock),
    'action_gating',action_gate,'economics_ref',jsonb_build_object('economics_state',econ_state,'break_even_cpa',bec,'contribution_after_reserve',contrib_reserve),
    'cpa_scenarios',cpa,'decision_reasons',to_jsonb(reasons),'lineage',jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id),
    'campaign_activation',false,'advertising_spend',0,
    'note','Unified per-market decision. WINNER is post-launch only; strongest pre-launch is HIGH_CONFIDENCE_TEST. Execution readiness gates ACTION, never the opportunity decision. Saturation gates TEST eligibility; demand never overrides it.',
    'contract','pulse_product_opportunity_decision_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pod_monday_block(p_tenant uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE t jsonb; best record;
BEGIN
  SELECT * INTO best FROM public.product_opportunity_decisions d
  WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version='pod_v1'
  ORDER BY CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
           CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST, d.country_code ASC LIMIT 1;
  IF best.id IS NULL THEN
    RETURN jsonb_build_object('product_id',p_product,'status','NO_UNIFIED_DECISION',
      'note','Run fn_pod_tournament first.','contract','pulse_product_opportunity_monday_v1');
  END IF;
  SELECT jsonb_agg(jsonb_build_object('country',country_code,'decision',decision,
           'score',product_opportunity_score,'band',opportunity_band,'confidence',overall_evidence_confidence,
           'product_confidence',product_confidence,'saturation',saturation_state->>'level',
           'advertising_headroom',advertising_headroom->>'state','opportunity_sweet_spot',opportunity_sweet_spot->>'state')
           ORDER BY product_opportunity_score DESC NULLS LAST)
    INTO t FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version='pod_v1' AND country_code<>best.country_code;
  RETURN jsonb_build_object(
    'product_id',p_product, 'BEST_MARKET', best.country_code, 'DECISION', best.decision, 'LIFECYCLE_STATE', best.lifecycle_state,
    'PRODUCT_OPPORTUNITY_SCORE', best.product_opportunity_score, 'OPPORTUNITY_BAND', best.opportunity_band,
    'PRODUCT_CONFIDENCE', best.product_confidence, 'EVIDENCE_CONFIDENCE', best.overall_evidence_confidence,
    'SATURATION', jsonb_build_object('country',best.country_code,'level',best.saturation_state->>'level','confidence',best.saturation_state->>'confidence'),
    'ADVERTISING_HEADROOM', jsonb_build_object('country',best.country_code,'state',best.advertising_headroom->>'state'),
    'OPPORTUNITY_SWEET_SPOT', jsonb_build_object('country',best.country_code,'state',best.opportunity_sweet_spot->>'state'),
    'WHY', best.decision_reasons, 'BEST_AD_PLATFORM', best.primary_platform, 'METRIC_SCOPE', best.metric_scope,
    'DECISION_BLOCKERS', best.decision_blockers, 'EXECUTION_BLOCKERS', best.execution_blockers,
    'CPA_SCENARIOS', best.cpa_scenarios, 'ACTION_GATING', best.action_gating,
    'CROSS_MARKET_ALTERNATIVES', COALESCE(t,'[]'::jsonb),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','Every market metric identifies its country. Monday cadence unchanged; no new recurring workflow. WINNER is post-launch only.',
    'contract','pulse_product_opportunity_monday_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_pod_tournament(p_tenant uuid, p_product uuid, p_score_version text DEFAULT 'pod_v1'::text, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record; combos jsonb; best record; avoid_markets text[]; live_markets text[];
BEGIN
  FOR c IN SELECT DISTINCT country_code FROM public.product_market_evaluations
           WHERE tenant_id=p_tenant AND product_id=p_product LOOP
    PERFORM public.fn_pod_evaluate(p_tenant, p_product, c.country_code, p_score_version, p_persist);
  END LOOP;

  WITH ranked AS (
    SELECT d.*,
      row_number() OVER (ORDER BY
        CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
        CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
        CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
        d.product_opportunity_score DESC NULLS LAST,
        CASE d.product_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END ASC,
        CASE d.advertising_headroom->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
        nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
        d.country_code ASC) AS rnk
    FROM public.product_opportunity_decisions d
    WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'rank',rnk,'country',country_code,'market_currency',market_currency,
      'product_opportunity_score',product_opportunity_score,'band',opportunity_band,
      'decision',decision,'lifecycle_state',lifecycle_state,'confidence',overall_evidence_confidence,
      'product_confidence',product_confidence,'saturation',saturation_state->>'level',
      'advertising_headroom',advertising_headroom->>'state','opportunity_sweet_spot',opportunity_sweet_spot->>'state',
      'metric_scope',metric_scope,'primary_platform',primary_platform,
      'decision_blockers',decision_blockers,'execution_blockers',execution_blockers,
      'contribution_after_reserve', economics_ref->>'contribution_after_reserve') ORDER BY rnk),'[]'::jsonb)
  INTO combos FROM ranked;

  SELECT * INTO best FROM public.product_opportunity_decisions d
  WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version
  ORDER BY CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
           CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST,
           CASE d.product_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END ASC,
           CASE d.advertising_headroom->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
           d.country_code ASC LIMIT 1;

  SELECT array_agg(country_code) INTO avoid_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision='AVOID';
  SELECT array_agg(country_code ORDER BY country_code) INTO live_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision<>'AVOID';

  RETURN jsonb_build_object(
    'tenant_id',p_tenant,'product_id',p_product,'score_version',p_score_version,
    'evaluated_combinations',(SELECT count(*) FROM public.product_opportunity_decisions
       WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version),
    'product_market_tournament', combos,
    'best_market', best.country_code, 'best_market_decision', best.decision,
    'best_market_score', best.product_opportunity_score, 'best_market_lifecycle', best.lifecycle_state,
    'best_market_sweet_spot', best.opportunity_sweet_spot->>'state', 'best_market_saturation', best.saturation_state->>'level',
    'product_level_decision', best.decision,
    'cross_market_recovery', jsonb_build_object(
      'recovered_markets', COALESCE(to_jsonb(live_markets),'[]'::jsonb),
      'failed_markets', COALESCE(to_jsonb(avoid_markets),'[]'::jsonb),
      'product_globally_rejected', (live_markets IS NULL),
      'note','A product is never globally rejected on one market''s failure; each market is judged on its own local evidence.'),
    'campaign_activation', false, 'advertising_spend', 0,
    'ranking_note','Ranks PRODUCT x MARKET by opportunity quality (sweet-spot, saturation, headroom, confidence), not popularity; best_market does NOT set campaign_target_market.',
    'contract','pulse_product_opportunity_tournament_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_postlaunch_metrics_contract()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT jsonb_build_object('contract_version','postlaunch_v1','populated_by','Phase 13-15 real execution only','metrics',
    jsonb_build_array('spend','impressions','clicks','ctr','cpc','landing_page_views','product_views','cta_clicks',
      'add_to_cart','checkout','purchases','cpa','revenue','roas','contribution','refunds','cancellations'),
    'note','no universal ROAS threshold; evaluate against product-specific break-even economics');
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ppf_acquisition_mode(p_evidence jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  band text := upper(coalesce(p_evidence->'search'->>'buyer_intent_band',''));
  tvol numeric := nullif(p_evidence->'search'->>'transactional_volume','')::numeric;
  social boolean := coalesce((p_evidence->'discovery'->>'social_attention_present')::boolean,false);
  demo numeric := nullif(p_evidence->'discovery'->>'demonstrability_subscore','')::numeric;
  search_sig boolean := (band IN ('HIGH','MEDIUM') AND tvol IS NOT NULL AND tvol > 0);
  disc_sig boolean := (social OR (demo IS NOT NULL AND demo >= 60));
  mode text; conf text;
BEGIN
  IF search_sig AND disc_sig THEN mode := 'HYBRID';
  ELSIF search_sig THEN mode := 'SEARCH_LED';
  ELSIF disc_sig THEN mode := 'DISCOVERY_LED';
  ELSE mode := 'UNKNOWN'; END IF;
  conf := CASE WHEN search_sig AND disc_sig THEN 'HIGH' WHEN search_sig OR disc_sig THEN 'MEDIUM' ELSE 'NONE' END;
  RETURN jsonb_build_object('acquisition_mode', mode, 'confidence', conf,
    'evidence', jsonb_build_object('search_signal',search_sig,'discovery_signal',disc_sig,'buyer_intent_band',band,'transactional_volume',tvol,'social_attention',social,'demonstrability',demo));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ppf_evaluate(p_tenant uuid, p_product uuid, p_country text, p_platform text, p_evidence jsonb, p_pme_id uuid DEFAULT NULL::uuid, p_policy jsonb DEFAULT '{}'::jsonb, p_is_fixture boolean DEFAULT false, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  W jsonb := coalesce(p_policy->'weights', jsonb_build_object(
    'buyer_intent_fit',18,'observable_competitor_activity',12,'audience_fit',14,'product_demonstrability',12,
    'creative_format_fit',12,'price_consideration_fit',8,'competition_saturation',12,'platform_opportunity_gap',12));
  min_cov numeric := coalesce(nullif(p_policy->>'min_coverage','')::numeric,0.4);
  avoid_max numeric := coalesce(nullif(p_policy->>'avoid_max','')::numeric,35);
  comps jsonb; sc jsonb; fit numeric; cov numeric; conf text; ev_state text; rec text;
  amode jsonb; execj jsonb; gaps jsonb := coalesce(p_evidence->'platform_gaps','[]'::jsonb);
  reasons text[] := '{}';
BEGIN
  comps := jsonb_build_object(
    'buyer_intent_fit', jsonb_build_object('subscore', p_evidence->>'buyer_intent_fit','weight', W->>'buyer_intent_fit'),
    'observable_competitor_activity', jsonb_build_object('subscore', p_evidence->>'observable_competitor_activity','weight', W->>'observable_competitor_activity'),
    'audience_fit', jsonb_build_object('subscore', p_evidence->>'audience_fit','weight', W->>'audience_fit'),
    'product_demonstrability', jsonb_build_object('subscore', p_evidence->>'product_demonstrability','weight', W->>'product_demonstrability'),
    'creative_format_fit', jsonb_build_object('subscore', p_evidence->>'creative_format_fit','weight', W->>'creative_format_fit'),
    'price_consideration_fit', jsonb_build_object('subscore', p_evidence->>'price_consideration_fit','weight', W->>'price_consideration_fit'),
    'competition_saturation', jsonb_build_object('subscore', p_evidence->>'competition_saturation','weight', W->>'competition_saturation'),
    'platform_opportunity_gap', jsonb_build_object('subscore', p_evidence->>'platform_opportunity_gap','weight', W->>'platform_opportunity_gap'));
  sc := public.fn_pm_score(comps);
  fit := nullif(sc->>'market_opportunity_score','')::numeric;
  cov := nullif(sc->>'coverage','')::numeric;
  conf := sc->>'evidence_confidence';
  ev_state := coalesce(p_evidence->>'evidence_state',
                CASE WHEN cov >= 0.6 THEN 'SUFFICIENT' WHEN cov >= 0.4 THEN 'PARTIAL' ELSE 'INSUFFICIENT' END);
  amode := public.fn_ppf_acquisition_mode(p_evidence);
  execj := public.fn_ppf_execution_readiness(p_platform);

  -- recommendation eligibility: confidence/coverage gate prevents low-evidence platforms winning by
  -- excluded unknowns. INSUFFICIENT stays INSUFFICIENT. Score alone never grants eligibility.
  IF ev_state = 'INSUFFICIENT' OR cov IS NULL OR cov < min_cov THEN
    rec := 'INSUFFICIENT_EVIDENCE'; reasons := array_append(reasons,'EVIDENCE_BELOW_ELIGIBILITY_COVERAGE');
  ELSIF fit IS NULL OR fit < avoid_max THEN
    rec := 'AVOID'; reasons := array_append(reasons,'FIT_BELOW_AVOID_THRESHOLD');
  ELSE
    rec := 'WATCH'; reasons := array_append(reasons,'ELIGIBLE_CANDIDATE_PENDING_RANK');  -- rank promotes to PRIMARY/SECONDARY/ALTERNATIVE
  END IF;

  IF p_persist THEN
    INSERT INTO public.product_market_platform_evaluations
      (tenant_id, product_id, product_market_evaluation_id, country_code, platform, acquisition_mode,
       component_scores, platform_fit_score, coverage, evidence_confidence, evidence_state,
       competition_level, saturation_points, observable_advertiser_count, observable_ad_count,
       platform_gaps, recommendation, execution_capability, execution_readiness, risks, reasons, evidence, is_fixture, provenance)
    VALUES (p_tenant, p_product, p_pme_id, p_country, upper(p_platform), amode->>'acquisition_mode',
       comps, fit, cov, conf, ev_state,
       p_evidence->>'competition_level', nullif(p_evidence->>'saturation_points','')::numeric,
       nullif(p_evidence->>'observable_advertiser_count','')::int, nullif(p_evidence->>'observable_ad_count','')::int,
       gaps, rec, execj->>'execution_capability', execj->>'execution_readiness',
       coalesce(p_evidence->'risks','[]'::jsonb), to_jsonb(reasons), p_evidence, p_is_fixture,
       jsonb_build_object('engine','fn_ppf_evaluate','acquisition',amode))
    ON CONFLICT (tenant_id, product_id, country_code, platform, score_version) DO UPDATE
      SET acquisition_mode=EXCLUDED.acquisition_mode, component_scores=EXCLUDED.component_scores,
          platform_fit_score=EXCLUDED.platform_fit_score, coverage=EXCLUDED.coverage,
          evidence_confidence=EXCLUDED.evidence_confidence, evidence_state=EXCLUDED.evidence_state,
          platform_gaps=EXCLUDED.platform_gaps, recommendation=EXCLUDED.recommendation,
          execution_capability=EXCLUDED.execution_capability, execution_readiness=EXCLUDED.execution_readiness,
          evidence=EXCLUDED.evidence, created_at=now();
  END IF;

  RETURN jsonb_build_object(
    'platform', upper(p_platform), 'country_code', p_country, 'product_id', p_product,
    'product_market_evaluation_id', p_pme_id, 'acquisition_mode', amode->>'acquisition_mode',
    'platform_fit_score', fit, 'coverage', cov, 'evidence_confidence', conf, 'evidence_state', ev_state,
    'recommendation', rec, 'reasons', to_jsonb(reasons),
    'execution_capability', execj->>'execution_capability', 'execution_readiness', execj->>'execution_readiness',
    'platform_gaps', gaps, 'component_scores', comps, 'is_fixture', p_is_fixture,
    'score_version','ppf_score_v1', 'contract','pulse_product_market_platform_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_ppf_execution_readiness(p_platform text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE upper(p_platform)
    WHEN 'FACEBOOK'      THEN jsonb_build_object('execution_capability','META_ADAPTER','execution_readiness','CONNECTED')
    WHEN 'INSTAGRAM'     THEN jsonb_build_object('execution_capability','META_ADAPTER','execution_readiness','CONNECTED')
    WHEN 'TIKTOK'        THEN jsonb_build_object('execution_capability','NONE','execution_readiness','NOT_CONNECTED')
    WHEN 'GOOGLE_SEARCH' THEN jsonb_build_object('execution_capability','NONE','execution_readiness','BLOCKED')  -- Google Ads API rejected; intelligence-only
    ELSE jsonb_build_object('execution_capability','NONE','execution_readiness','NOT_CONNECTED')
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ppf_monday_block(p_tenant uuid, p_product uuid, p_country text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH r AS (SELECT public.fn_ppf_rank(p_tenant, p_product, p_country) AS j)
  SELECT jsonb_build_object(
    'best_ad_platform', (j->>'primary_test_platform'),
    'platform_fit_score', (j#>'{platforms,0,platform_fit_score}'),
    'why_this_platform', (j#>'{platforms,0,reasons}'),
    'search_vs_discovery_mode', (j->>'primary_acquisition_mode'),
    'competitor_activity', (j#>'{platforms,0,observable_ad_count}'),
    'saturation', (j#>'{platforms,0,competition_level}'),
    'creative_fit', (j#>'{platforms,0,platform_gaps}'),
    'alternative_platform', (SELECT m FROM jsonb_array_elements(j->'platforms') m WHERE (m->>'recommendation')='SECONDARY_TEST' LIMIT 1),
    'evidence_confidence', (j#>'{platforms,0,confidence}'),
    'execution_readiness', (j->>'primary_execution_readiness'),
    'all_platforms', (j->'platforms'),
    'schedule_note', 'Monday-only cadence unchanged; no new recurring workflow.',
    'contract', 'pulse_monday_platform_block_v1') FROM r;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_ppf_rank(p_tenant uuid, p_product uuid, p_country text, p_score_version text DEFAULT 'ppf_score_v1'::text, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r record; n int := 0; final_rec text; out_arr jsonb := '[]'::jsonb; primary_platform text; primary_exec text; primary_mode text;
BEGIN
  FOR r IN
    SELECT * FROM public.product_market_platform_evaluations
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country AND score_version=p_score_version
    ORDER BY
      CASE WHEN recommendation='WATCH' THEN 0 ELSE 1 END,
      CASE evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END,
      platform_fit_score DESC NULLS LAST,
      platform ASC
  LOOP
    IF r.recommendation = 'WATCH' THEN
      n := n + 1;
      final_rec := CASE n WHEN 1 THEN 'PRIMARY_TEST' WHEN 2 THEN 'SECONDARY_TEST' ELSE 'ALTERNATIVE' END;
      IF n = 1 THEN primary_platform := r.platform; primary_exec := r.execution_readiness; primary_mode := r.acquisition_mode; END IF;
    ELSE
      final_rec := r.recommendation;
    END IF;
    IF p_persist THEN
      UPDATE public.product_market_platform_evaluations SET recommendation = final_rec WHERE id = r.id;
    END IF;
    out_arr := out_arr || jsonb_build_array(jsonb_build_object(
      'placement', CASE WHEN r.recommendation='WATCH' THEN n ELSE NULL END,
      'platform', r.platform, 'recommendation', final_rec,
      'platform_fit_score', r.platform_fit_score, 'confidence', r.evidence_confidence,
      'evidence_state', r.evidence_state, 'acquisition_mode', r.acquisition_mode,
      'competition_level', r.competition_level, 'observable_ad_count', r.observable_ad_count,
      'platform_gaps', r.platform_gaps, 'execution_readiness', r.execution_readiness,
      'execution_capability', r.execution_capability, 'reasons', r.reasons));
  END LOOP;
  RETURN jsonb_build_object(
    'product_id', p_product, 'country_code', p_country, 'score_version', p_score_version,
    'platforms', out_arr, 'primary_test_platform', primary_platform,
    'primary_execution_readiness', primary_exec, 'primary_acquisition_mode', primary_mode,
    'note', 'confidence-tier-first ranking; ignores execution readiness (opportunity != execution); low-evidence platforms stay INSUFFICIENT_EVIDENCE. Recommended platform does not set campaign_target_market.',
    'contract', 'pulse_product_market_platform_ranking_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_country_explorer(p_tenant uuid, p_product_id uuid, p_selling_markets text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (e.country_code) e.country_code, e.market_currency, e.market_opportunity_score,
      e.evidence_confidence, e.market_decision, e.component_scores, e.economics, e.gate_state,
      e.stock_state, e.compliance_risk, e.evidence, e.risk_flags, e.evaluation_ts
    FROM public.product_market_evaluations e
    WHERE e.product_id=p_product_id AND e.tenant_id=p_tenant          -- strict tenant scope (no is_fixture)
    ORDER BY e.country_code, e.evaluation_ts DESC
  ),
  plat AS (
    SELECT DISTINCT ON (country_code) country_code, platform, platform_fit_score, recommendation
    FROM public.product_market_platform_evaluations
    WHERE product_id=p_product_id AND tenant_id=p_tenant             -- strict tenant scope
    ORDER BY country_code, platform_fit_score DESC NULLS LAST
  ),
  cards AS (
    SELECT u.country_code, u.country_name, u.region, u.default_currency, u.status AS universe_status,
      ev.country_code IS NOT NULL AS evaluated,
      ev.market_decision, ev.market_opportunity_score, ev.evidence_confidence, ev.market_currency,
      ev.component_scores, ev.economics, ev.gate_state, ev.stock_state, ev.compliance_risk, ev.evidence, ev.risk_flags,
      plat.platform AS primary_platform, plat.platform_fit_score,
      (p_selling_markets IS NULL OR u.country_code = ANY(p_selling_markets)) AS within_selling,
      CASE ev.market_decision WHEN 'TEST' THEN 3 WHEN 'WATCH' THEN 2 WHEN 'AVOID' THEN 1 ELSE 0 END AS drank,
      public.fn_eur_to_local(ev.market_currency) AS eur2loc
    FROM public.ecommerce_market_universe u
    LEFT JOIN ev ON ev.country_code=u.country_code
    LEFT JOIN plat ON plat.country_code=u.country_code
    WHERE u.status IN ('ELIGIBLE','LIMITED_EVIDENCE') OR ev.country_code IS NOT NULL
  ),
  best AS (
    SELECT country_code FROM cards WHERE evaluated AND universe_status='ELIGIBLE' AND market_decision IN ('TEST','WATCH')
    ORDER BY drank DESC, market_opportunity_score DESC NULLS LAST, country_code LIMIT 1
  ),
  best_sell AS (
    SELECT country_code FROM cards WHERE evaluated AND universe_status='ELIGIBLE' AND within_selling AND market_decision IN ('TEST','WATCH')
    ORDER BY drank DESC, market_opportunity_score DESC NULLS LAST, country_code LIMIT 1
  ),
  built AS (
    SELECT c.*, (c.country_code = (SELECT country_code FROM best)) AS is_recommended,
      CASE WHEN c.evaluated THEN 'EVALUATED' WHEN c.universe_status='ELIGIBLE' THEN 'ANALYSIS_REQUIRED'
        WHEN c.universe_status='LIMITED_EVIDENCE' THEN 'LIMITED_EVIDENCE' ELSE 'UNSUPPORTED' END AS evaluation_state
    FROM cards c
  )
  SELECT jsonb_build_object('contract','pulse_country_opportunity_explorer_v1','product_id', p_product_id,
    'recommended_best_market', (SELECT to_jsonb(x) FROM (
        SELECT country_code AS country, country_name AS name, region, market_decision AS decision,
          market_opportunity_score AS score, evidence_confidence AS confidence, primary_platform,
          'strongest legitimate evaluated market: highest decision tier then market opportunity score; not biased by country size' AS why
        FROM built WHERE country_code=(SELECT country_code FROM best)) x),
    'global_opportunity', (SELECT country_code FROM best),
    'best_available_within_selling_markets', (SELECT country_code FROM best_sell),
    'selling_market_constraint', to_jsonb(p_selling_markets),
    'markets', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'country', country_code,'name',country_name,'region',region,'currency',default_currency,
        'evaluation_state', evaluation_state,'is_recommended', is_recommended,'universe_status', universe_status,'within_selling_markets', within_selling,
        'decision', market_decision,'score', market_opportunity_score,'confidence', evidence_confidence,
        'buyer_intent', component_scores->'buyer_search_intent'->'subscore','demand_momentum', component_scores->'demand_momentum'->'subscore',
        'marketplace_validation', component_scores->'marketplace_validation'->'subscore','advertising_activity', component_scores->'advertising_activity'->'subscore',
        'competition_saturation_gap', component_scores->'competition_saturation_gap'->'subscore',
        'local_price', evidence->'observed_market_price','stock_state', stock_state,'compliance_risk', compliance_risk,'gate_state', gate_state,
        'economics', CASE WHEN economics IS NULL THEN NULL ELSE jsonb_build_object(
            'currency', economics->'money'->>'display_currency','selling_price', economics->'selling_price','landed_cost', economics->'landed_cost_display',
            'break_even_cpa', economics->'break_even_cpa','contribution_before_ads', economics->'contribution_before_ads',
            'contribution_after_reserve', economics->'contribution_after_reserve','economics_state', economics->>'economics_state') END,
        'cpa_scenarios_local', CASE WHEN economics->'contribution_before_ads' IS NULL THEN NULL ELSE jsonb_build_object(
            'currency', market_currency,'eur_reserve_equiv', true,
            'cpa_eur10', round((economics->>'contribution_before_ads')::numeric - 10*eur2loc, 2),
            'cpa_eur15', round((economics->>'contribution_before_ads')::numeric - 15*eur2loc, 2),
            'cpa_eur20', round((economics->>'contribution_before_ads')::numeric - 20*eur2loc, 2)) END,
        'primary_platform', coalesce(primary_platform, CASE WHEN evaluated THEN 'ANALYSIS_REQUIRED' ELSE NULL END),
        'risks', coalesce(risk_flags,'[]'::jsonb))
        ORDER BY is_recommended DESC, drank DESC, market_opportunity_score DESC NULLS LAST, universe_status, country_code)
      FROM built),'[]'::jsonb),
    'evaluated_count', (SELECT count(*) FROM built WHERE evaluated),
    'analysis_required_count', (SELECT count(*) FROM built WHERE evaluation_state='ANALYSIS_REQUIRED'),
    'safety', jsonb_build_object('campaign_target_market','UNCHANGED','spend_authorized', false,
      'note','selecting a country in the explorer never sets campaign target and never authorizes campaign creation, activation or spend'),
    'country_isolation','each market card is that country''s own evaluation; USA evidence cannot satisfy Germany; UNKNOWN/unevaluated is never treated as favorable',
    'policy','Product x Country canonical; local price stays in local currency; supplier/saturation/economics/platform are country-specific')
  INTO result; RETURN result;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_decision_customer(p_product_id uuid, p_market text, p_selling_price numeric, p_display_currency text, p_fees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_prod public.commerce_products%rowtype; v_prof jsonb; v_dec jsonb; v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_sd jsonb; v_anchor jsonb; v_ctx jsonb; v_handoff jsonb; v_class text; v_rec text;
  v_why text[] := '{}'; v_but text[] := '{}'; v_next text[] := '{}'; r text; d jsonb;
BEGIN
  SELECT * INTO v_prod FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_prof := public.fn_build_evidence_profile_v2(p_product_id, v_mkt);
  IF v_prof->>'status' <> 'ok' THEN RETURN v_prof; END IF;
  v_dec := public.fn_canonical_product_decision_v2(v_prof->'profile', v_prof->'product', v_prof->'supplier',
             v_prof->'reviews', NULL, v_prof->'market_advantage', p_fees, v_prof->'cx_signals', v_mkt, p_selling_price, p_display_currency);
  v_class := v_dec->>'classification'; v_rec := v_dec->>'recommendation';

  SELECT value INTO v_sd FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='SEARCH_DEMAND'
     AND upper(value->>'market')=v_mkt ORDER BY observed_at DESC LIMIT 1;
  SELECT jsonb_build_object('price_min',min((value->>'price')::numeric),'price_max',max((value->>'price')::numeric),
         'currency',min(value->>'currency'),'listings',count(*)) INTO v_anchor
     FROM public.commerce_signals WHERE product_id=p_product_id AND signal_type='MARKETPLACE_ACTIVITY' AND upper(value->>'market')=v_mkt;

  -- WHY (positives)
  FOR r IN SELECT jsonb_array_elements_text(coalesce(v_dec->'reasons_for','[]'::jsonb)) LOOP v_why := array_append(v_why, r); END LOOP;
  IF (v_dec->'buyer_intent'->>'state')='OBSERVED' THEN
    v_why := array_append(v_why,'Real buyer intent OBSERVED (score '||coalesce(v_dec->'buyer_intent'->>'score','?')||', band '||coalesce(v_sd->>'buyer_intent_band','?')||') — estimated search volume, inferred intent');
  END IF;
  IF (v_dec->'marketplace_validation'->>'state')='OBSERVED' THEN
    v_why := array_append(v_why,'Active marketplace presence OBSERVED ('||coalesce(v_anchor->>'listings','?')||' eBay listings, '||coalesce(v_anchor->>'price_min','?')||'-'||coalesce(v_anchor->>'price_max','?')||' '||coalesce(v_anchor->>'currency','')||') — listings, NOT sales');
  END IF;

  -- BUT (limitations / missing / binding constraints)
  FOR r IN SELECT jsonb_array_elements_text(coalesce(v_dec->'reasons_against','[]'::jsonb)) LOOP v_but := array_append(v_but, r); END LOOP;
  IF (v_dec->'advertising_validation'->>'state') <> 'OBSERVED' THEN v_but := array_append(v_but,'Advertising/competitor creative '||(v_dec->'advertising_validation'->>'state')||' in this market'); END IF;
  IF (v_dec->'viral_potential'->>'state') <> 'PARTIAL' THEN v_but := array_append(v_but,'Social/viral momentum not observed for this product'); END IF;
  IF (v_dec->'competition_risk'->>'risk_level')='UNKNOWN' THEN v_but := array_append(v_but,'Competition/saturation not yet measurable (needs full marketplace census / trend history)'); END IF;
  IF (v_dec->>'supply_confidence')='BETA_ACCEPTABLE_RELIABILITY_UNOBSERVED' THEN v_but := array_append(v_but,'Supplier reliability NOT observable from CJ — beta-acceptable, caps confidence below full verification'); END IF;
  IF nullif(v_dec->>'opportunity_score','')::numeric < 70 THEN v_but := array_append(v_but,'Opportunity score '||(v_dec->>'opportunity_score')||' is below the 70 STRONG-TEST band'); END IF;

  -- NEXT
  v_next := array_append(v_next, 'Primary action: '||coalesce(v_dec->>'recommended_next_action','GET_MORE_EVIDENCE'));
  FOR r IN SELECT jsonb_array_elements_text(coalesce(v_dec->'evidence_needed_next','[]'::jsonb)) LOOP v_next := array_append(v_next,'Gather: '||r); END LOOP;

  v_ctx := jsonb_build_object('product_id',p_product_id,'product_title',v_prod.title,
    'positioning', coalesce(v_sd->>'headline_query', v_prod.extended->>'normalized_name', v_prod.title),
    'supplier_reference', jsonb_build_object('source', v_prof->'supplier'->>'source','cj_source_product_id', v_prod.extended->>'cj_source_product_id'),
    'selling_price', p_selling_price, 'display_currency', p_display_currency,
    'buyer_intent', jsonb_build_object('score', v_sd->>'buyer_intent_score','band', v_sd->>'buyer_intent_band','subscores', v_sd->'subscores'),
    'competitive_price_anchor', v_anchor,
    'product_assets', NULL, 'audience_evidence', NULL,
    'provenance', jsonb_build_object('engine','wps_v2','buyer_intent','GOOGLE_ADS_via_DATAFORSEO','marketplace','EBAY_BROWSE_API','supply','CJ'));
  v_handoff := public.fn_store_builder_payload(v_dec, v_ctx);

  RETURN jsonb_build_object(
    'product_id', p_product_id, 'product_title', v_prod.title, 'target_market', v_mkt,
    'classification', v_class, 'recommended_action', v_rec, 'operational_next_action', v_dec->>'recommended_next_action',
    'opportunity_score', v_dec->>'opportunity_score', 'evidence_confidence', v_dec->>'evidence_confidence',
    'buyer_intent', v_dec->'buyer_intent', 'marketplace_validation', v_dec->'marketplace_validation',
    'advertising_validation', v_dec->'advertising_validation', 'viral_potential', v_dec->'viral_potential',
    'competition_risk', v_dec->'competition_risk',
    'supplier', jsonb_build_object('supply_confidence', v_dec->>'supply_confidence',
        'reliability_state', v_dec->'supplier_execution'->>'reliability_state',
        'execution_gate', v_dec->'supplier_execution'->>'supplier_execution_gate',
        'landed_cost_display', v_dec->'economics'->>'landed_cost_display', 'selling_price', p_selling_price,
        'margin', v_dec->'economics'->>'margin', 'margin_pct', v_dec->'economics'->>'margin_pct',
        'economics_state', v_dec->'economics'->>'economics_state', 'delivery', v_dec->'supplier_execution'->'delivery'),
    'product_trust', jsonb_build_object('gate', v_dec->'product_trust'->>'gate'),
    'explanation', jsonb_build_object('DECISION', v_class, 'WHY', to_jsonb(v_why), 'BUT', to_jsonb(v_but), 'WHAT_TO_DO_NEXT', to_jsonb(v_next)),
    'action_handoff', jsonb_build_object('classification', v_class, 'auto_launch_campaign', false,
        'allowed_next', CASE WHEN v_rec='TEST' THEN jsonb_build_array('BUILD_PRODUCT_PAGE','AD_STUDIO_DRAFT')
                             WHEN v_class='AVOID' THEN jsonb_build_array('DROP_CANDIDATE')
                             ELSE jsonb_build_array('CONTINUE_WATCH','GET_MORE_EVIDENCE') END,
        'campaign_launch', CASE WHEN v_rec='TEST' THEN 'PAUSED_DRAFT_ONLY_requires_explicit_founder_approval' ELSE 'BLOCKED_requires_TEST_decision' END,
        'note','WATCH/AVOID never auto-launch a campaign; WINNER is post-spend only'),
    'store_builder_handoff', v_handoff,
    'lifecycle_note', v_dec->>'lifecycle_note',
    'claim_safety','buyer intent ESTIMATED/INFERRED; marketplace/advertising = presence not sales; supplier reliability unobserved; no WINNER pre-spend');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_opportunity_score(p_dims jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  w jsonb := jsonb_build_object(
    'search_buyer_intent',25,'social_viral',20,'marketplace_validation',15,
    'advertising_competitor',15,'supplier_quality_economics',15,'competition_saturation_gap',10);
  d text; dim jsonb; st text; sc numeric; wt numeric;
  num numeric := 0; den numeric := 0;
  detail jsonb := '{}'::jsonb; blocked text[] := '{}'; notobs text[] := '{}'; observed text[] := '{}';
BEGIN
  FOREACH d IN ARRAY ARRAY['search_buyer_intent','social_viral','marketplace_validation','advertising_competitor','supplier_quality_economics','competition_saturation_gap'] LOOP
    dim := p_dims->d;
    st := coalesce(dim->>'state','NOT_OBSERVED');
    sc := nullif(dim->>'score','')::numeric;
    wt := (w->>d)::numeric;
    IF st = 'OBSERVED' AND sc IS NOT NULL THEN
      num := num + sc*wt; den := den + wt; observed := array_append(observed,d);
      detail := detail || jsonb_build_object(d, jsonb_build_object(
        'evidence_state',st,'raw_score',sc,'max_weight',wt,'weighted_contribution',round(sc*wt/100.0,2),
        'confidence',dim->>'confidence','counts_toward_score',true));
    ELSE
      IF st = 'SOURCE_BLOCKED' THEN blocked := array_append(blocked,d); END IF;
      IF st IN ('NOT_OBSERVED','SOURCE_UNSUPPORTED','INSUFFICIENT_EVIDENCE','STALE') THEN notobs := array_append(notobs,d); END IF;
      detail := detail || jsonb_build_object(d, jsonb_build_object(
        'evidence_state',st,'raw_score',NULL,'max_weight',wt,'weighted_contribution',0,
        'confidence',dim->>'confidence','counts_toward_score',false,
        'blocked_reason',dim->>'blocked_reason','note','excluded from score; not scored as zero'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'opportunity_score', CASE WHEN den > 0 THEN round(num/den) ELSE NULL END,
    'score_basis','weighted_average_over_OBSERVED_dimensions_only',
    'observed_weight', den, 'total_weight', 100,
    'evidence_completeness', round(den/100.0,2),
    'evidence_completeness_note','fraction of the 100-pt evidence stack actually observed; separate from score quality',
    'dimensions', detail,
    'observed_dimensions', to_jsonb(observed),
    'blocked_sources', to_jsonb(blocked),
    'not_observed_dimensions', to_jsonb(notobs),
    'insufficient', (den = 0));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_quality_state(p_reviews jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_total int := nullif(btrim(p_reviews->>'total'),'')::int;
  v_avg numeric := nullif(btrim(p_reviews->>'avg_score'),'')::numeric;  -- 0..5 scale
  v_neg_share numeric := nullif(btrim(p_reviews->>'neg_share'),'')::numeric; -- share of 1-2 star
  v_pos_share numeric := nullif(btrim(p_reviews->>'pos_share'),'')::numeric; -- share of 4-5 star
  c_min_sample int := 3;
  v_state text; v_sub numeric := NULL; v_known boolean := false; v_reason text;
BEGIN
  IF p_reviews IS NULL OR v_total IS NULL THEN
    RETURN jsonb_build_object('dimension','product_quality','state','PRODUCT_QUALITY_UNKNOWN','known',false,
      'critical',false,'reason','reviews_not_fetched','provenance','PLATFORM_REPORTED_OR_ABSENT');
  END IF;
  IF v_total = 0 THEN
    RETURN jsonb_build_object('dimension','product_quality','state','PRODUCT_QUALITY_UNKNOWN','known',false,
      'critical',false,'reason','NO_REVIEWS_FOUND','review_count',0,
      'note','absence of reviews is not evidence of quality; never scored as zero');
  END IF;
  IF v_total < c_min_sample THEN
    RETURN jsonb_build_object('dimension','product_quality','state','PRODUCT_QUALITY_INSUFFICIENT','known',false,
      'critical',false,'reason','below_min_sample','review_count',v_total,'min_sample',c_min_sample);
  END IF;
  IF v_avg IS NULL THEN
    RETURN jsonb_build_object('dimension','product_quality','state','PRODUCT_QUALITY_INSUFFICIENT','known',false,
      'critical',false,'reason','review_count_without_score','review_count',v_total);
  END IF;
  -- conflicting: material polarization on both ends
  IF coalesce(v_neg_share,0) >= 0.30 AND coalesce(v_pos_share,0) >= 0.30 THEN
    v_state := 'PRODUCT_QUALITY_CONFLICTING'; v_sub := 45; v_known := true; v_reason := 'polarized_reviews';
  ELSIF v_avg >= 4.3 THEN v_state := 'PRODUCT_QUALITY_STRONG'; v_sub := 90; v_known := true; v_reason := 'high_avg_score';
  ELSIF v_avg >= 3.7 THEN v_state := 'PRODUCT_QUALITY_ACCEPTABLE'; v_sub := 70; v_known := true; v_reason := 'moderate_avg_score';
  ELSE v_state := 'PRODUCT_QUALITY_WEAK'; v_sub := CASE WHEN v_avg >= 3.0 THEN 35 ELSE 15 END; v_known := true; v_reason := 'low_avg_score';
  END IF;
  RETURN jsonb_build_object('dimension','product_quality','state',v_state,'known',v_known,
    'critical',(v_state='PRODUCT_QUALITY_WEAK' AND v_avg < 3.0 AND v_total >= 10),
    'subscore',v_sub,'review_count',v_total,'avg_score',v_avg,'reason',v_reason,
    'source',p_reviews->>'source','observed_at',p_reviews->>'observed_at','provenance','PLATFORM_REPORTED');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_trust_classification(p_product jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text := lower(coalesce(p_product->>'title','')||' '||coalesce(p_product->>'title_original','')||' '||coalesce(p_product->>'name',''));
  v_desc  text := lower(coalesce(p_product->>'description',''));
  v_brand text := lower(btrim(coalesce(p_product->>'brand','')));
  v_cat   text := lower(coalesce(p_product->>'category',''));
  v_hay   text := v_title||' '||v_desc||' '||v_brand||' '||v_cat;
  v_material text := lower(coalesce(p_product->>'material','')||' '||coalesce(p_product->>'material_key',''));
  ip_tokens text[] := ARRAY['disney','marvel','pixar','star wars','pokemon','pokémon','nintendo','super mario','sonic the','hello kitty','sanrio','lego','barbie','harry potter','dc comics','batman','superman','spider-man','spiderman','avengers','frozen elsa','bluey','paw patrol','minecraft','fortnite','nba','nfl',' mlb ','fifa','uefa','premier league','formula 1','funko','squid game','naruto','sailor moon','hatsune'];
  brand_tokens text[] := ARRAY['nike','adidas','puma','air jordan','apple ','iphone','ipad','airpod','samsung galaxy','playstation','xbox','bose','gucci','louis vuitton','chanel','rolex','prada','dior','versace','hermes','burberry','supreme','yeezy','the north face','dyson','lululemon','ray-ban','rayban','oakley','stanley 1913'];
  commodity_cat text[] := ARRAY['home','garden','furniture','storage','kitchen','tool','pet','beauty','phone accessor','car accessor','office','cleaning','organizer','outdoor','lighting','bathroom','hardware','automotive','sports & entertainment'];
  func_words text[] := ARRAY['repair','patch','holder','organizer','organiser','cleaner','cover','protector','stand','mount','rack','storage','brush','clip','strap',' mat ','sticker','dispenser','sponge','peeler','grip','hook','cutter','trimmer','opener','wrap','pad ','massager','gadget','accessory','tools','kit'];
  v_tm boolean := (v_hay ~ '[®™©]');
  v_ip boolean := EXISTS (SELECT 1 FROM unnest(ip_tokens) t WHERE v_hay LIKE '%'||t||'%');
  v_brand_hit boolean := (v_brand <> '' AND v_brand NOT IN ('none','n/a','no brand','generic','unbranded','oem'))
                         OR EXISTS (SELECT 1 FROM unnest(brand_tokens) t WHERE v_hay LIKE '%'||t||'%');
  v_cat_hit boolean := EXISTS (SELECT 1 FROM unnest(commodity_cat) t WHERE v_cat LIKE '%'||t||'%');
  v_func_hit boolean := EXISTS (SELECT 1 FROM unnest(func_words) t WHERE v_title LIKE '%'||t||'%');
  v_generic_ev boolean := v_cat_hit OR (v_func_hit AND btrim(v_material) <> '');
  v_class text; v_conf text; v_ev text[] := '{}'; v_risks text[] := '{}'; v_unknowns text[] := '{}';
BEGIN
  IF v_ip THEN
    v_class := 'LICENSED_OR_IP_SENSITIVE'; v_conf := 'HIGH';
    v_ev := array_append(v_ev,'ip_or_licensed_token_detected');
    v_risks := array_append(v_risks,'ip_infringement_risk');
  ELSIF v_brand_hit OR v_tm THEN
    v_class := 'BRANDED'; v_conf := CASE WHEN v_tm OR v_brand<>'' THEN 'HIGH' ELSE 'MEDIUM' END;
    IF v_tm THEN v_ev := array_append(v_ev,'trademark_symbol_present'); END IF;
    IF v_brand<>'' THEN v_ev := array_append(v_ev,'brand_field_present'); END IF;
    IF EXISTS (SELECT 1 FROM unnest(brand_tokens) t WHERE v_hay LIKE '%'||t||'%') THEN v_ev := array_append(v_ev,'known_brand_token'); END IF;
    v_risks := array_append(v_risks,'authenticity_required');
  ELSIF v_generic_ev AND NOT v_brand_hit AND NOT v_ip AND NOT v_tm THEN
    v_class := 'GENERIC_UNBRANDED';
    v_conf := CASE WHEN v_cat_hit AND v_func_hit THEN 'HIGH' WHEN v_cat_hit OR v_func_hit THEN 'MEDIUM' ELSE 'LOW' END;
    IF v_cat_hit THEN v_ev := array_append(v_ev,'commodity_category'); END IF;
    IF v_func_hit THEN v_ev := array_append(v_ev,'functional_descriptive_title'); END IF;
    v_ev := array_append(v_ev,'no_brand_or_ip_or_trademark_signal');
  ELSE
    -- No protected-identity signal AND no affirmative generic evidence -> cannot safely call generic.
    v_class := 'UNKNOWN'; v_conf := 'LOW';
    v_unknowns := array_append(v_unknowns,'brand_status_indeterminate');
    v_risks := array_append(v_risks,'authenticity_unresolved');
  END IF;

  RETURN jsonb_build_object(
    'classification', v_class, 'confidence', v_conf,
    'evidence', to_jsonb(v_ev), 'risk_flags', to_jsonb(v_risks), 'unknowns', to_jsonb(v_unknowns),
    'signals', jsonb_build_object('ip', v_ip, 'brand', v_brand_hit, 'trademark_symbol', v_tm,
                                  'commodity_category', v_cat_hit, 'functional_title', v_func_hit),
    'provenance', jsonb_build_object('method','deterministic_rule','source','product_metadata',
                                     'note','LLM cannot override; evidence-driven only'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_product_trust_gate(p_classification jsonb, p_authenticity jsonb, p_quality jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_class text := p_classification->>'classification';
  v_auth_sat boolean := (p_authenticity->>'satisfied')::boolean;
  v_auth_gating boolean := (p_authenticity->>'gating')::boolean;
  v_q text := p_quality->>'state';
  v_gate text; v_reasons text[] := '{}';
BEGIN
  -- Branded / licensed without satisfied authenticity => BLOCKED from any trust pass.
  IF v_class IN ('BRANDED','LICENSED_OR_IP_SENSITIVE') AND NOT coalesce(v_auth_sat,false) THEN
    RETURN jsonb_build_object('product_trust_gate','PRODUCT_TRUST_BLOCKED',
      'reasons', to_jsonb(ARRAY['authenticity_'||coalesce(p_authenticity->>'state','MISSING')]),
      'classification',v_class,'quality_state',v_q);
  END IF;
  -- Unknown brand status can never reach strongest trust.
  IF v_class = 'UNKNOWN' THEN
    RETURN jsonb_build_object('product_trust_gate','PRODUCT_TRUST_WATCH',
      'reasons', to_jsonb(ARRAY['brand_status_unknown_authenticity_unresolved']),'classification',v_class,'quality_state',v_q);
  END IF;
  -- Quality-driven cap (brand-safe path: generic, or branded/licensed with satisfied authenticity).
  IF v_q IN ('PRODUCT_QUALITY_STRONG','PRODUCT_QUALITY_ACCEPTABLE') THEN
    v_gate := 'PRODUCT_TRUST_PASS'; v_reasons := array_append(v_reasons,'brand_safe_and_quality_supported');
  ELSIF v_q IN ('PRODUCT_QUALITY_UNKNOWN','PRODUCT_QUALITY_INSUFFICIENT') THEN
    v_gate := 'PRODUCT_TRUST_ACCEPTABLE'; v_reasons := array_append(v_reasons,'brand_safe_quality_unproven');
  ELSE -- WEAK or CONFLICTING
    v_gate := 'PRODUCT_TRUST_WATCH'; v_reasons := array_append(v_reasons,'quality_risk_'||v_q);
  END IF;
  IF (p_quality->>'critical')::boolean THEN
    v_gate := 'PRODUCT_TRUST_WATCH'; v_reasons := array_append(v_reasons,'critical_quality_signal');
  END IF;
  RETURN jsonb_build_object('product_trust_gate',v_gate,'reasons',to_jsonb(v_reasons),
    'classification',v_class,'authenticity_state',p_authenticity->>'state','quality_state',v_q);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_public_storefront_render(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  sp public.commerce_store_projects%rowtype;
  pm jsonb; rc jsonb; v_assets jsonb;
BEGIN
  SELECT * INTO sp FROM public.commerce_store_projects WHERE (public_route = p_slug OR slug = p_slug) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = sp.product_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  IF coalesce(p.publication_state,'') <> 'PUBLISHED' THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  pm := coalesce(p.page_model,'{}'::jsonb);
  rc := coalesce(p.runtime_contract,'{}'::jsonb);
  v_assets := rc->'supplier_asset_refs';
  RETURN jsonb_build_object(
    'status','OK',
    'storefront', jsonb_build_object(
      'slug', coalesce(sp.public_route, sp.slug),
      'template_family', p.template_family,
      'template_version', p.template_version,
      'market', p.market,
      'country_code', p.country_code,
      'currency', jsonb_build_object('display', p.display_currency, 'source', p.source_currency),
      'offer', jsonb_build_object('price', p.selling_price, 'currency', p.display_currency,
                 'note','no fabricated discount or crossed-out price'),
      'hero', jsonb_build_object('variant', rc->>'hero_variant',
                 'headline', pm->'hero'->>'headline', 'subheadline', pm->'hero'->>'subheadline'),
      'sections', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'type', s->>'type', 'order', s->'order',
                     'conversion_role', s->>'conversion_role', 'render', s->'render') ORDER BY (s->>'order')::int),'[]'::jsonb)
                   FROM jsonb_array_elements(coalesce(rc->'sections','[]'::jsonb)) s),
      'cta_structure', rc->'cta_structure',
      'copy', jsonb_build_object(
         'product_title', pm->>'product_title',
         'short_description', pm->>'short_description',
         'benefits', pm->'benefits',
         'how_it_works', pm->'how_it_works',
         'problem_solution', pm->'problem_solution',
         'shipping', jsonb_build_object('copy', pm->'shipping'->>'copy',
             'est_min_days', pm->'shipping'->>'est_min_days','est_max_days', pm->'shipping'->>'est_max_days',
             'method', pm->'shipping'->>'method'),
         'trust', jsonb_build_object('copy', pm->'trust'->>'copy','disclaimers', pm->'trust'->'disclaimers'),
         'faq', pm->'faq',
         'seo', jsonb_build_object('title', pm->'seo'->>'title','meta_description', pm->'seo'->>'meta_description')),
      'assets', jsonb_build_object(
         'primary_image', v_assets->'primary_image'->>'source_url',
         'gallery', (SELECT coalesce(jsonb_agg(g->>'source_url'),'[]'::jsonb)
                     FROM jsonb_array_elements(coalesce(v_assets->'gallery','[]'::jsonb)) g),
         'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS' ELSE 'IMAGE_UNAVAILABLE' END),
      'video', jsonb_build_object(
         'state', coalesce(v_assets->>'video_state','VIDEO_ASSET_NOT_AVAILABLE'),
         'url', CASE WHEN v_assets->>'video_state'='VIDEO_AVAILABLE' THEN v_assets->'video'->>'source_url' ELSE NULL END,
         'origin_kind', v_assets->'video'->>'origin_kind'),
      'claim_safety', jsonb_build_object(
         'no_reviews_fabricated', true, 'no_fake_discount', true, 'no_guaranteed_delivery', true,
         'no_urgency_scarcity', true, 'delivery_labeled_estimate', true,
         'claim_scan_clean', (rc->'claim_safety'->>'claim_scan_clean')::boolean),
      'product_provenance', jsonb_build_object(
         'title', pm->>'product_title', 'condition','New',
         'fulfilment','Ships from the supplier warehouse; delivery times are estimates',
         'evidence_basis','SUPPLIER_CONFIRMED'),
      'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED',
         'functional', false,
         'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
         'note','no payment/checkout provider connected; add-to-cart CTA is non-functional (no fabricated checkout)'),
      'publication', jsonb_build_object('state','PUBLISHED','noindex', true)));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_rank_candidate_fulfilment(p_product_id uuid, p_market text, p_display_currency text, p_market_price numeric, p_ad_reserve numeric DEFAULT 15, p_variable_costs numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_ext jsonb; v_refs jsonb; v_ref jsonb;
  v_sup public.commerce_supplier_products%rowtype;
  v_market text := upper(btrim(coalesce(p_market,'')));
  v_rep jsonb; v_stock jsonb; v_ship_raw numeric; v_ship_ccy text; v_ship_cost numeric; v_conv jsonb;
  v_option jsonb; v_options jsonb := '[]'::jsonb; v_eval jsonb;
BEGIN
  SELECT coalesce(extended,'{}'::jsonb) INTO v_ext FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found','product_id',p_product_id); END IF;

  v_refs := coalesce(v_ext->'supplier_refs','[]'::jsonb);
  -- back-compat: single supplier_ref (or legacy cj_source_product_id) with no refs array
  IF jsonb_array_length(v_refs)=0 THEN
    IF v_ext ? 'supplier_ref' THEN
      v_refs := jsonb_build_array(v_ext->'supplier_ref');
    ELSIF nullif(btrim(v_ext->>'cj_source_product_id'),'') IS NOT NULL THEN
      v_refs := jsonb_build_array(jsonb_build_object('provider','CJ','source_product_id',v_ext->>'cj_source_product_id'));
    END IF;
  END IF;

  IF jsonb_array_length(v_refs)=0 THEN
    RETURN jsonb_build_object('status','ok','product_id',p_product_id,'market',v_market,
      'fulfilment', public.fn_fulfilment_rollup('[]'::jsonb),
      'note','no supplier linked to this candidate');
  END IF;

  FOR v_ref IN SELECT * FROM jsonb_array_elements(v_refs) LOOP
    SELECT * INTO v_sup FROM public.commerce_supplier_products
      WHERE source_product_id = v_ref->>'source_product_id'
        AND public.fn_supplier_provider_canon(source) = public.fn_supplier_provider_canon(v_ref->>'provider')
      LIMIT 1;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_rep   := v_sup.supplier_enrichment #> ARRAY['freight', v_market, 'representative'];
    v_stock := v_sup.supplier_enrichment -> 'stock';

    -- shipping cost normalized into supplier cost currency (fail-closed: leave null if cannot convert)
    v_ship_raw := nullif(btrim(v_rep->>'shipping_cost'),'')::numeric;
    v_ship_ccy := upper(coalesce(nullif(btrim(v_rep->>'shipping_currency'),''), v_sup.cost_currency, 'USD'));
    v_ship_cost := NULL;
    IF v_ship_raw IS NOT NULL THEN
      IF v_ship_ccy = upper(coalesce(v_sup.cost_currency,'USD')) THEN
        v_ship_cost := v_ship_raw;
      ELSE
        v_conv := public.normalize_money(v_ship_raw, v_ship_ccy, upper(coalesce(v_sup.cost_currency,'USD')));
        v_ship_cost := nullif(v_conv->>'converted_amount','')::numeric;
      END IF;
    END IF;

    v_option := jsonb_build_object(
      'provider', public.fn_supplier_provider_canon(v_sup.source),
      'source_product_id', v_sup.source_product_id,
      'title', v_sup.title,
      'image_url', v_sup.image_url,
      'supplier_cost', v_sup.supplier_cost,
      'cost_currency', upper(coalesce(v_sup.cost_currency,'USD')),
      'is_free_shipping', coalesce(v_sup.is_free_shipping,false),
      'shipping_cost', v_ship_cost,
      'shipping_country_codes', v_sup.shipping_country_codes,
      'warehouse_country', coalesce(v_stock->>'warehouse_country', v_sup.supplier_enrichment->>'warehouse_country'),
      'stock', v_stock,
      'delivery_estimate', v_rep);

    v_eval := public.fn_fulfilment_evaluate_option(v_option, v_market, p_display_currency, p_market_price, p_ad_reserve, p_variable_costs);
    v_options := v_options || jsonb_build_array(v_eval);
  END LOOP;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id,'market',v_market,
    'display_currency', upper(coalesce(p_display_currency,'')),
    'market_price', p_market_price,
    'fulfilment', public.fn_fulfilment_rollup(v_options));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_rank_product_markets(p_tenant uuid, p_product uuid, p_score_version text DEFAULT 'pm_score_v1'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH ranked AS (
    SELECT e.*,
      CASE e.market_decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END AS dec_rank,
      CASE e.evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END AS conf_rank,
      nullif(e.economics->>'contribution_after_reserve','')::numeric AS contrib,
      row_number() OVER (ORDER BY
        CASE e.market_decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
        e.market_opportunity_score DESC NULLS LAST,
        CASE e.evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END ASC,
        nullif(e.economics->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
        e.country_code ASC) AS rnk
    FROM public.product_market_evaluations e
    WHERE e.tenant_id = p_tenant AND e.product_id = p_product AND e.score_version = p_score_version
  )
  SELECT jsonb_build_object(
    'product_id', p_product, 'tenant_id', p_tenant, 'score_version', p_score_version,
    'evaluated_markets', (SELECT count(*) FROM ranked),
    'markets', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'rank', rnk, 'country', country_code, 'market_currency', market_currency,
        'market_score', market_opportunity_score, 'confidence', evidence_confidence,
        'decision', market_decision, 'gate_state', gate_state,
        'buyer_intent', evidence->'buyer_search_intent', 'demand', evidence->'demand_momentum',
        'marketplace', evidence->'marketplace_validation', 'competitor_saturation', evidence->'competition_saturation_gap',
        'advertising', evidence->'advertising_activity', 'selling_price', evidence->'observed_market_price',
        'supplier_stock', stock_state, 'landed_cost', economics->'landed_cost_display',
        'contribution_after_reserve', contrib, 'delivery', evidence->'delivery_evidence',
        'advertising_headroom', economics->'break_even_cpa', 'compliance_risk', compliance_risk,
        'risks', decision_reasons, 'reason_for_rank', decision_reasons
      ) ORDER BY rnk) FROM ranked), '[]'::jsonb),
    -- recommended = strongest overall (rank #1); NOT auto home/selling market, NOT auto campaign market
    'recommended_market', (SELECT country_code FROM ranked WHERE rnk = 1),
    'recommended_decision', (SELECT market_decision FROM ranked WHERE rnk = 1),
    'recommended_is_test', (SELECT (market_decision = 'TEST') FROM ranked WHERE rnk = 1),
    'note', 'recommended_market is the strongest evidence-ranked opportunity; it does NOT set campaign_target_market (separate approval).',
    'contract', 'pulse_product_market_ranking_v1'
  );
$function$
;

CREATE OR REPLACE FUNCTION public.fn_rank_suppliers(p_suppliers jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_min numeric; v_res jsonb;
BEGIN
  SELECT min(nullif(r->'economics'->>'landed_cost_display','')::numeric) INTO v_min
    FROM (SELECT public.fn_evaluate_supplier(e, p_target_market, p_selling_price, p_display_currency) r
          FROM jsonb_array_elements(p_suppliers) e) z;
  WITH ev AS (
    SELECT public.fn_evaluate_supplier(e, p_target_market, p_selling_price, p_display_currency) r
    FROM jsonb_array_elements(p_suppliers) e),
  keyed AS (
    SELECT r,
      CASE r->>'supplier_gate' WHEN 'PASS' THEN 0 WHEN 'WATCH' THEN 1 WHEN 'INSUFFICIENT_EVIDENCE' THEN 2 ELSE 3 END AS gate_rank,
      coalesce((r->'supplier_quality_score'->>'score')::numeric, -1) AS score_sort
    FROM ev),
  ranked AS (
    SELECT r, gate_rank, score_sort, row_number() OVER (ORDER BY gate_rank, score_sort DESC) AS rnk
    FROM keyed)
  SELECT jsonb_agg(
    (r || jsonb_build_object(
      'rank', rnk,
      'why_not_cheapest', CASE
        WHEN nullif(r->'economics'->>'landed_cost_display','')::numeric IS NULL THEN 'landed cost unknown'
        WHEN nullif(r->'economics'->>'landed_cost_display','')::numeric > coalesce(v_min,0)
          THEN 'not the cheapest, but stronger supplier gate/quality justifies it'
        ELSE 'this is the cheapest viable option' END,
      'why_recommended', CASE r->>'supplier_gate'
        WHEN 'PASS' THEN 'supplier gate PASS with sufficient evidence'
        WHEN 'WATCH' THEN 'best available but not a confident PASS'
        WHEN 'INSUFFICIENT_EVIDENCE' THEN 'insufficient supplier evidence to recommend'
        ELSE 'failed supplier gate' END))
    ORDER BY rnk) INTO v_res FROM ranked;
  RETURN jsonb_build_object('target_market', upper(coalesce(p_target_market,'UNKNOWN')),
    'cheapest_landed_display', v_min, 'ranked', coalesce(v_res,'[]'::jsonb));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_release_spend(p_tenant uuid, p_authority_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.spend_reservations;
BEGIN
  SELECT * INTO r FROM public.spend_reservations WHERE authority_id=p_authority_id AND idempotency_key=p_idempotency_key AND tenant_id=p_tenant FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF r.status<>'RESERVED' THEN RETURN jsonb_build_object('status','idempotent','reservation_status',r.status); END IF;
  UPDATE public.spend_reservations SET status='RELEASED', released_at=now() WHERE id=r.id;
  UPDATE public.marketing_spend_authority SET reserved = greatest(0, reserved - r.amount) WHERE id=p_authority_id;
  PERFORM public.fn_authority_audit(p_tenant,'SPEND_RELEASED',NULL,p_authority_id,r.campaign_id,to_jsonb(r),NULL,NULL,p_idempotency_key);
  RETURN jsonb_build_object('status','RELEASED','reservation_id',r.id,'amount',r.amount);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_request_activation(p_actor uuid, p_tenant uuid, p_cb_campaign_id uuid, p_authority_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts; a public.marketing_spend_authority; v_reasons text[] := '{}'; v_ok boolean;
  v_budget_minor numeric; v_id uuid; v_tok text;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_campaign_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO a FROM public.marketing_spend_authority WHERE id=p_authority_id AND tenant_id=p_tenant;

  IF c.status<>'APPROVED' THEN v_reasons := array_append(v_reasons,'campaign_not_approved'); END IF;
  IF c.cb_approved_fingerprint IS NULL OR c.cb_approved_fingerprint<>c.cb_fingerprint THEN v_reasons := array_append(v_reasons,'campaign_fingerprint_stale'); END IF;
  IF c.campaign_target_market IS NULL THEN v_reasons := array_append(v_reasons,'no_target_market'); END IF;
  IF c.destination_state<>'VALID' THEN v_reasons := array_append(v_reasons,'destination_invalid'); END IF;
  IF (c.media_gate->>'gate')<>'PASS' OR c.non_executable_fixture THEN v_reasons := array_append(v_reasons,'media_not_launch_safe'); END IF;
  IF c.tracking_state NOT IN ('READY') THEN v_reasons := array_append(v_reasons,'tracking_not_configured'); END IF;
  IF a.id IS NULL THEN v_reasons := array_append(v_reasons,'no_authority');
  ELSE
    IF NOT a.executable THEN v_reasons := array_append(v_reasons,'authority_not_executable'); END IF;
    IF a.is_synthetic THEN v_reasons := array_append(v_reasons,'authority_synthetic'); END IF;
    IF a.status<>'ACTIVE' THEN v_reasons := array_append(v_reasons,'authority_not_active'); END IF;
    IF a.authorized_total<=0 THEN v_reasons := array_append(v_reasons,'authority_zero'); END IF;
    IF upper(coalesce(c.currency_execution,''))<>a.execution_currency THEN v_reasons := array_append(v_reasons,'currency_mismatch'); END IF;
    IF a.ad_account IS NULL THEN v_reasons := array_append(v_reasons,'no_ad_account'); END IF;
    IF NOT (a.allowed_markets ? coalesce(c.campaign_target_market,'')) THEN v_reasons := array_append(v_reasons,'market_not_allowed'); END IF;
    IF a.mode='BOUNDED_AUTO' AND NOT (coalesce(a.allowed_actions,'[]'::jsonb) ? 'ACTIVATE') THEN v_reasons := array_append(v_reasons,'auto_activate_action_not_allowed'); END IF;
    IF (c.budget->>'lifetime_minor') IS NULL OR (c.budget->>'end_time') IS NULL THEN v_reasons := array_append(v_reasons,'hard_ceiling_not_established'); END IF;
  END IF;

  v_ok := (array_length(v_reasons,1) IS NULL);
  IF NOT v_ok THEN
    PERFORM public.fn_authority_audit(p_tenant,'ACTIVATION_REJECTED',p_actor,p_authority_id,p_cb_campaign_id,NULL,jsonb_build_object('reasons',to_jsonb(v_reasons)),NULL,p_idempotency_key);
    RETURN jsonb_build_object('status','ACTIVATION_REJECTED','reasons',to_jsonb(v_reasons),'activation_authorized',false,'meta_write_called',false);
  END IF;
  v_budget_minor := (c.budget->>'lifetime_minor')::numeric;
  v_tok := gen_random_uuid()::text || gen_random_uuid()::text;
  INSERT INTO public.activation_authorizations(tenant_id,platform,ad_account,campaign_id,authority_id,token_hash,
    bound_campaign_fp,bound_authority_fp,bound_budget_minor,bound_currency,bound_market,status,single_use,expires_at,idempotency_key)
  VALUES (p_tenant,'META',a.ad_account,p_cb_campaign_id,p_authority_id,md5(v_tok),
    c.cb_approved_fingerprint,a.authority_fingerprint,v_budget_minor,a.execution_currency,c.campaign_target_market,
    'ISSUED',true, now()+interval '15 minutes', p_idempotency_key)
  RETURNING id INTO v_id;
  PERFORM public.fn_authority_audit(p_tenant,'ACTIVATION_APPROVED',p_actor,p_authority_id,p_cb_campaign_id,NULL,jsonb_build_object('activation_id',v_id),NULL,p_idempotency_key);
  RETURN jsonb_build_object('status','ACTIVATION_AUTHORIZED','activation_id',v_id,'expires_in','15m','note','token hash stored server-side; raw token not returned in this unit');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_reserve_spend(p_tenant uuid, p_authority_id uuid, p_campaign_id uuid, p_amount numeric, p_currency text, p_idempotency_key text, p_is_product_test boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.marketing_spend_authority; v_existing public.spend_reservations; v_daily numeric; v_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key)='' THEN RETURN jsonb_build_object('status','idempotency_key_required'); END IF;
  SELECT * INTO a FROM public.marketing_spend_authority WHERE id=p_authority_id AND tenant_id=p_tenant FOR UPDATE;  -- row lock = concurrency safety
  IF NOT FOUND THEN RETURN jsonb_build_object('status','authority_not_found_or_forbidden'); END IF;

  -- idempotency: same key returns the existing reservation, no double-reserve
  SELECT * INTO v_existing FROM public.spend_reservations WHERE authority_id=p_authority_id AND idempotency_key=p_idempotency_key;
  IF FOUND THEN RETURN jsonb_build_object('status','idempotent','reservation_id',v_existing.id,'reservation_status',v_existing.status,'amount',v_existing.amount); END IF;

  IF a.status<>'ACTIVE' THEN RETURN jsonb_build_object('status','rejected','reason','authority_not_active','authority_status',a.status); END IF;
  IF a.end_at IS NOT NULL AND a.end_at <= now() THEN RETURN jsonb_build_object('status','rejected','reason','authority_expired'); END IF;
  IF a.start_at IS NOT NULL AND a.start_at > now() THEN RETURN jsonb_build_object('status','rejected','reason','authority_not_started'); END IF;
  IF upper(coalesce(p_currency,'')) <> a.execution_currency THEN RETURN jsonb_build_object('status','rejected','reason','currency_mismatch','authority_currency',a.execution_currency); END IF;
  IF a.max_campaign > 0 AND p_amount > a.max_campaign THEN RETURN jsonb_build_object('status','rejected','reason','exceeds_max_campaign','max_campaign',a.max_campaign); END IF;
  IF p_is_product_test AND a.max_product_test > 0 AND p_amount > a.max_product_test THEN RETURN jsonb_build_object('status','rejected','reason','exceeds_max_product_test','max_product_test',a.max_product_test); END IF;
  SELECT coalesce(sum(amount),0) INTO v_daily FROM public.spend_reservations
    WHERE authority_id=p_authority_id AND status IN ('RESERVED','COMMITTED') AND created_at::date = now()::date;
  IF a.max_daily > 0 AND (v_daily + p_amount) > a.max_daily THEN RETURN jsonb_build_object('status','rejected','reason','exceeds_max_daily','max_daily',a.max_daily,'today',v_daily); END IF;
  IF (a.spent + a.reserved + p_amount) > a.authorized_total THEN
    RETURN jsonb_build_object('status','rejected','reason','exceeds_authorized_total','authorized_total',a.authorized_total,'spent',a.spent,'reserved',a.reserved); END IF;

  INSERT INTO public.spend_reservations(authority_id,tenant_id,campaign_id,amount,currency,status,idempotency_key)
  VALUES (p_authority_id,p_tenant,p_campaign_id,p_amount,upper(p_currency),'RESERVED',p_idempotency_key)
  RETURNING id INTO v_id;
  UPDATE public.marketing_spend_authority SET reserved = reserved + p_amount WHERE id=p_authority_id;  -- CHECK(spent+reserved<=authorized_total) is the DB backstop
  PERFORM public.fn_authority_audit(p_tenant,'SPEND_RESERVED',NULL,p_authority_id,p_campaign_id,NULL,jsonb_build_object('amount',p_amount,'reservation_id',v_id),NULL,p_idempotency_key);
  RETURN jsonb_build_object('status','RESERVED','reservation_id',v_id,'amount',p_amount);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_tenant uuid, p_product uuid, p_supplier uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true, p_exact_link boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  cand record; sup record; asset record; ident jsonb; mc text; id_state text; rights text; hero boolean;
  prov text; spid text;
BEGIN
  SELECT * INTO cand FROM public.commerce_products WHERE id=p_product;
  IF cand.id IS NULL THEN RETURN jsonb_build_object('available',false,'reason','CANDIDATE_NOT_FOUND'); END IF;
  IF p_supplier IS NOT NULL THEN SELECT * INTO sup FROM public.commerce_supplier_products WHERE id=p_supplier;
  ELSE SELECT * INTO sup FROM public.commerce_supplier_products
       WHERE source='cjdropshipping' AND category=cand.category AND image_url IS NOT NULL AND image_url<>''
       ORDER BY supplier_cost NULLS LAST LIMIT 1; END IF;
  IF sup.id IS NULL THEN RETURN jsonb_build_object('available',false,'reason','NO_SUPPLIER_MATCH','product_id',p_product); END IF;

  PERFORM public.fn_ingest_supplier_product_assets(sup.id, true);
  prov := upper(coalesce(sup.source,'UNKNOWN'));
  spid := coalesce(sup.source_product_id, sup.raw->>'pid', sup.id::text);
  SELECT * INTO asset FROM public.supplier_product_assets
    WHERE supplier=prov AND supplier_product_id=spid AND asset_type='PRIMARY_IMAGE' AND availability='AVAILABLE'
    ORDER BY is_primary DESC, created_at DESC LIMIT 1;
  IF asset.id IS NULL THEN
    RETURN jsonb_build_object('available',false,'reason','NO_SUPPLIER_IMAGE_IN_CANONICAL_ASSETS','product_id',p_product,'supplier',prov,'supplier_product_id',spid);
  END IF;

  IF p_exact_link THEN mc := 'EXACT_PRODUCT';
  ELSE ident := public.fn_resolve_supplier_identity(cand.title, cand.category, cand.product_identity, sup.title, sup.category, sup.source_product_id, false);
       mc := ident->>'match_class'; END IF;
  id_state := CASE mc WHEN 'EXACT_PRODUCT' THEN 'EXACT_PRODUCT' WHEN 'CLOSE_COMPARABLE' THEN 'CLOSE_COMPARABLE'
                      WHEN 'CATEGORY_MATCH' THEN 'REFERENCE_ONLY' ELSE 'REFERENCE_ONLY' END;
  rights := asset.rights_state;
  hero := (id_state='EXACT_PRODUCT' AND rights IN ('SUPPLIER_PROVIDED','OWNED'));

  IF p_persist THEN
    INSERT INTO public.product_asset_intelligence (tenant_id, product_id, supplier_product_id, source, source_url,
        source_ref, asset_type, rights_state, identity_state, match_class, match_confidence, hero_eligible, is_primary, observed_at, provenance)
    VALUES (p_tenant, p_product, spid, prov, asset.source_url, spid, 'SOURCE_PRODUCT_IMAGE', rights, id_state, mc,
        CASE WHEN p_exact_link THEN 'HIGH' ELSE coalesce(ident->>'match_confidence','NONE') END, hero, true, asset.observed_at,
        jsonb_build_object('canonical_asset_id', asset.id, 'exact_identifier_link', p_exact_link, 'asset_identity','SUPPLIER_OWN',
          'note','image sourced from canonical supplier_product_assets; comparable image is not the exact candidate'))
    ON CONFLICT (tenant_id, product_id, source, source_ref) DO UPDATE SET source_url=excluded.source_url,
        identity_state=excluded.identity_state, rights_state=excluded.rights_state, match_class=excluded.match_class,
        match_confidence=excluded.match_confidence, hero_eligible=excluded.hero_eligible, provenance=excluded.provenance, is_primary=true;
  END IF;

  RETURN jsonb_build_object('available',true,'product_id',p_product,'source',prov,
    'image_url',asset.source_url,'supplier_product_id',spid,'asset_type','SOURCE_PRODUCT_IMAGE','asset_identity','SUPPLIER_OWN',
    'identity_state',id_state,'match_class',mc,'exact_identifier_link',p_exact_link,'rights_state',rights,'hero_eligible',hero,
    'canonical_asset_id',asset.id,
    'presentation_note', CASE WHEN hero THEN 'exact-product supplier image (hero)'
        ELSE 'comparable supplier image ('||id_state||') — NOT the exact candidate; label as reference' END,
    'contract','pulse_product_asset_v2');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_tenant uuid, p_product uuid, p_supplier uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  cand record; sup record; asset record; ident jsonb; mc text; id_state text; rights text; hero boolean;
  prov text; spid text; supplier_native boolean;
BEGIN
  SELECT * INTO cand FROM public.commerce_products WHERE id=p_product;
  IF cand.id IS NULL THEN RETURN jsonb_build_object('available',false,'reason','CANDIDATE_NOT_FOUND'); END IF;
  IF p_supplier IS NOT NULL THEN SELECT * INTO sup FROM public.commerce_supplier_products WHERE id=p_supplier;
  ELSE SELECT * INTO sup FROM public.commerce_supplier_products
       WHERE source='cjdropshipping' AND category=cand.category AND image_url IS NOT NULL AND image_url<>''
       ORDER BY supplier_cost NULLS LAST LIMIT 1; END IF;
  IF sup.id IS NULL THEN RETURN jsonb_build_object('available',false,'reason','NO_SUPPLIER_MATCH','product_id',p_product); END IF;

  -- ensure canonical assets exist for this supplier product (universal contract, provider-independent)
  PERFORM public.fn_ingest_supplier_product_assets(sup.id, true);
  prov := upper(coalesce(sup.source,'UNKNOWN'));
  spid := coalesce(sup.source_product_id, sup.raw->>'pid', sup.id::text);
  SELECT * INTO asset FROM public.supplier_product_assets
    WHERE supplier=prov AND supplier_product_id=spid AND asset_type='PRIMARY_IMAGE' AND availability='AVAILABLE'
    ORDER BY is_primary DESC, created_at DESC LIMIT 1;
  IF asset.id IS NULL THEN
    RETURN jsonb_build_object('available',false,'reason','NO_SUPPLIER_IMAGE_IN_CANONICAL_ASSETS','product_id',p_product,
      'supplier',prov,'supplier_product_id',spid);
  END IF;

  -- candidate-representation identity: supplier-native product is EXACT; else fuzzy resolver
  supplier_native := (lower(coalesce(cand.source_store,''))=lower(coalesce(sup.source,'')));
  IF supplier_native THEN mc := 'EXACT_PRODUCT';
  ELSE ident := public.fn_resolve_supplier_identity(cand.title, cand.category, cand.product_identity, sup.title, sup.category, sup.source_product_id, false);
       mc := ident->>'match_class'; END IF;
  id_state := CASE mc WHEN 'EXACT_PRODUCT' THEN 'EXACT_PRODUCT' WHEN 'CLOSE_COMPARABLE' THEN 'CLOSE_COMPARABLE'
                      WHEN 'CATEGORY_MATCH' THEN 'REFERENCE_ONLY' ELSE 'REFERENCE_ONLY' END;
  rights := asset.rights_state;
  hero := (id_state='EXACT_PRODUCT' AND rights IN ('SUPPLIER_PROVIDED','OWNED'));

  IF p_persist THEN
    INSERT INTO public.product_asset_intelligence (tenant_id, product_id, supplier_product_id, source, source_url,
        source_ref, asset_type, rights_state, identity_state, match_class, match_confidence, hero_eligible, is_primary, observed_at, provenance)
    VALUES (p_tenant, p_product, spid, prov, asset.source_url, spid, 'SOURCE_PRODUCT_IMAGE', rights, id_state, mc,
        CASE WHEN supplier_native THEN 'HIGH' ELSE coalesce(ident->>'match_confidence','NONE') END, hero, true, asset.observed_at,
        jsonb_build_object('canonical_asset_id', asset.id, 'supplier_native', supplier_native, 'asset_identity','SUPPLIER_OWN',
          'note','image sourced from canonical supplier_product_assets; comparable image is not the exact candidate'))
    ON CONFLICT (tenant_id, product_id, source, source_ref) DO UPDATE SET source_url=excluded.source_url,
        identity_state=excluded.identity_state, rights_state=excluded.rights_state, match_class=excluded.match_class,
        hero_eligible=excluded.hero_eligible, provenance=excluded.provenance, is_primary=true;
  END IF;

  RETURN jsonb_build_object('available',true,'product_id',p_product,'source',prov,
    'image_url',asset.source_url,'supplier_product_id',spid,'asset_type','SOURCE_PRODUCT_IMAGE','asset_identity','SUPPLIER_OWN',
    'identity_state',id_state,'match_class',mc,'supplier_native',supplier_native,'rights_state',rights,'hero_eligible',hero,
    'canonical_asset_id',asset.id,
    'presentation_note', CASE WHEN hero THEN 'exact-product supplier image (hero)'
        ELSE 'comparable supplier image ('||id_state||') — NOT the exact candidate; label as reference' END,
    'contract','pulse_product_asset_v2');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_resolve_storefront_assets(p_supplier text, p_supplier_product_id text, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_fulfil text := lower(coalesce(p_supplier,''));
  v_usable jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_primary jsonb := NULL;
  v_video jsonb := NULL;
  r record; v_reason text;
BEGIN
  IF v_fulfil IN ('cj','cjdropshipping','cj_dropshipping') THEN v_fulfil := 'cjdropshipping'; END IF;
  FOR r IN
    SELECT * FROM public.supplier_product_assets
    WHERE p_supplier_product_id IS NOT NULL
      AND supplier_product_id = p_supplier_product_id
    ORDER BY is_primary DESC NULLS LAST, observed_at DESC NULLS LAST
  LOOP
    v_reason := NULL;
    IF coalesce(r.availability,'') <> 'AVAILABLE' THEN v_reason := 'UNAVAILABLE';
    ELSIF coalesce(r.rights_state,'UNKNOWN') NOT IN ('SUPPLIER_PROVIDED','LICENSED','OWNED') THEN v_reason := 'RIGHTS_NOT_ESTABLISHED';
    ELSIF coalesce(r.provenance->>'reference_only','false') = 'true' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.provenance->>'purpose','') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_identity,'') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_type,'') ILIKE '%reference%' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.asset_class,'') NOT IN ('SOURCE_PRODUCT_ASSET','GENERATED_CREATIVE','LICENSED_ASSET') THEN v_reason := 'DISALLOWED_ASSET_CLASS';
    ELSIF lower(coalesce(r.original_source,'')) IN ('fruugo','ebay','amazon','aliexpress-reference','reference') THEN v_reason := 'REFERENCE_ONLY_MARKETPLACE';
    ELSIF v_fulfil <> '' AND lower(coalesce(r.original_source,'')) <> v_fulfil AND lower(coalesce(r.supplier,'')) <> v_fulfil THEN v_reason := 'NOT_FULFILMENT_SUPPLIER_SOURCE';
    END IF;
    IF v_reason IS NULL THEN
      IF coalesce(r.asset_type,'') ILIKE '%video%' THEN
        IF v_video IS NULL THEN
          v_video := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
            'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
            'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
            'rights_state', r.rights_state, 'original_source', r.original_source);
        END IF;
      ELSE
        v_usable := v_usable || jsonb_build_object(
          'asset_id', r.id, 'asset_type', r.asset_type,
          'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
          'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
          'rights_state', r.rights_state, 'is_primary', coalesce(r.is_primary,false),
          'source_url', r.source_url, 'storage_ref', r.storage_ref, 'original_source', r.original_source);
        IF v_primary IS NULL AND coalesce(r.asset_type,'IMAGE') ILIKE '%image%' THEN
          v_primary := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
                         'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END);
        END IF;
      END IF;
    ELSE
      v_rejected := v_rejected || jsonb_build_object('asset_id', r.id, 'reason', v_reason,
        'original_source', r.original_source, 'rights_state', r.rights_state, 'availability', r.availability, 'asset_type', r.asset_type);
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'state', CASE WHEN v_primary IS NOT NULL THEN 'ASSETS_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END,
    'primary_image', v_primary,
    'gallery', v_usable,
    'usable_count', jsonb_array_length(v_usable),
    'video', v_video,
    'video_state', CASE WHEN v_video IS NOT NULL THEN 'VIDEO_AVAILABLE' ELSE 'VIDEO_ASSET_NOT_AVAILABLE' END,
    'rejected', v_rejected,
    'rejected_count', jsonb_array_length(v_rejected),
    'fulfilment_supplier', v_fulfil,
    'supplier_product_id', p_supplier_product_id,
    'no_fabricated_replacement', true,
    'source_vs_generated_distinction', 'origin_kind on each asset (SOURCE_SUPPLIER vs GENERATED)');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_resolve_supplier_identity(p_cand_title text, p_cand_category text, p_cand_ident text, p_sup_title text, p_sup_category text, p_sup_ref text, p_shared_identifier boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  ct text[]; st text[]; inter int; ngshared int; base int; overlap numeric;
  cls text; conf text; cn text; sn text;
  -- Generic tokens: container/storage/holder words, bundling words, generic
  -- placement/location words, form/size descriptors, and materials. These commonly
  -- appear in keyword-stuffed supplier titles and category strings and DO NOT
  -- identify a specific product. A shared token drawn only from this set is
  -- category co-occurrence, never product identity.
  generic_arr text[] := ARRAY[
    'holder','stand','organizer','organiser','case','box','tray','rack','storage',
    'mount','bracket','dish','bowl','cover','bag','pouch','basket','bin','caddy',
    'shelf','hook','hanger','clip','strap',
    'set','kit','pack','piece','pieces','pcs','bundle','lot','pair',
    'desk','table','wall','door','floor','car','seat','back','front','side','top',
    'home','office','kitchen','bathroom','bedroom','living','outdoor','indoor','travel','portable',
    'adjustable','foldable','folding','collapsible','mini','small','large','big',
    'multi','multifunction','multifunctional','universal','premium','luxury','deluxe',
    'new','hot','cute','fashion','fashionable','creative','simple','modern','nordic',
    'aluminium','aluminum','steel','stainless','metal','plastic','wooden','wood',
    'silicone','leather','glass','ceramic','fabric','cotton','rubber'
  ];
BEGIN
  IF p_cand_title IS NULL OR p_sup_title IS NULL THEN
    RETURN jsonb_build_object('match_class','UNKNOWN','match_confidence','NONE',
      'matching_evidence',jsonb_build_object('reason','missing_title'));
  END IF;
  cn := lower(p_cand_title||' '||coalesce(p_cand_category,''));
  sn := lower(p_sup_title||' '||coalesce(p_sup_category,''));
  cn := regexp_replace(cn, 'night[ -]?light', 'nightlight', 'g'); sn := regexp_replace(sn, 'night[ -]?light', 'nightlight', 'g');
  cn := regexp_replace(cn, 'projection', 'projector', 'g');       sn := regexp_replace(sn, 'projection', 'projector', 'g');
  cn := regexp_replace(cn, 'children|child|toddler|baby', 'kids', 'g'); sn := regexp_replace(sn, 'children|child|toddler|baby', 'kids', 'g');
  ct := public.fn_text_tokens(cn); st := public.fn_text_tokens(sn);
  SELECT count(*) INTO inter    FROM (SELECT unnest(ct) INTERSECT SELECT unnest(st)) x;
  SELECT count(*) INTO ngshared FROM (SELECT unnest(ct) INTERSECT SELECT unnest(st)) y(tok)
    WHERE y.tok <> ALL (generic_arr);
  base := greatest(cardinality(ct),1);
  overlap := round(inter::numeric/base, 3);
  IF p_shared_identifier THEN
    cls := 'EXACT_PRODUCT'; conf := 'HIGH';
  ELSIF overlap >= 0.5 AND inter >= 2 AND ngshared >= 1 THEN
    cls := 'CLOSE_COMPARABLE'; conf := CASE WHEN overlap>=0.7 THEN 'MEDIUM' ELSE 'LOW' END;
  ELSIF inter >= 2 AND p_cand_category IS NOT NULL AND lower(p_cand_category)=lower(p_sup_category) THEN
    cls := 'CATEGORY_MATCH'; conf := 'LOW';
  ELSE
    cls := 'UNRELATED'; conf := 'NONE';
  END IF;
  RETURN jsonb_build_object('match_class', cls, 'match_confidence', conf,
    'matching_evidence', jsonb_build_object(
      'token_overlap', overlap, 'shared_tokens', inter, 'nongeneric_shared_tokens', ngshared,
      'shared_identifier', p_shared_identifier,
      'candidate_ref', p_cand_ident, 'supplier_product_ref', p_sup_ref,
      'note','EXACT requires a shared product identifier; CLOSE requires overlap>=0.5 AND >=2 shared tokens AND >=1 shared NON-GENERIC (product-discriminating) token; generic category/material/placement co-occurrence is not product identity'));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_revoke_spend_authority(p_actor uuid, p_authority_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.marketing_spend_authority; v_released numeric := 0;
BEGIN
  IF p_actor IS NULL THEN RETURN jsonb_build_object('status','unauthorized_no_actor'); END IF;
  SELECT * INTO a FROM public.marketing_spend_authority WHERE id=p_authority_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  UPDATE public.spend_reservations SET status='RELEASED', released_at=now()
    WHERE authority_id=p_authority_id AND status='RESERVED';
  GET DIAGNOSTICS v_released = ROW_COUNT;
  UPDATE public.marketing_spend_authority SET status='REVOKED', revoked_at=now(), reserved=0 WHERE id=p_authority_id;
  UPDATE public.activation_authorizations SET status='INVALIDATED' WHERE authority_id=p_authority_id AND status='ISSUED';
  PERFORM public.fn_authority_audit(a.tenant_id,'AUTHORITY_REVOKED',p_actor,p_authority_id,NULL,to_jsonb(a),NULL,p_reason,NULL);
  RETURN jsonb_build_object('status','REVOKED','authority_id',p_authority_id,'reservations_released',v_released);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_route_evidence(p_category text, p_market text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  WITH prov AS (SELECT DISTINCT source FROM public.provider_capability_registry WHERE evidence_category=p_category)
  SELECT jsonb_build_object('evidence_category',p_category,'market',upper(btrim(coalesce(p_market,''))),
    'providers', coalesce(jsonb_agg(public.fn_source_availability(prov.source,p_category,p_market) ORDER BY prov.source),'[]'::jsonb))
  FROM prov;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_run_monday_product_opportunity(p_trigger text DEFAULT 'manual'::text, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  reg record; m jsonb; run_id uuid := gen_random_uuid();
  ncand int := 0; ncombo int := 0; ndeliv int := 0; navoid int := 0;
  src_states jsonb := '{}'::jsonb; deliver jsonb := '[]'::jsonb; blk jsonb; best_dec text;
BEGIN
  FOR reg IN SELECT * FROM public.monday_opportunity_registry WHERE active LOOP
    ncand := ncand + 1;
    FOR m IN SELECT * FROM jsonb_array_elements(reg.markets) LOOP
      BEGIN   -- per-market failure isolation: one bad source never corrupts the rest
        PERFORM public.fn_assemble_real_product_market(reg.product_id, m->>'country', m->>'currency',
                  m->>'price_query', reg.supplier_id, p_persist);
        ncombo := ncombo + 1;
        src_states := src_states || jsonb_build_object((reg.product_id::text)||':'||(m->>'country'), 'AVAILABLE');
      EXCEPTION WHEN OTHERS THEN
        src_states := src_states || jsonb_build_object((reg.product_id::text)||':'||(m->>'country'),
          jsonb_build_object('state','FAILED','error',SQLERRM));
      END;
    END LOOP;
    PERFORM public.fn_pod_tournament(reg.tenant_id, reg.product_id, 'pod_v1', p_persist);
    blk := public.fn_pod_monday_block(reg.tenant_id, reg.product_id);
    best_dec := blk->>'DECISION';
    IF best_dec = 'AVOID' THEN navoid := navoid + 1;      -- retained in evidence/history, not promoted
    ELSE deliver := deliver || jsonb_build_array(blk); ndeliv := ndeliv + 1; END IF;   -- TEST + WATCH delivered
  END LOOP;

  IF p_persist THEN
    INSERT INTO public.monday_opportunity_runs (id, trigger_source, candidates, combinations, delivered, excluded_avoid, source_states, payload)
    VALUES (run_id, p_trigger, ncand, ncombo, ndeliv, navoid, src_states,
      jsonb_build_object('delivered', deliver));
  END IF;

  RETURN jsonb_build_object('run_id', run_id, 'trigger_source', p_trigger, 'ran_at', now(),
    'candidates', ncand, 'combinations', ncombo, 'delivered', ndeliv, 'excluded_avoid', navoid,
    'source_states', src_states, 'delivered_opportunities', deliver,
    'campaign_activation', false, 'advertising_spend', 0,
    'cadence','MONDAY_WEEKLY', 'note','WATCH delivered as emerging opportunity with blockers; AVOID retained in history, not promoted; WINNER never pre-performance.',
    'contract','pulse_monday_product_opportunity_run_v1');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_sanitize_ad_snapshot_url(p_url text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v text := coalesce(p_url,'');
BEGIN
  IF v = '' THEN RETURN v; END IF;
  -- remove access_token / any *token / *secret / client_secret query params (+ a trailing separator)
  v := regexp_replace(v, '([?&])(access_token|client_secret|[a-z_]*token|[a-z_]*secret)=[^&#]*&?', '\1', 'gi');
  v := regexp_replace(v, '[?&]$', '');   -- dangling separator
  v := regexp_replace(v, '\?&', '?');    -- ?& -> ?
  v := regexp_replace(v, '&&+', '&', 'g');
  RETURN v;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_search_momentum(p_monthly jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_vals numeric[]; v_n int; v_recent numeric; v_prior numeric; v_pct numeric; v_dir text;
BEGIN
  IF jsonb_typeof(p_monthly) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('direction','unknown','inferred',true,'reason','no_history');
  END IF;
  SELECT array_agg(v ORDER BY ord) INTO v_vals FROM (
    SELECT (e->>'volume')::numeric v, coalesce((e->>'year')::int,0)*12+coalesce((e->>'month')::int,0) ord
    FROM jsonb_array_elements(p_monthly) e WHERE (e->>'volume') ~ '^[0-9]+(\.[0-9]+)?$') s;
  v_n := coalesce(array_length(v_vals,1),0);
  IF v_n < 6 THEN RETURN jsonb_build_object('direction','unknown','inferred',true,'reason','insufficient_history','months',v_n); END IF;
  v_recent := (v_vals[v_n] + v_vals[v_n-1] + v_vals[v_n-2]) / 3.0;
  v_prior  := (v_vals[v_n-3] + v_vals[v_n-4] + v_vals[v_n-5]) / 3.0;
  v_pct := CASE WHEN v_prior > 0 THEN (v_recent - v_prior)/v_prior ELSE NULL END;
  v_dir := CASE WHEN v_pct IS NULL THEN 'unknown'
                WHEN v_pct > 0.15 THEN 'rising'
                WHEN v_pct < -0.15 THEN 'declining' ELSE 'flat' END;
  RETURN jsonb_build_object('direction',v_dir,'inferred',true,'basis','recent3_vs_prior3',
    'pct_change', CASE WHEN v_pct IS NULL THEN NULL ELSE round(v_pct,3) END,
    'recent3_avg',round(v_recent,1),'prior3_avg',round(v_prior,1));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_select_conversion_template(p_input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_cat text := lower(coalesce(p_input->>'category',''));
  v_traffic text := lower(coalesce(p_input->>'traffic_source',''));
  v_ev text[] := '{}';
  v_fam record;
  v_cands jsonb := '[]'::jsonb;
  v_disq boolean; v_missing text[]; v_score int; v_reasons text[];
  v_best jsonb := NULL; v_alt jsonb := NULL;
  v_sections jsonb; v_hero text; v_hero_ev text[]; v_note text := NULL;
BEGIN
  IF coalesce((p_input->>'buyer_pain')::boolean,false)        THEN v_ev := array_append(v_ev,'BUYER_PAIN'); END IF;
  IF coalesce((p_input->>'has_product_image')::boolean,false) THEN v_ev := array_append(v_ev,'PRODUCT_IMAGE'); END IF;
  IF coalesce((p_input->>'has_demo_asset')::boolean,false)    THEN v_ev := array_append(v_ev,'DEMO_ASSET'); END IF;
  IF coalesce((p_input->>'has_video_asset')::boolean,false)   THEN v_ev := array_append(v_ev,'VIDEO_ASSET'); END IF;
  IF coalesce((p_input->>'has_specs')::boolean,false)         THEN v_ev := array_append(v_ev,'PRODUCT_SPECS'); END IF;
  IF coalesce((p_input->>'has_reviews_ugc')::boolean,false)   THEN v_ev := array_append(v_ev,'REVIEWS_OR_UGC'); END IF;
  IF coalesce((p_input->>'has_comparison_basis')::boolean,false) THEN v_ev := array_append(v_ev,'COMPARISON_BASIS'); END IF;
  IF coalesce((p_input->>'has_before_after')::boolean,false)  THEN v_ev := array_append(v_ev,'BEFORE_AFTER_EVIDENCE'); END IF;
  IF coalesce((p_input->>'genuine_offer')::boolean,false)     THEN v_ev := array_append(v_ev,'GENUINE_OFFER'); END IF;
  IF coalesce((p_input->>'has_returns_policy')::boolean,false) THEN v_ev := array_append(v_ev,'RETURNS_POLICY'); END IF;

  FOR v_fam IN SELECT * FROM public.conversion_template_families WHERE is_active ORDER BY selection_priority LOOP
    v_disq := false; v_missing := '{}'; v_reasons := '{}';
    IF 'no_articulable_problem' = ANY(v_fam.disqualifiers) AND NOT ('BUYER_PAIN' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_articulable_problem'); END IF;
    IF 'no_usable_demo_asset' = ANY(v_fam.disqualifiers) AND NOT ('DEMO_ASSET' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_usable_demo_asset'); END IF;
    IF 'low_cost_commodity_no_premium_substantiation' = ANY(v_fam.disqualifiers) AND NOT coalesce((p_input->>'premium_substantiation')::boolean,false) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_premium_substantiation'); END IF;
    IF 'no_legitimate_social_proof' = ANY(v_fam.disqualifiers) AND NOT ('REVIEWS_OR_UGC' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_social_proof'); END IF;
    IF 'unknown_specs' = ANY(v_fam.disqualifiers) AND NOT ('PRODUCT_SPECS' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:unknown_specs'); END IF;
    IF 'no_legitimate_comparison_basis' = ANY(v_fam.disqualifiers) AND NOT ('COMPARISON_BASIS' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_comparison_basis'); END IF;
    IF 'purely_functional_no_emotional_angle' = ANY(v_fam.disqualifiers) AND NOT coalesce((p_input->>'emotional_angle')::boolean,false) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_emotional_angle'); END IF;
    IF 'no_legitimate_offer' = ANY(v_fam.disqualifiers) AND NOT ('GENUINE_OFFER' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_offer'); END IF;

    SELECT array_agg(e) INTO v_missing FROM unnest(v_fam.evidence_requirements) e WHERE NOT (e = ANY(v_ev));
    IF v_missing IS NOT NULL AND array_length(v_missing,1) > 0 THEN
      v_reasons := array_append(v_reasons, 'missing_evidence:'||array_to_string(v_missing,','));
    END IF;

    IF v_disq OR (v_missing IS NOT NULL AND array_length(v_missing,1) > 0) THEN
      CONTINUE;
    END IF;

    v_score := 0;
    IF v_cat <> '' AND v_cat = ANY(v_fam.categories) THEN v_score := v_score + 3; v_reasons := array_append(v_reasons,'category_match'); END IF;
    IF v_traffic <> '' AND v_traffic = ANY(v_fam.traffic_fit) THEN v_score := v_score + 2; v_reasons := array_append(v_reasons,'traffic_match'); END IF;
    v_score := v_score + (SELECT count(*)::int FROM unnest(v_fam.optional_sections) s
                          JOIN public.conversion_section_types t ON t.section_type=s
                          WHERE t.required_evidence <@ v_ev AND array_length(t.required_evidence,1) > 0);
    v_cands := v_cands || jsonb_build_object('family',v_fam.family,'score',v_score,
                 'priority',v_fam.selection_priority,'reasons',to_jsonb(v_reasons),'hero',v_fam.hero_variant);
  END LOOP;

  SELECT jsonb_agg(c ORDER BY (c->>'score')::int DESC, (c->>'priority')::int ASC)
    INTO v_cands FROM jsonb_array_elements(v_cands) c;
  IF v_cands IS NOT NULL AND jsonb_array_length(v_cands) >= 1 THEN v_best := v_cands->0; END IF;
  IF v_cands IS NOT NULL AND jsonb_array_length(v_cands) >= 2 THEN v_alt := v_cands->1; END IF;

  IF v_best IS NULL THEN
    v_best := jsonb_build_object('family','PROBLEM_SOLUTION','score',0,'priority',20,
                'reasons', jsonb_build_array('insufficient_evidence_fallback'),'hero','HERO_PROBLEM_FRAMING');
    v_note := 'INSUFFICIENT_EVIDENCE_FALLBACK';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'type', o.section_type, 'order', o.ord,
           'conversion_role', st.default_conversion_role,
           'required_evidence', to_jsonb(st.required_evidence),
           'render', (st.required_evidence <@ v_ev),
           'degrade', CASE WHEN st.required_evidence <@ v_ev THEN 'RENDER'
                           WHEN st.structural THEN 'RENDER_EDITABLE' ELSE 'HIDE_OR_PLACEHOLDER' END,
           'mobile', st.mobile_defaults) ORDER BY o.ord)
    INTO v_sections
  FROM public.conversion_template_families f
  CROSS JOIN LATERAL unnest(f.ordering_strategy) WITH ORDINALITY AS o(section_type, ord)
  JOIN public.conversion_section_types st ON st.section_type = o.section_type
  WHERE f.family = (v_best->>'family');

  SELECT hero_variant INTO v_hero FROM public.conversion_template_families WHERE family=(v_best->>'family');
  SELECT required_evidence INTO v_hero_ev FROM public.conversion_hero_variants WHERE variant=v_hero;
  IF NOT (coalesce(v_hero_ev,'{}') <@ v_ev) THEN
    v_hero := 'HERO_PROBLEM_FRAMING';
  END IF;

  RETURN jsonb_build_object(
    'label','BEST_FIT',
    'recommended_template_family', v_best->>'family',
    'alternative_template_family', v_alt->>'family',
    'template_version','v1',
    'confidence', CASE WHEN v_note IS NOT NULL THEN 'LOW'
                       WHEN (v_best->>'score')::int >= 4 THEN 'HIGH'
                       WHEN (v_best->>'score')::int >= 2 THEN 'MEDIUM' ELSE 'LOW' END,
    'selection_reasons', v_best->'reasons',
    'hero_variant', v_hero,
    'cta_structure', (SELECT cta_structure FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'sections', v_sections,
    'recommended_section_order', (SELECT to_jsonb(ordering_strategy) FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'excluded_sections', (SELECT to_jsonb(excluded_sections) FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'missing_evidence', (SELECT coalesce(jsonb_agg(x->>'type'),'[]'::jsonb) FROM jsonb_array_elements(v_sections) x WHERE (x->>'render')::boolean = false),
    'available_evidence', to_jsonb(v_ev),
    'all_candidates', coalesce(v_cands,'[]'::jsonb),
    'note', v_note,
    'terminology_guard','PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_set_ecommerce_destination(p_user_id uuid, p_destination text, p_store_connection_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_d text := upper(btrim(coalesce(p_destination,'')));
BEGIN
  IF v_d NOT IN ('EXISTING_STORE','PULSE_STORE') THEN RETURN jsonb_build_object('status','invalid_destination'); END IF;
  INSERT INTO public.commerce_destination_choice(user_id,destination,store_connection_id,updated_at)
  VALUES (p_user_id, v_d, CASE WHEN v_d='EXISTING_STORE' THEN p_store_connection_id ELSE NULL END, now())
  ON CONFLICT (user_id) DO UPDATE SET destination=EXCLUDED.destination,
    store_connection_id=EXCLUDED.store_connection_id, updated_at=now();
  RETURN jsonb_build_object('status','ok','user_id',p_user_id,'destination',v_d,
    'store_connection_id', CASE WHEN v_d='EXISTING_STORE' THEN p_store_connection_id ELSE NULL END,
    'note','editable later; PULSE_STORE requires no URL');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_source_availability(p_source text, p_category text, p_market text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT to_jsonb(r) FROM (
    SELECT source, evidence_category, availability, coverage_type, limitations, last_verified_at
    FROM public.provider_capability_registry
    WHERE source=p_source AND evidence_category=p_category
      AND market IN (upper(btrim(coalesce(p_market,''))), '*')
    ORDER BY (market <> '*') DESC LIMIT 1) r;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_spend_authority_fingerprint(a marketing_spend_authority)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT md5(concat_ws('|', a.tenant_id::text, a.platform, coalesce(a.ad_account,''), a.execution_currency,
    a.mode, a.authorized_total::text, a.max_daily::text, a.max_campaign::text, a.max_product_test::text,
    coalesce(a.allowed_markets::text,''), coalesce(a.allowed_actions::text,''),
    coalesce(a.allowed_campaign_types::text,''), coalesce(a.start_at::text,''), coalesce(a.end_at::text,'')));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_stamp_commerce_visibility()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
  NEW.visibility := CASE WHEN NEW.user_id = public.fn_global_intelligence_uid()
                         THEN 'GLOBAL_SAFE' ELSE 'TENANT_PRIVATE' END;
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_store_builder_payload(p_decision jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v_rec text := p_decision->>'recommendation'; v_class text := p_decision->>'classification';
        v_payload jsonb; v_missing text[];
BEGIN
  IF v_rec <> 'TEST' THEN
    RETURN jsonb_build_object('handoff_allowed',false,'decision',v_class,'recommendation',v_rec,
      'reason','store-builder handoff requires a TEST-class decision; current='||coalesce(v_class,'UNKNOWN'),
      'target_market',p_decision->>'target_market');
  END IF;
  v_payload := jsonb_build_object(
    'product_id', p_context->>'product_id', 'market', p_decision->>'target_market',
    'decision', v_class, 'recommendation', v_rec,
    'opportunity_score', p_decision->>'opportunity_score', 'evidence_confidence', p_decision->>'evidence_confidence',
    'product_title', p_context->>'product_title', 'positioning', p_context->>'positioning',
    'supplier_reference', p_context->'supplier_reference',
    'selling_price', p_context->>'selling_price', 'display_currency', p_context->>'display_currency',
    'source_currency', p_decision->'economics'->>'landed_cost_currency',
    'landed_cost_original', p_decision->'economics'->>'landed_cost_original',
    'landed_cost_display', p_decision->'economics'->>'landed_cost_display',
    'margin', p_decision->'economics'->>'margin', 'margin_pct', p_decision->'economics'->>'margin_pct',
    'delivery_evidence', p_decision->'supplier_execution'->'delivery',
    'buyer_intent', p_context->'buyer_intent', 'competitive_price_anchor', p_context->'competitive_price_anchor',
    'advertising_pattern_state', p_decision->'advertising_validation'->>'state',
    'trust_authenticity', jsonb_build_object('gate', p_decision->'product_trust'->>'gate',
        'classification', p_decision->'product_trust'->'classification'->>'classification'),
    'supply_confidence', p_decision->>'supply_confidence',
    'product_assets', p_context->'product_assets', 'audience_evidence', p_context->'audience_evidence',
    'provenance', p_context->'provenance');
  SELECT array_agg(f) INTO v_missing FROM (VALUES ('product_assets'),('audience_evidence')) t(f)
    WHERE coalesce(v_payload->f,'null'::jsonb) = 'null'::jsonb;
  RETURN jsonb_build_object('handoff_allowed',true,'decision',v_class,
    'store_builder_payload', v_payload, 'missing_optional_fields', coalesce(to_jsonb(v_missing),'[]'::jsonb),
    'note','fields left null are genuinely uncollected, not fabricated');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_ad_addressable(p_page_id uuid, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_pg public.commerce_product_pages%rowtype; v_actor uuid := coalesce(auth.uid(), p_actor);
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  RETURN jsonb_build_object('status','ok','addressable',true,
    'product_id', v_pg.product_id,
    'country_code', coalesce(v_pg.country_code, v_pg.market),
    'market', v_pg.market,
    'storefront_page_id', v_pg.id,
    'page_version', extract(epoch FROM v_pg.updated_at)::bigint,
    'template_family', v_pg.template_family,
    'offer_version', coalesce(v_pg.ad_match_ref->>'offer_version','v1'),
    'ad_match_ref', v_pg.ad_match_ref,
    'destination', v_pg.destination,
    'destination_url', CASE WHEN coalesce(v_pg.publication_state,'')='PUBLISHED' THEN v_pg.published_url ELSE NULL END,
    'publication_state', v_pg.publication_state,
    'campaign_created', false, 'meta_activated', false, 'ad_spend_authorized', 0,
    'note','addressable reference only; no campaign created, no Meta activation, no spend');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_change_country(p_page_id uuid, p_new_country text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_pg public.commerce_product_pages%rowtype; v_actor uuid := coalesce(auth.uid(), p_actor);
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  IF upper(coalesce(p_new_country,'')) = upper(coalesce(v_pg.country_code, v_pg.market,'')) THEN
    RETURN jsonb_build_object('status','NO_CHANGE','country',p_new_country);
  END IF;
  RETURN jsonb_build_object(
    'status','COUNTRY_CONTEXT_RESOLUTION_REQUIRED',
    'current_country', coalesce(v_pg.country_code, v_pg.market),
    'new_country', upper(p_new_country),
    'requires', jsonb_build_array('new Product×Country evaluation','fresh TEST eligibility gate','new landed economics','new supplier/stock/fulfilment evidence'),
    'currency_only_conversion_permitted', false,
    'next_action','call fn_generate_storefront_runtime with the new Product×Country inputs (product_id, '||upper(p_new_country)||')',
    'note','Changing country resolves a new Product×Country context; currency conversion alone is not permitted.');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_publish(p_page_id uuid, p_gate_inputs jsonb, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_gate jsonb; v_assets jsonb; v_clean boolean; v_slug text; v_url text;
  v_base text := 'https://nxaunmyihhjixxxljcqt.supabase.co';
BEGIN
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND p.user_id IS NOT NULL AND v_actor <> p.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT'); END IF;
  IF upper(coalesce(p.review_state,'')) <> 'APPROVED' THEN
    RETURN jsonb_build_object('status','NOT_APPROVED','review_state',p.review_state,
      'note','publish requires the page to be APPROVED first (DRAFT -> IN_REVIEW -> APPROVED)'); END IF;
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  IF NOT (v_gate->>'test_eligible')::boolean THEN
    RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_gate->'reason_codes','gate',v_gate); END IF;
  v_clean := coalesce((p.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, false);
  IF NOT v_clean THEN
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','note','claim scan not clean; resolve before publish'); END IF;
  v_assets := public.fn_resolve_storefront_assets(
      coalesce(p.runtime_contract->'supplier_asset_refs'->>'fulfilment_supplier','cjdropshipping'),
      p.runtime_contract->'supplier_asset_refs'->>'supplier_product_id', p.country_code);
  IF (v_assets->>'rejected_count')::int > 0 AND (v_assets->>'usable_count')::int = 0 THEN
    RETURN jsonb_build_object('status','BLOCKED_ASSET_SAFETY','assets',v_assets,
      'note','no usable rights-clear supplier assets; only rejected/reference-only present'); END IF;
  IF upper(coalesce(p.destination,'')) NOT IN ('PULSE_STORE') THEN
    RETURN jsonb_build_object('status','BLOCKED_DESTINATION','destination',p.destination,
      'note','this runtime publishes PULSE_STORE (Pulse-hosted) only'); END IF;
  v_slug := 'p'||left(replace(p_page_id::text,'-',''),12);
  v_url := v_base||'/functions/v1/storefront/'||v_slug;
  UPDATE public.commerce_product_pages SET
    review_state = 'PUBLISHED', publication_state = 'PUBLISHED', published_url = v_url,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object(
      'review_state','PUBLISHED','publication_state','PUBLISHED',
      'publication', jsonb_build_object(
        'destination','PULSE_HOSTED','slug',v_slug,'destination_url',v_url,'noindex',true,
        'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
        'renderer','fn_public_storefront_render','published_at', now(),
        'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
           'assets_state',v_assets->>'state','destination','PULSE_STORE'),
        'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED','dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER'))),
    supplier_asset_refs = v_assets, updated_at = now()
  WHERE id = p_page_id;
  UPDATE public.commerce_store_projects SET
    project_state = 'PUBLISHED', public_route = v_slug,
    settings = coalesce(settings,'{}'::jsonb) || jsonb_build_object(
      'publication_state','PUBLISHED','destination_url',v_url,'noindex',true,
      'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT'),
    updated_at = now()
  WHERE product_page_id = p_page_id;
  RETURN jsonb_build_object('status','ok','publication_state','PUBLISHED',
    'page_id',p_page_id,'slug',v_slug,'destination_url',v_url,
    'checkout_state','CHECKOUT_NOT_CONFIGURED','checkout_dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
    'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT','renderer','fn_public_storefront_render',
    'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
       'assets_state',v_assets->>'state','destination','PULSE_STORE'),
    'note','internal publication runtime complete; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_publish_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; r jsonb; render jsonb;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  pid uuid; slug text;
  ok_gate jsonb := '{"recommendation":"TEST","decision_tier":"STRONG_TEST","supplier_identity_state":"SUPPLIER_EXACT","market_supplier_match":"EXACT_CONFIRMED","subtype_price_valid":true,"stock_state":"IN_STOCK","economics_state":"VIABLE","product_confidence":"ACCEPTABLE","fulfilment_evidence":true,"no_critical_risk":true}'::jsonb;
BEGIN
  INSERT INTO public.commerce_product_pages(user_id,market,country_code,destination,decision_classification,
     page_model,status,source_kind,review_state,publication_state,selling_price,display_currency,source_currency,runtime_contract)
   VALUES (u1,'US','US','PULSE_STORE','QUALIFIED_TEST_NOT_HIGH_CONFIDENCE',
     '{"product_title":"Selftest Cam","hero":{"headline":"Selftest Cam"},"benefits":["a"],"trust":{"copy":"New."},"shipping":{"copy":"Estimate"},"seo":{"title":"Selftest"}}'::jsonb,
     'READY_FOR_REVIEW','REAL','DRAFT','UNPUBLISHED',91.79,'USD','USD',
     jsonb_build_object('hero_variant','HERO_FEATURE_SPOTLIGHT','cta_structure','{}'::jsonb,'sections','[]'::jsonb,
       'claim_safety', jsonb_build_object('claim_scan_clean', true),
       'supplier_asset_refs', jsonb_build_object('state','ASSETS_AVAILABLE','usable_count',1,'rejected_count',0,
          'fulfilment_supplier','cjdropshipping','supplier_product_id','SELFTEST_PUB',
          'primary_image', jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg'),
          'gallery', jsonb_build_array(jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg')))))
   RETURNING id INTO pid;
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,source_kind)
   VALUES (u1,pid,'DRAFT','selftestpub-'||left(replace(pid::text,'-',''),8),'REAL');
  r := public.fn_storefront_publish(pid, ok_gate, u1);
  v := v || jsonb_build_object('case','publish_requires_approved','pass', r->>'status'='NOT_APPROVED','got',r->>'status');
  render := public.fn_public_storefront_render((SELECT csp.slug FROM public.commerce_store_projects csp WHERE csp.product_page_id=pid));
  v := v || jsonb_build_object('case','renderer_notfound_for_draft','pass', render->>'status'='NOT_FOUND','got',render->>'status');
  PERFORM public.fn_storefront_transition_state(pid,'IN_REVIEW',u1);
  PERFORM public.fn_storefront_transition_state(pid,'APPROVED',u1);
  r := public.fn_storefront_publish(pid, ok_gate, u2);
  v := v || jsonb_build_object('case','publish_cross_tenant_denied','pass', r->>'status'='DENIED_CROSS_TENANT','got',r->>'status');
  r := public.fn_storefront_publish(pid, ok_gate || '{"recommendation":"WATCH"}'::jsonb, u1);
  v := v || jsonb_build_object('case','publish_failclosed_bad_gate','pass', r->>'status'='BLOCKED_TEST_ELIGIBILITY','got',r->>'status');
  r := public.fn_storefront_publish(pid, ok_gate, u1);
  slug := r->>'slug';
  v := v || jsonb_build_object('case','publish_ok','pass', r->>'status'='ok' AND r->>'publication_state'='PUBLISHED' AND r->>'destination_url' IS NOT NULL,'got',r->>'status');
  v := v || jsonb_build_object('case','publish_checkout_not_configured','pass', r->>'checkout_state'='CHECKOUT_NOT_CONFIGURED','got',r->>'checkout_state');
  render := public.fn_public_storefront_render(slug);
  v := v || jsonb_build_object('case','renderer_ok_for_published','pass', render->>'status'='OK' AND (render->'storefront'->'checkout'->>'state')='CHECKOUT_NOT_CONFIGURED','got',render->>'status');
  v := v || jsonb_build_object('case','renderer_no_secrets','pass',
        NOT (render::text ILIKE '%landed%' OR render::text ILIKE '%supplier_cost%' OR render::text ILIKE '%accessToken%'
             OR render::text ILIKE '%"wps"%' OR render::text ILIKE '%decision_classification%' OR render::text ILIKE '%user_id%'),
        'got','checked');
  render := public.fn_public_storefront_render('does-not-exist-'||left(replace(gen_random_uuid()::text,'-',''),8));
  v := v || jsonb_build_object('case','renderer_notfound_unknown','pass', render->>'status'='NOT_FOUND','got',render->>'status');
  DELETE FROM public.commerce_store_projects WHERE product_page_id=pid;
  DELETE FROM public.commerce_product_pages WHERE id=pid;
  RETURN jsonb_build_object('suite','pulse_hosted_publish',
    'total', jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_runtime_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  g jsonb; s jsonb; a jsonb; r jsonb;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  pid uuid; pid2 uuid;
  base_ok jsonb := '{"recommendation":"TEST","decision_tier":"STRONG_TEST","supplier_identity_state":"SUPPLIER_EXACT","market_supplier_match":"EXACT_CONFIRMED","subtype_price_valid":true,"stock_state":"IN_STOCK","economics_state":"VIABLE","product_confidence":"ACCEPTABLE","fulfilment_evidence":true,"no_critical_risk":true}'::jsonb;
BEGIN
  g := public.fn_storefront_test_eligibility(base_ok);
  v := v || jsonb_build_object('case','test_accepted','pass',(g->>'test_eligible')::boolean = true,'got',g->>'decision_state');
  v := v || jsonb_build_object('case','no_silent_high_confidence_upgrade','pass',(g->>'high_confidence')::boolean = false AND g->>'decision_tier'='STRONG_TEST','got',g->>'decision_tier');
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"WATCH"}'::jsonb);
  v := v || jsonb_build_object('case','watch_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_WATCH','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"AVOID"}'::jsonb);
  v := v || jsonb_build_object('case','avoid_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_AVOID','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"ANALYSIS_REQUIRED"}'::jsonb);
  v := v || jsonb_build_object('case','analysis_required_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ANALYSIS_REQUIRED','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"WATCH","sourcing_status":"PENDING_EXTERNAL_CJ_SOURCING"}'::jsonb);
  v := v || jsonb_build_object('case','pending_external_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_SOURCING_PENDING_EXTERNAL','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"stock_state":"OUT_OF_STOCK"}'::jsonb);
  v := v || jsonb_build_object('case','out_of_stock_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_OUT_OF_STOCK','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"stock_state":"UNKNOWN"}'::jsonb);
  v := v || jsonb_build_object('case','unknown_stock_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_STOCK_UNKNOWN','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"economics_state":"NEGATIVE"}'::jsonb);
  v := v || jsonb_build_object('case','economics_negative_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ECONOMICS_UNVIABLE','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"economics_state":"UNKNOWN"}'::jsonb);
  v := v || jsonb_build_object('case','economics_unknown_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ECONOMICS_UNKNOWN','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"market_supplier_match":"CLOSE_COMPARABLE","subtype_price_valid":false}'::jsonb);
  v := v || jsonb_build_object('case','cross_market_cannot_satisfy_local','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_IDENTITY_WEAK','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"supplier_identity_state":"SUPPLIER_AMBIGUOUS"}'::jsonb);
  v := v || jsonb_build_object('case','supplier_not_canonical_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_SUPPLIER_NOT_CANONICAL','got',g->'reason_codes');
  s := public.fn_select_conversion_template('{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','template_selection_feature_tech','pass',s->>'recommended_template_family'='FEATURE_TECHNOLOGY' AND s->>'label'='BEST_FIT','got',s->>'recommended_template_family');
  r := public.fn_select_conversion_template('{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','selection_deterministic','pass',(s->>'recommended_template_family')=(r->>'recommended_template_family'),'got',r->>'recommended_template_family');
  v := v || jsonb_build_object('case','template_versioning','pass',s->>'template_version' IS NOT NULL,'got',s->>'template_version');
  v := v || jsonb_build_object('case','comparison_section_hidden','pass', s->'missing_evidence' ? 'COMPARISON','got',s->'missing_evidence');
  v := v || jsonb_build_object('case','ugc_excluded_without_reviews','pass',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'all_candidates') c WHERE c->>'family'='UGC_SOCIAL_COMMERCE'),'got',s->'all_candidates');
  r := public.fn_select_conversion_template('{"category":"broad_consumer","traffic_source":"social","buyer_pain":true,"has_reviews_ugc":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','ugc_candidate_with_reviews','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(r->'all_candidates') c WHERE c->>'family'='UGC_SOCIAL_COMMERCE'),'got',r->'all_candidates');
  v := v || jsonb_build_object('case','claim_scan_flags_reviews','pass', jsonb_array_length(public.fn_ad_studio_claim_scan('Rated 5 stars by 2000 happy customers, best seller!')) > 0,'got',public.fn_ad_studio_claim_scan('Rated 5 stars by 2000 happy customers'));
  v := v || jsonb_build_object('case','claim_scan_clean_honest_copy','pass', jsonb_array_length(public.fn_ad_studio_claim_scan('A practical countertop device for everyday use. Ships from the supplier warehouse.')) = 0,'got',public.fn_ad_studio_claim_scan('A practical countertop device for everyday use.'));
  INSERT INTO public.supplier_product_assets(id,supplier,supplier_product_id,asset_type,asset_class,rights_state,availability,is_primary,original_source,provenance,is_fixture)
   VALUES (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',true,'cjdropshipping','{}'::jsonb,true),
          (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','UNKNOWN','AVAILABLE',false,'cjdropshipping','{}'::jsonb,true),
          (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',false,'cjdropshipping','{"purpose":"SOURCING_REFERENCE"}'::jsonb,true),
          (gen_random_uuid(),'fruugo','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',false,'fruugo','{}'::jsonb,true);
  a := public.fn_resolve_storefront_assets('cjdropshipping','SELFTEST_PID','US');
  v := v || jsonb_build_object('case','assets_available_supplier_provided','pass',a->>'state'='ASSETS_AVAILABLE' AND (a->>'usable_count')::int=1,'got',a->>'usable_count');
  v := v || jsonb_build_object('case','asset_rights_unknown_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='RIGHTS_NOT_ESTABLISHED'),'got',a->'rejected');
  v := v || jsonb_build_object('case','asset_sourcing_reference_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='SOURCING_REFERENCE'),'got',a->'rejected');
  v := v || jsonb_build_object('case','asset_reference_marketplace_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='REFERENCE_ONLY_MARKETPLACE'),'got',a->'rejected');
  a := public.fn_resolve_storefront_assets('cjdropshipping','2609120902334496901','US');
  v := v || jsonb_build_object('case','nitro_image_unavailable','pass',a->>'state'='IMAGE_UNAVAILABLE' AND (a->>'usable_count')::int=0,'got',a->>'state');
  DELETE FROM public.supplier_product_assets WHERE supplier_product_id='SELFTEST_PID';
  r := public.fn_generate_storefront_runtime(u1,
        base_ok || '{"recommendation":"WATCH","sourcing_status":"PENDING_EXTERNAL_CJ_SOURCING","stock_state":"UNKNOWN","economics_state":"UNKNOWN","product_confidence":"UNKNOWN","fulfilment_evidence":false}'::jsonb,
        '{"category":"kitchen","buyer_pain":true}'::jsonb,
        '{"product_title":"Nitro Cold Brew Maker","positioning":"nitro cold brew maker","display_currency":"USD","selling_price":"89","supplier":"cjdropshipping","supplier_product_id":"2609120902334496901"}'::jsonb,
        '{"recommendation":"WATCH","target_market":"US","economics":{"economics_state":"UNKNOWN"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_refused_nitro','pass',r->>'status'='REFUSED' AND (r->>'test_eligible')::boolean=false,'got',r->>'status');
  r := public.fn_generate_storefront_runtime(u1, base_ok,
        '{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb,
        '{"product_title":"3-Channel Dash Cam","positioning":"3-channel dash cam","category":"electronics","display_currency":"USD","selling_price":"91.79","source_currency":"USD","supplier":"cjdropshipping","supplier_product_id":"1980170173102026754"}'::jsonb,
        '{"recommendation":"TEST","target_market":"US","economics":{"economics_state":"VIABLE","landed_cost_currency":"USD","landed_cost_display":"24.28"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_preview_contract','pass',
        r->>'status'='ok_preview' AND r->'runtime_contract'->>'template_family'='FEATURE_TECHNOLOGY'
        AND r->'runtime_contract'->>'template_version' IS NOT NULL
        AND r->'runtime_contract' ? 'ad_match_ref','got',r->'runtime_contract'->>'template_family');
  g := public.fn_generate_storefront_runtime(u1, base_ok,
        '{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb,
        '{"product_title":"3-Channel Dash Cam","positioning":"3-channel dash cam","category":"electronics","display_currency":"USD","selling_price":"91.79","supplier":"cjdropshipping","supplier_product_id":"1980170173102026754"}'::jsonb,
        '{"recommendation":"TEST","target_market":"US","economics":{"economics_state":"VIABLE"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_idempotent_preview','pass',
        (g->'runtime_contract'->>'template_family')=(r->'runtime_contract'->>'template_family'),'got',g->'runtime_contract'->>'template_family');
  INSERT INTO public.commerce_product_pages(user_id,market,destination,decision_classification,page_model,status,
     source_kind,review_state,publication_state,runtime_contract,country_code)
   VALUES (u1,'US','PULSE_STORE','TEST','{}'::jsonb,'DRAFT','REAL','DRAFT','UNPUBLISHED',
     '{"claim_safety":{"claim_scan_clean":true}}'::jsonb,'US')
   RETURNING id INTO pid;
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,source_kind)
   VALUES (u1,pid,'DRAFT','selftest-'||left(replace(pid::text,'-',''),8),'REAL');
  r := public.fn_storefront_transition_state(pid,'IN_REVIEW',u1);
  v := v || jsonb_build_object('case','transition_draft_to_in_review','pass',r->>'status'='ok' AND r->>'review_state'='IN_REVIEW','got',r->>'status');
  r := public.fn_storefront_transition_state(pid,'APPROVED',u1);
  v := v || jsonb_build_object('case','transition_in_review_to_approved','pass',r->>'status'='ok','got',r->>'status');
  r := public.fn_storefront_transition_state(pid,'PUBLISHED',u1);
  v := v || jsonb_build_object('case','transition_approved_to_published_pulse','pass',r->>'status'='ok' AND r->>'publication_state'='PUBLISHED','got',r->>'status');
  a := public.fn_storefront_ad_addressable(pid,u1);
  v := v || jsonb_build_object('case','ad_addressable_no_campaign_no_spend','pass',
        (a->>'campaign_created')::boolean=false AND (a->>'ad_spend_authorized')::int=0 AND (a->>'meta_activated')::boolean=false AND (a->>'addressable')::boolean=true,'got',a->>'status');
  r := public.fn_storefront_transition_state(pid,'ARCHIVED',u2);
  v := v || jsonb_build_object('case','cross_tenant_denied','pass',r->>'status'='DENIED_CROSS_TENANT','got',r->>'status');
  r := public.fn_storefront_change_country(pid,'DE',u1);
  v := v || jsonb_build_object('case','country_switch_resolves_context','pass',r->>'status'='COUNTRY_CONTEXT_RESOLUTION_REQUIRED' AND (r->>'currency_only_conversion_permitted')::boolean=false,'got',r->>'status');
  INSERT INTO public.commerce_product_pages(user_id,market,destination,decision_classification,page_model,status,
     source_kind,review_state,publication_state,runtime_contract)
   VALUES (u1,'US','PULSE_STORE','TEST','{}'::jsonb,'DRAFT','REAL','DRAFT','UNPUBLISHED','{"claim_safety":{"claim_scan_clean":true}}'::jsonb)
   RETURNING id INTO pid2;
  r := public.fn_storefront_transition_state(pid2,'PUBLISHED',u1);
  v := v || jsonb_build_object('case','invalid_transition_draft_to_published','pass',r->>'status'='INVALID_TRANSITION','got',r->>'status');
  r := public.fn_storefront_set_destination(pid2,'SHOPIFY',NULL,NULL,u1);
  v := v || jsonb_build_object('case','shopify_blocked_without_connection','pass',r->>'status'='BLOCKED_EXTERNAL_SHOPIFY_CONNECTION','got',r->>'status');
  r := public.fn_storefront_set_destination(pid2,'GENERIC_EXTERNAL_URL',NULL,'not a url',u1);
  v := v || jsonb_build_object('case','generic_url_invalid_blocked','pass',r->>'status' LIKE 'BLOCKED%','got',r->>'status');
  UPDATE public.commerce_product_pages SET runtime_contract='{"claim_safety":{"claim_scan_clean":false}}'::jsonb, review_state='IN_REVIEW' WHERE id=pid2;
  r := public.fn_storefront_transition_state(pid2,'APPROVED',u1);
  v := v || jsonb_build_object('case','claim_safety_not_bypassed_on_approve','pass',r->>'status'='BLOCKED_CLAIM_SAFETY','got',r->>'status');
  DELETE FROM public.commerce_store_projects WHERE product_page_id IN (pid,pid2);
  DELETE FROM public.commerce_product_pages WHERE id IN (pid,pid2);
  RETURN jsonb_build_object(
    'suite','PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'failures', (SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_set_destination(p_page_id uuid, p_destination text, p_store_connection_id uuid DEFAULT NULL::uuid, p_external_url text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pg public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_kind text := upper(coalesce(p_destination,''));
  v_col text;
  v_conn public.commerce_store_connections%rowtype; v_state text; v_note text; v_url text;
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  IF v_kind IN ('PULSE_HOSTED','PULSE_STORE') THEN
    v_kind := 'PULSE_HOSTED'; v_col := 'PULSE_STORE'; v_state := 'DESTINATION_READY';
    SELECT coalesce('pulse-store/'||slug||'/preview', public_route) INTO v_url
      FROM public.commerce_store_projects WHERE product_page_id=p_page_id LIMIT 1;
    v_note := 'Pulse-hosted beta runtime (noindex preview route)';
  ELSIF v_kind = 'SHOPIFY' THEN
    v_col := 'EXISTING_STORE';
    SELECT * INTO v_conn FROM public.commerce_store_connections WHERE id=p_store_connection_id AND provider='SHOPIFY';
    IF NOT FOUND OR coalesce(v_conn.connection_state,'') <> 'CONNECTED' THEN
      v_state := 'BLOCKED_EXTERNAL_SHOPIFY_CONNECTION';
      v_note := 'Shopify adapter boundary present; no connected store -> cannot publish (not faked)';
    ELSE
      v_state := 'DESTINATION_READY'; v_url := v_conn.store_domain;
      v_note := 'Shopify connection resolved';
    END IF;
  ELSIF v_kind = 'GENERIC_EXTERNAL_URL' THEN
    v_col := 'EXISTING_STORE';
    IF p_external_url IS NULL OR public.fn_cb_validate_destination(p_external_url) <> 'VALID' THEN
      v_state := 'BLOCKED_INVALID_EXTERNAL_URL'; v_note := 'external URL failed validation';
    ELSE
      v_state := 'DESTINATION_READY'; v_url := p_external_url; v_note := 'validated external URL';
    END IF;
  ELSIF v_kind = 'WOOCOMMERCE' THEN
    RETURN jsonb_build_object('status','DEFERRED_WOOCOMMERCE','note','WooCommerce remains deferred');
  ELSE
    RETURN jsonb_build_object('status','UNKNOWN_DESTINATION','destination',v_kind);
  END IF;
  UPDATE public.commerce_product_pages SET
    destination = v_col,
    store_connection_id = CASE WHEN v_kind='SHOPIFY' THEN p_store_connection_id ELSE store_connection_id END,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb)
       || jsonb_build_object('destination',v_col,'destination_kind',v_kind,'destination_state',v_state,'external_url',
            CASE WHEN v_kind='GENERIC_EXTERNAL_URL' THEN p_external_url ELSE NULL END,'resolved_url',v_url),
    updated_at = now()
  WHERE id=p_page_id;
  RETURN jsonb_build_object('status', CASE WHEN v_state='DESTINATION_READY' THEN 'ok' ELSE v_state END,
    'page_id',p_page_id,'destination',v_col,'destination_kind',v_kind,'destination_state',v_state,'resolved_url',v_url,'note',v_note);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_test_eligibility(p_inputs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_rec text := upper(coalesce(p_inputs->>'recommendation',''));
  v_tier text := upper(coalesce(p_inputs->>'decision_tier',''));
  v_sup text := upper(coalesce(p_inputs->>'supplier_identity_state',''));
  v_match text := upper(coalesce(p_inputs->>'market_supplier_match',''));
  v_subtype boolean := coalesce((p_inputs->>'subtype_price_valid')::boolean,false);
  v_stock text := upper(coalesce(p_inputs->>'stock_state','UNKNOWN'));
  v_econ text := upper(coalesce(p_inputs->>'economics_state','UNKNOWN'));
  v_conf text := upper(coalesce(p_inputs->>'product_confidence','UNKNOWN'));
  v_fulfil boolean := coalesce((p_inputs->>'fulfilment_evidence')::boolean,false);
  v_norisk boolean := coalesce((p_inputs->>'no_critical_risk')::boolean,false);
  v_sourcing text := upper(coalesce(p_inputs->>'sourcing_status',''));
  v_identity jsonb;
  v_reasons text[] := '{}';
  v_warn text[] := '{}';
  v_hi boolean := false;
BEGIN
  IF v_sourcing IN ('PENDING_EXTERNAL_CJ_SOURCING','PENDING','PROCESSING','SOURCING','AWAITING_SUPPLIER_RESULT','AWAITING_REFERENCE_IMAGE') THEN
    v_reasons := array_append(v_reasons, 'REJECT_SOURCING_PENDING_EXTERNAL');
  END IF;
  IF v_rec NOT IN ('TEST','HIGH_CONFIDENCE_TEST') THEN
    v_reasons := array_append(v_reasons, CASE v_rec
      WHEN 'WATCH' THEN 'REJECT_WATCH'
      WHEN 'AVOID' THEN 'REJECT_AVOID'
      WHEN 'ANALYSIS_REQUIRED' THEN 'REJECT_ANALYSIS_REQUIRED'
      ELSE 'REJECT_NOT_TEST_DECISION' END);
  END IF;
  v_identity := public.fn_test_identity_gate(v_sup, v_match, v_subtype, v_norisk);
  IF (v_identity->>'test_identity') IS DISTINCT FROM 'TEST_IDENTITY_SATISFIED' THEN
    IF v_sup IS DISTINCT FROM 'SUPPLIER_EXACT' THEN
      v_reasons := array_append(v_reasons, 'REJECT_SUPPLIER_NOT_CANONICAL');
    ELSE
      v_reasons := array_append(v_reasons, 'REJECT_IDENTITY_WEAK');
    END IF;
  END IF;
  IF v_stock = 'OUT_OF_STOCK' THEN v_reasons := array_append(v_reasons, 'REJECT_OUT_OF_STOCK');
  ELSIF v_stock <> 'IN_STOCK' THEN v_reasons := array_append(v_reasons, 'REJECT_STOCK_UNKNOWN');
  END IF;
  IF v_econ = 'NEGATIVE' THEN v_reasons := array_append(v_reasons, 'REJECT_ECONOMICS_UNVIABLE');
  ELSIF v_econ = 'THIN' THEN v_warn := array_append(v_warn, 'ECONOMICS_THIN');
  ELSIF v_econ <> 'VIABLE' THEN v_reasons := array_append(v_reasons, 'REJECT_ECONOMICS_UNKNOWN');
  END IF;
  IF v_conf NOT IN ('ACCEPTABLE','HIGH','STRONG') THEN
    v_reasons := array_append(v_reasons, 'REJECT_PRODUCT_CONFIDENCE_LOW');
  END IF;
  IF NOT v_fulfil THEN v_reasons := array_append(v_reasons, 'REJECT_NO_FULFILMENT_EVIDENCE'); END IF;
  IF NOT v_norisk THEN v_reasons := array_append(v_reasons, 'REJECT_CRITICAL_RISK'); END IF;
  v_hi := (v_rec = 'HIGH_CONFIDENCE_TEST') OR (v_tier = 'HIGH_CONFIDENCE_TEST');
  IF array_length(v_reasons,1) IS NULL THEN
    RETURN jsonb_build_object(
      'test_eligible', true, 'decision_state','TEST_ELIGIBLE',
      'decision_tier', CASE WHEN v_hi THEN 'HIGH_CONFIDENCE_TEST' ELSE 'STRONG_TEST' END,
      'high_confidence', v_hi,
      'reason_codes', jsonb_build_array('OK_TEST_ELIGIBLE'),
      'warnings', to_jsonb(v_warn), 'identity', v_identity,
      'checked', jsonb_build_object('recommendation',v_rec,'stock',v_stock,'economics',v_econ,
        'product_confidence',v_conf,'fulfilment_evidence',v_fulfil,'no_critical_risk',v_norisk,'sourcing_status',v_sourcing));
  ELSE
    RETURN jsonb_build_object(
      'test_eligible', false, 'decision_state','REFUSED',
      'decision_tier', CASE WHEN v_hi THEN 'HIGH_CONFIDENCE_TEST' ELSE NULLIF(v_tier,'') END,
      'high_confidence', false,
      'reason_codes', to_jsonb(v_reasons),
      'warnings', to_jsonb(v_warn), 'identity', v_identity,
      'checked', jsonb_build_object('recommendation',v_rec,'stock',v_stock,'economics',v_econ,
        'product_confidence',v_conf,'fulfilment_evidence',v_fulfil,'no_critical_risk',v_norisk,'sourcing_status',v_sourcing));
  END IF;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_storefront_transition_state(p_page_id uuid, p_target_state text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pg public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_cur text; v_tgt text := upper(coalesce(p_target_state,''));
  v_allowed boolean := false; v_clean boolean; v_dest text; v_pubstate text; v_puburl text;
  v_conn public.commerce_store_connections%rowtype;
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  v_cur := upper(coalesce(v_pg.review_state,'DRAFT'));
  v_allowed := (v_cur='DRAFT'     AND v_tgt IN ('IN_REVIEW','ARCHIVED'))
            OR (v_cur='IN_REVIEW' AND v_tgt IN ('APPROVED','DRAFT','ARCHIVED'))
            OR (v_cur='APPROVED'  AND v_tgt IN ('PUBLISHED','IN_REVIEW','ARCHIVED'))
            OR (v_cur='PUBLISHED' AND v_tgt IN ('APPROVED','ARCHIVED'))
            OR (v_cur='ARCHIVED'  AND v_tgt IN ('DRAFT'));
  IF NOT v_allowed THEN
    RETURN jsonb_build_object('status','INVALID_TRANSITION','from',v_cur,'to',v_tgt,
      'note','transition not permitted by the storefront lifecycle');
  END IF;
  IF v_tgt IN ('APPROVED','PUBLISHED') THEN
    v_clean := coalesce((v_pg.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, true);
    IF NOT v_clean THEN
      RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','from',v_cur,'to',v_tgt,
        'note','unsafe claims present; resolve editable placeholders before approval/publish');
    END IF;
  END IF;
  v_pubstate := v_pg.publication_state; v_puburl := v_pg.published_url;
  IF v_tgt = 'PUBLISHED' THEN
    v_dest := upper(coalesce(v_pg.runtime_contract->>'destination_kind',
                CASE WHEN upper(coalesce(v_pg.destination,'PULSE_STORE'))='EXISTING_STORE' THEN 'SHOPIFY' ELSE 'PULSE_HOSTED' END));
    IF v_dest = 'SHOPIFY' THEN
      SELECT * INTO v_conn FROM public.commerce_store_connections
       WHERE id = v_pg.store_connection_id AND provider='SHOPIFY';
      IF NOT FOUND OR coalesce(v_conn.connection_state,'') <> 'CONNECTED' THEN
        RETURN jsonb_build_object('status','BLOCKED_EXTERNAL_SHOPIFY_CONNECTION','from',v_cur,'to',v_tgt,
          'note','Shopify publishing requires a CONNECTED store connection; adapter boundary present, not faked');
      END IF;
      v_puburl := coalesce(v_conn.store_domain,'') ;
    ELSIF v_dest = 'GENERIC_EXTERNAL_URL' THEN
      v_puburl := v_pg.runtime_contract->>'external_url';
      IF v_puburl IS NULL OR public.fn_cb_validate_destination(v_puburl) <> 'VALID' THEN
        RETURN jsonb_build_object('status','BLOCKED_INVALID_EXTERNAL_URL','from',v_cur,'to',v_tgt);
      END IF;
    ELSE
      SELECT coalesce('pulse-store/'||slug||'/preview', public_route) INTO v_puburl
        FROM public.commerce_store_projects WHERE product_page_id = p_page_id LIMIT 1;
    END IF;
    v_pubstate := 'PUBLISHED';
  ELSIF v_tgt = 'ARCHIVED' THEN
    v_pubstate := 'ARCHIVED';
  ELSIF v_tgt = 'APPROVED' AND v_cur = 'PUBLISHED' THEN
    v_pubstate := 'UNPUBLISHED'; v_puburl := NULL;
  ELSIF v_tgt IN ('DRAFT','IN_REVIEW','APPROVED') THEN
    v_pubstate := 'UNPUBLISHED';
  END IF;
  UPDATE public.commerce_product_pages SET
    review_state = v_tgt,
    publication_state = v_pubstate,
    published_url = v_puburl,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb)
       || jsonb_build_object('review_state',v_tgt,'publication_state',v_pubstate),
    updated_at = now()
  WHERE id = p_page_id;
  RETURN jsonb_build_object('status','ok','page_id',p_page_id,'from',v_cur,'to',v_tgt,
    'review_state',v_tgt,'publication_state',v_pubstate,'published_url',v_puburl);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_backed_scan(p_pool_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
  WITH pool AS (
    SELECT * FROM public.commerce_supplier_products WHERE source='cjdropshipping' ORDER BY id LIMIT p_pool_limit
  ),
  pf AS (
    SELECT *, (image_url IS NOT NULL AND image_url<>'' AND supplier_cost IS NOT NULL AND sale_status='3') AS keep FROM pool
  ),
  matched AS (
    SELECT p.id, p.keep, p.source_product_id cj_pid, p.title, p.category, p.supplier_cost, p.cost_currency,
      dm.product_query, dm.market, dm.currency, dm.price_median, dm.total_listings, dm.mc
    FROM pf p
    LEFT JOIN LATERAL (
      SELECT q.product_query, q.market, q.currency, q.price_median, q.total_listings,
        public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class' mc
      FROM (SELECT DISTINCT product_query, market, currency, price_median, total_listings FROM public.market_price_observations) q
      WHERE p.keep AND public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class'
            IN ('EXACT_PRODUCT','CLOSE_COMPARABLE')
      ORDER BY CASE public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class'
                 WHEN 'EXACT_PRODUCT' THEN 0 ELSE 1 END, q.total_listings DESC
      LIMIT 1
    ) dm ON true
  )
  SELECT jsonb_build_object(
    'cj_products_scanned', (SELECT count(*) FROM matched),
    'pre_filtered_survivors', (SELECT count(*) FROM matched WHERE keep),
    'rejected_prefilter', (SELECT count(*) FROM matched WHERE NOT keep),
    'market_validated', (SELECT count(*) FROM matched WHERE mc IS NOT NULL),
    'rejected_no_exact_demand_match', (SELECT count(*) FROM matched WHERE keep AND mc IS NULL),
    'validated_candidates', coalesce((SELECT jsonb_agg(jsonb_build_object('cj_pid',cj_pid,'title',left(title,44),
        'category',category,'demand_query',product_query,'market',market,'local_price',price_median,'currency',currency,
        'listings',total_listings,'demand_match_class',mc,'supplier_cost',supplier_cost,'cost_currency',cost_currency)
        ORDER BY CASE mc WHEN 'EXACT_PRODUCT' THEN 0 ELSE 1 END, total_listings DESC)
      FROM matched WHERE mc IS NOT NULL),'[]'::jsonb),
    'policy', jsonb_build_object('supply_source','CJDROPSHIPPING (SUPPLY_ONLY)',
      'prefilter','usable primary image + supplier cost + active sale status',
      'demand_validation','canonical identity resolver EXACT_PRODUCT/CLOSE_COMPARABLE vs real eBay demand queries; category/keyword overlap never validates',
      'note','supplier availability alone never creates an opportunity; missing demand stays UNKNOWN'),
    'contract','pulse_supplier_backed_scan_v1')
  INTO result FROM (SELECT 1) _;
  RETURN result;
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_canonical_identity(p_pid text, p_query_confirmed_pid text, p_subtype_ok boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE st text; reason text;
BEGIN
  IF p_pid IS NULL OR length(trim(p_pid)) = 0 THEN
    st := 'SUPPLIER_UNCONFIRMED'; reason := 'NO_CJ_PID';
  ELSIF p_query_confirmed_pid IS NULL OR p_query_confirmed_pid <> p_pid THEN
    st := 'SUPPLIER_PID_UNVERIFIED'; reason := 'PRODUCT_QUERY_DID_NOT_CONFIRM_SAME_PID';
  ELSIF p_subtype_ok IS NOT TRUE THEN
    st := 'SUPPLIER_PID_UNVERIFIED'; reason := 'PID_CONFIRMED_BUT_SUBTYPE_INCOMPATIBLE';
  ELSE
    st := 'SUPPLIER_EXACT'; reason := 'CJ_PID_CONFIRMED_BY_PRODUCT_QUERY_AND_SUBTYPE';
  END IF;
  RETURN jsonb_build_object(
    'supplier_identity_state', st,
    'reason', reason,
    'cj_pid', p_pid,
    'query_confirmed_pid', p_query_confirmed_pid,
    'subtype_ok', coalesce(p_subtype_ok,false),
    'note','SUPPLIER_EXACT establishes canonical identity of the CJ product only; it never establishes market identity');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_delivery_state(p_codes jsonb, p_delivery_days numeric, p_target_market text, p_delivery_estimate jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  tm text := upper(btrim(coalesce(p_target_market,'')));
  supported boolean;
  has_codes boolean := (p_codes IS NOT NULL AND jsonb_typeof(p_codes)='array' AND jsonb_array_length(p_codes) > 0);
  est_min numeric := nullif(btrim(p_delivery_estimate->>'est_min_days'),'')::numeric;
  est_max numeric := nullif(btrim(p_delivery_estimate->>'est_max_days'),'')::numeric;
  est_dest text := upper(nullif(btrim(p_delivery_estimate->>'destination'),''));
  est_days numeric;
  est_pertains boolean := (p_delivery_estimate IS NOT NULL AND (est_dest IS NULL OR tm = '' OR est_dest = tm));
  explicit_negative boolean := (
     p_delivery_estimate IS NOT NULL AND (est_dest IS NULL OR tm = '' OR est_dest = tm) AND (
        lower(coalesce(p_delivery_estimate->>'destination_supported','')) = 'false'
        OR lower(coalesce(p_delivery_estimate->>'supported','')) = 'false'
        OR lower(coalesce(p_delivery_estimate->>'unsupported','')) = 'true'
        OR upper(coalesce(p_delivery_estimate->>'state','')) IN ('UNSUPPORTED','UNSUPPORTED_DELIVERY','OBSERVED_NEGATIVE','DESTINATION_UNSUPPORTED')
     ));
BEGIN
  -- Priority 0: explicit REAL provider negative for THIS destination -> OBSERVED_NEGATIVE (may FAIL).
  IF explicit_negative THEN
    RETURN jsonb_build_object('dimension','delivery','state','UNSUPPORTED_DELIVERY','market_evidence_state','OBSERVED_NEGATIVE',
      'known',true,'supported',false,'subscore',0,'critical',true,'estimate',false,'guaranteed',false,
      'destination',coalesce(est_dest,tm),'source',coalesce(p_delivery_estimate->>'source','CJ_FREIGHT_CALCULATE'),
      'observed_at',p_delivery_estimate->>'observed_at',
      'note','provider explicitly reports destination unsupported; real negative evidence');
  END IF;

  -- Priority 1: REAL freight estimate for THIS destination -> OBSERVED_SUPPORTED (conservative upper bound).
  IF p_delivery_estimate IS NOT NULL AND est_max IS NOT NULL AND est_pertains THEN
    est_days := est_max;
    RETURN jsonb_build_object(
      'dimension','delivery','state','PLATFORM_REPORTED','market_evidence_state','OBSERVED_SUPPORTED','known',true,'supported',true,
      'days',est_days,'estimate',true,'guaranteed',false,'critical',false,
      'est_min_days',est_min,'est_max_days',est_max,'destination',coalesce(est_dest,tm),
      'method',p_delivery_estimate->>'method',
      'shipping_cost',nullif(btrim(p_delivery_estimate->>'shipping_cost'),'')::numeric,
      'shipping_currency',p_delivery_estimate->>'shipping_currency',
      'source',coalesce(p_delivery_estimate->>'source','CJ_FREIGHT_CALCULATE'),
      'observed_at',p_delivery_estimate->>'observed_at',
      'subscore', CASE WHEN est_days<=7 THEN 100 WHEN est_days<=14 THEN 80
                       WHEN est_days<=21 THEN 60 WHEN est_days<=30 THEN 40 ELSE 20 END,
      'note','carrier estimated delivery range; not guaranteed');
  END IF;

  -- Priority 2: explicit single delivery_days.
  IF p_delivery_days IS NOT NULL THEN
    RETURN jsonb_build_object('dimension','delivery','state','PLATFORM_REPORTED','market_evidence_state','OBSERVED_SUPPORTED','known',true,'supported',true,
      'days',p_delivery_days,'critical',false,
      'subscore', CASE WHEN p_delivery_days<=7 THEN 100 WHEN p_delivery_days<=14 THEN 80
                       WHEN p_delivery_days<=21 THEN 60 WHEN p_delivery_days<=30 THEN 40 ELSE 20 END);
  END IF;

  -- Priority 3: shipping codes are POSITIVE-ONLY coverage evidence; absence is NEVER a negative.
  IF tm = '' THEN
    RETURN jsonb_build_object('dimension','delivery','state','UNKNOWN','market_evidence_state','UNKNOWN','known',false,'supported',NULL,'critical',false,
      'note','target market not specified');
  END IF;
  IF has_codes THEN
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_codes) c,
                          unnest(string_to_array(upper(c),'_')) tok WHERE tok = tm) INTO supported;
    IF supported THEN
      RETURN jsonb_build_object('dimension','delivery','state','PLATFORM_REPORTED','market_evidence_state','OBSERVED_SUPPORTED','known',true,'supported',true,
        'days',NULL,'subscore',55,'critical',false,'note','destination covered by supplier shipping codes; delivery time UNKNOWN');
    END IF;
  END IF;
  -- No freight probe for destination and not covered by codes: NOT_PROBED / INSUFFICIENT (never FAIL for absence).
  RETURN jsonb_build_object('dimension','delivery','state','NOT_PROBED','market_evidence_state','NOT_PROBED','known',false,'supported',NULL,'critical',false,
    'subscore',NULL,'destination',tm,
    'note','no freight probe performed for this destination; absence of a probe is not negative evidence (INSUFFICIENT_EVIDENCE)');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_economics(p_supplier jsonb, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_cost numeric := nullif(btrim(p_supplier->>'supplier_cost'),'')::numeric;
  v_free boolean := coalesce((p_supplier->>'is_free_shipping')::boolean,false);
  v_ship numeric := nullif(btrim(p_supplier->>'shipping_cost'),'')::numeric;
  v_ship_known boolean; v_ship_eff numeric;
  v_cur text := upper(coalesce(nullif(btrim(p_supplier->>'cost_currency'),''),'USD'));
  v_landed numeric; v_money jsonb; v_landed_disp numeric; v_margin numeric; v_margin_pct numeric;
  v_critical boolean := false; v_subscore numeric := NULL; v_conv text;
BEGIN
  -- supplier cost required
  IF v_cost IS NULL THEN
    RETURN jsonb_build_object('dimension','economics','state','UNKNOWN','market_evidence_state','UNKNOWN','known',false,'critical',false,
      'reason','supplier_cost_missing');
  END IF;

  -- shipping: destination-specific; NEVER assumed 0. 0 only when provider explicitly states free shipping.
  IF v_ship IS NOT NULL THEN v_ship_known := true; v_ship_eff := v_ship;
  ELSIF v_free THEN v_ship_known := true; v_ship_eff := 0;
  ELSE v_ship_known := false; v_ship_eff := NULL; END IF;

  IF NOT v_ship_known THEN
    RETURN jsonb_build_object('dimension','economics','state','UNKNOWN','market_evidence_state','INSUFFICIENT_EVIDENCE','known',false,'critical',false,
      'supplier_cost',v_cost,'cost_currency',v_cur,'shipping_known',false,
      'reason','shipping_cost_missing_for_destination_not_assumed_zero',
      'note','no destination-specific freight; shipping unknown -> economics UNKNOWN (never assume shipping=0)');
  END IF;

  v_landed := v_cost + v_ship_eff;
  v_money := public.normalize_money(v_landed, v_cur, p_display_currency);
  v_landed_disp := nullif(v_money->>'converted_amount','')::numeric;
  v_conv := v_money->>'conversion_status';

  -- FX fail-closed: unavailable / stale / no-display -> economics UNKNOWN (no fabricated conversion).
  IF v_landed_disp IS NULL THEN
    RETURN jsonb_build_object('dimension','economics','state','UNKNOWN','market_evidence_state','UNKNOWN','known',false,'critical',false,
      'supplier_cost',v_cost,'shipping_cost',v_ship_eff,'landed_cost_original',v_landed,'landed_cost_currency',v_cur,
      'shipping_known',true,'money',v_money,'reason','fx_unavailable_fails_closed',
      'note','FX conversion '||coalesce(v_conv,'unavailable')||'; economics UNKNOWN (GLOBAL-CURRENCY-001 fail-closed)');
  END IF;

  IF p_selling_price IS NOT NULL AND p_selling_price > 0 THEN
    v_margin := round(p_selling_price - v_landed_disp, 2);
    v_margin_pct := round(v_margin / p_selling_price, 4);
    v_critical := v_margin < 0;
    v_subscore := CASE WHEN v_margin_pct >= 0.60 THEN 100 WHEN v_margin_pct >= 0.40 THEN 80
                       WHEN v_margin_pct >= 0.25 THEN 60 WHEN v_margin_pct >= 0.15 THEN 45
                       WHEN v_margin_pct >= 0 THEN 25 ELSE 0 END;
  END IF;

  RETURN jsonb_build_object('dimension','economics','state','PLATFORM_REPORTED',
    'market_evidence_state', CASE WHEN v_margin IS NOT NULL AND v_margin < 0 THEN 'OBSERVED_NEGATIVE' ELSE 'OBSERVED' END,
    'known',true,'critical',v_critical,
    'subscore',v_subscore,'landed_cost_original',v_landed,'landed_cost_currency',v_cur,
    'landed_cost_display',v_landed_disp,'selling_price',p_selling_price,'margin',v_margin,'margin_pct',v_margin_pct,
    'shipping_cost',v_ship_eff,'shipping_known',true,'money',v_money);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_evidence(p_supplier jsonb, p_target_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_rating numeric := nullif(btrim(p_supplier->>'rating'),'')::numeric;
  v_rcount int := nullif(btrim(p_supplier->>'rating_count'),'')::int;
  v_auth text := upper(nullif(btrim(p_supplier->>'authenticity'),''));
  v_av text := upper(nullif(btrim(p_supplier->>'availability'),''));
  v_sale text := nullif(btrim(p_supplier->>'sale_status'),'');
  v_stock jsonb := p_supplier->'stock';
  v_stock_qty numeric := nullif(btrim(v_stock->>'total_inventory'),'')::numeric;
  v_rel jsonb; v_del jsonb; v_aut jsonb; v_avl jsonb;
BEGIN
  -- reliability: CJ exposes no supplier rating/reviews/fulfilment -> RELIABILITY_UNKNOWN (never inferred from price/listing/sale).
  IF v_rating IS NULL THEN v_rel := jsonb_build_object('dimension','reliability','state','RELIABILITY_UNKNOWN','known',false,'critical',false);
  ELSE v_rel := jsonb_build_object('dimension','reliability','state','PLATFORM_REPORTED','known',true,
         'rating',v_rating,'rating_count',v_rcount,'subscore',round(v_rating/5.0*100),
         'critical',(v_rating <= 2.0 AND coalesce(v_rcount,0) >= 20));
  END IF;

  -- delivery: market-aware; real freight estimate takes priority when present.
  v_del := public.fn_supplier_delivery_state(p_supplier->'shipping_country_codes',
             nullif(btrim(p_supplier->>'delivery_days'),'')::numeric, p_target_market,
             p_supplier->'delivery_estimate');

  -- authenticity: CJ exposes no verification/brand-authorization -> AUTHENTICITY_UNKNOWN (never labelled genuine merely because listed).
  IF v_auth IN ('VERIFIED','GENUINE','BRAND_AUTHORIZED') THEN
    v_aut := jsonb_build_object('dimension','authenticity','state','PLATFORM_REPORTED','known',true,'value',v_auth,'subscore',100,'critical',false);
  ELSIF v_auth IN ('COUNTERFEIT','FAKE','INFRINGING') THEN
    v_aut := jsonb_build_object('dimension','authenticity','state','OBSERVED','known',true,'value',v_auth,'subscore',0,'critical',true);
  ELSE
    v_aut := jsonb_build_object('dimension','authenticity','state','AUTHENTICITY_UNKNOWN','known',false,'critical',false);
  END IF;

  -- availability: explicit CJ inventory quantity is genuine STOCK (OBSERVED); else listing-status proxy; else UNKNOWN.
  IF v_stock_qty IS NOT NULL THEN
    v_avl := jsonb_build_object('dimension','availability','state','OBSERVED','known',true,
      'value','warehouse_inventory','stock_quantity',v_stock_qty,
      'warehouse',v_stock->>'warehouse','warehouse_country',v_stock->>'warehouse_country',
      'source',coalesce(v_stock->>'source','CJ_STOCK_QUERY_BY_VID'),'observed_at',v_stock->>'observed_at',
      'subscore', CASE WHEN v_stock_qty >= 100 THEN 90 WHEN v_stock_qty >= 20 THEN 70
                       WHEN v_stock_qty >= 1 THEN 40 ELSE 15 END,
      'critical',(v_stock_qty = 0),
      'note','explicit CJ warehouse inventory quantity (not listing_count/listed_num)');
  ELSIF v_av IN ('IN_STOCK','ACTIVE') THEN v_avl := jsonb_build_object('dimension','availability','state','PLATFORM_REPORTED','known',true,'value',v_av,'subscore',85,'critical',false);
  ELSIF v_av IN ('LOW_STOCK') THEN v_avl := jsonb_build_object('dimension','availability','state','PLATFORM_REPORTED','known',true,'value',v_av,'subscore',50,'critical',false);
  ELSIF v_av IN ('OUT_OF_STOCK','DISCONTINUED') THEN v_avl := jsonb_build_object('dimension','availability','state','PLATFORM_REPORTED','known',true,'value',v_av,'subscore',15,'critical',false);
  ELSIF v_sale IS NOT NULL THEN v_avl := jsonb_build_object('dimension','availability','state','PLATFORM_REPORTED','known',true,'value','active_listing','subscore',60,'critical',false,'note','listing status, not stock quantity');
  ELSE v_avl := jsonb_build_object('dimension','availability','state','UNKNOWN','known',false,'critical',false);
  END IF;

  RETURN jsonb_build_object('reliability',v_rel,'delivery',v_del,'authenticity',v_aut,'availability',v_avl);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_evidence_sufficiency(p_dims jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN (p_dims->'economics'->>'known')::boolean AND (p_dims->'delivery'->>'known')::boolean
         AND (p_dims->'reliability'->>'known')::boolean AND (p_dims->'authenticity'->>'known')::boolean THEN 'SUPPLIER_EVIDENCE_STRONG'
    WHEN (p_dims->'economics'->>'known')::boolean AND (p_dims->'delivery'->>'known')::boolean
         AND ((p_dims->'reliability'->>'known')::boolean OR (p_dims->'authenticity'->>'known')::boolean) THEN 'SUPPLIER_EVIDENCE_SUFFICIENT'
    WHEN (p_dims->'economics'->>'known')::boolean AND (p_dims->'delivery'->>'known')::boolean THEN 'SUPPLIER_EVIDENCE_PARTIAL'
    ELSE 'SUPPLIER_EVIDENCE_INSUFFICIENT'
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_execution_gate(p_supplier jsonb, p_target_market text, p_selling_price numeric, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_ev jsonb := public.fn_supplier_evidence(p_supplier, p_target_market);
  v_del jsonb := v_ev->'delivery'; v_avl jsonb := v_ev->'availability';
  v_econ jsonb := public.fn_supplier_economics(p_supplier, p_selling_price, p_display_currency);
  v_rel jsonb := public.fn_supplier_reliability_state(p_supplier);
  v_margin numeric := nullif(v_econ->>'margin_pct','')::numeric;
  v_crit text[] := '{}'; v_gate text; v_reasons text[] := '{}';
  v_del_known boolean := (v_del->>'known')::boolean;
  v_econ_known boolean := (v_econ->>'known')::boolean;
  v_avl_known boolean := (v_avl->>'known')::boolean;
BEGIN
  IF (v_del->>'critical')::boolean THEN v_crit := array_append(v_crit,'delivery_unsupported_in_target_market'); END IF;
  IF (v_econ->>'critical')::boolean THEN v_crit := array_append(v_crit,'economics_negative_margin'); END IF;
  IF (v_avl->>'critical')::boolean THEN v_crit := array_append(v_crit,'availability_zero_stock'); END IF;
  IF (v_rel->>'critical')::boolean THEN v_crit := array_append(v_crit,'reliability_confirmed_negative'); END IF;

  IF array_length(v_crit,1) > 0 THEN
    v_gate := 'SUPPLIER_EXECUTION_FAIL'; v_reasons := v_crit;
  ELSIF NOT (coalesce(v_del_known,false) AND coalesce(v_econ_known,false)) THEN
    v_gate := 'SUPPLIER_EXECUTION_INSUFFICIENT';
    IF NOT coalesce(v_del_known,false) THEN v_reasons := array_append(v_reasons,'delivery_unknown'); END IF;
    IF NOT coalesce(v_econ_known,false) THEN v_reasons := array_append(v_reasons,'economics_unknown'); END IF;
  ELSIF (v_del->>'supported')::boolean IS TRUE AND coalesce(v_margin,-1) >= 0.15 AND coalesce(v_avl_known,false) THEN
    v_gate := 'SUPPLIER_EXECUTION_PASS'; v_reasons := array_append(v_reasons,'delivery_supported,margin_ok,availability_known');
  ELSE
    v_gate := 'SUPPLIER_EXECUTION_WATCH';
    IF (v_del->>'supported')::boolean IS DISTINCT FROM TRUE THEN v_reasons := array_append(v_reasons,'delivery_support_unconfirmed'); END IF;
    IF coalesce(v_margin,-1) < 0.15 THEN v_reasons := array_append(v_reasons,'margin_thin_or_unknown'); END IF;
    IF NOT coalesce(v_avl_known,false) THEN v_reasons := array_append(v_reasons,'availability_unknown'); END IF;
  END IF;

  RETURN jsonb_build_object('supplier_execution_gate',v_gate,'reasons',to_jsonb(v_reasons),
    'critical_failures',to_jsonb(v_crit),
    'reliability_state', v_rel->>'state', 'reliability', v_rel,
    'delivery', v_del, 'availability', v_avl, 'economics', v_econ);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_gate(p_dims jsonb, p_score jsonb, p_sufficiency text, p_econ jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  c_pass_score numeric := 70; c_pass_margin numeric := 0.15;
  v_crit text[] := '{}'; v_score numeric := nullif(p_score->>'score','')::numeric;
  v_margin numeric := nullif(p_econ->>'margin_pct','')::numeric; v_gate text; v_reasons text[] := '{}';
BEGIN
  IF (p_dims->'delivery'->>'critical')::boolean THEN v_crit := array_append(v_crit,'delivery_unsupported_in_target_market'); END IF;
  IF (p_dims->'authenticity'->>'critical')::boolean THEN v_crit := array_append(v_crit,'authenticity_counterfeit_or_infringing'); END IF;
  IF (p_dims->'reliability'->>'critical')::boolean THEN v_crit := array_append(v_crit,'reliability_confirmed_severe'); END IF;
  IF (p_econ->>'critical')::boolean THEN v_crit := array_append(v_crit,'economics_negative_margin'); END IF;

  IF array_length(v_crit,1) > 0 THEN
    v_gate := 'FAIL'; v_reasons := v_crit;
  ELSIF p_sufficiency = 'SUPPLIER_EVIDENCE_INSUFFICIENT' THEN
    v_gate := 'INSUFFICIENT_EVIDENCE'; v_reasons := array_append(v_reasons,'insufficient_supplier_evidence');
  ELSIF v_score >= c_pass_score AND coalesce(v_margin,-1) >= c_pass_margin
        AND (p_dims->'delivery'->>'supported')::boolean IS TRUE
        AND p_sufficiency IN ('SUPPLIER_EVIDENCE_SUFFICIENT','SUPPLIER_EVIDENCE_STRONG') THEN
    v_gate := 'PASS'; v_reasons := array_append(v_reasons,'quality>=70,acceptable_margin,delivery_supported,sufficient_evidence');
  ELSE
    v_gate := 'WATCH';
    IF coalesce(v_score,0) < c_pass_score THEN v_reasons := array_append(v_reasons,'quality_below_pass_threshold'); END IF;
    IF coalesce(v_margin,-1) < c_pass_margin THEN v_reasons := array_append(v_reasons,'margin_thin_or_unknown'); END IF;
    IF (p_dims->'delivery'->>'supported')::boolean IS DISTINCT FROM TRUE THEN v_reasons := array_append(v_reasons,'delivery_time_or_support_unconfirmed'); END IF;
    IF p_sufficiency = 'SUPPLIER_EVIDENCE_PARTIAL' THEN v_reasons := array_append(v_reasons,'evidence_partial'); END IF;
  END IF;
  RETURN jsonb_build_object('supplier_gate', v_gate, 'reasons', to_jsonb(v_reasons), 'critical_failures', to_jsonb(v_crit),
    'thresholds', jsonb_build_object('pass_score', c_pass_score, 'pass_margin_pct', c_pass_margin));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_provider_canon(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN upper(btrim(coalesce(p,''))) LIKE 'CJ%' THEN 'CJ'
    WHEN upper(btrim(coalesce(p,''))) LIKE 'ALI%' THEN 'ALIEXPRESS'
    WHEN upper(btrim(coalesce(p,''))) LIKE 'BIGBUY%' THEN 'BIGBUY'
    WHEN upper(btrim(coalesce(p,''))) LIKE 'SPOCKET%' THEN 'SPOCKET'
    ELSE upper(btrim(coalesce(p,''))) END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_quality_score(p_dims jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  w jsonb := jsonb_build_object('reliability',30,'delivery',25,'authenticity',20,'availability',10,'economics',15);
  d text; dim jsonb; num numeric := 0; den numeric := 0; scored text[] := '{}'; unknown text[] := '{}'; ss numeric;
BEGIN
  FOREACH d IN ARRAY ARRAY['reliability','delivery','authenticity','availability','economics'] LOOP
    dim := p_dims->d;
    ss := nullif(dim->>'subscore','')::numeric;
    IF (dim->>'known')::boolean IS TRUE AND ss IS NOT NULL THEN
      num := num + ss * (w->>d)::numeric; den := den + (w->>d)::numeric; scored := scored || d;
    ELSE unknown := unknown || d; END IF;
  END LOOP;
  IF den = 0 THEN RETURN jsonb_build_object('score',NULL,'scored_dimensions',to_jsonb(scored),'unknown_dimensions',to_jsonb(unknown)); END IF;
  RETURN jsonb_build_object('score',round(num/den),'scored_dimensions',to_jsonb(scored),'unknown_dimensions',to_jsonb(unknown),
    'weights',w,'note','weighted over known dimensions only');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_reliability_state(p_supplier jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_rating numeric := nullif(btrim(p_supplier->>'rating'),'')::numeric;
  v_rcount int := nullif(btrim(p_supplier->>'rating_count'),'')::int;
  v_src text := lower(coalesce(p_supplier->>'source',''));
  v_no_reliability_sources text[] := ARRAY['cjdropshipping'];
BEGIN
  IF v_rating IS NOT NULL THEN
    IF v_rating <= 2.0 AND coalesce(v_rcount,0) >= 20 THEN
      RETURN jsonb_build_object('dimension','reliability','state','RELIABILITY_NEGATIVE','known',true,'observable',true,
        'critical',true,'rating',v_rating,'rating_count',v_rcount,'subscore',round(v_rating/5.0*100));
    ELSIF coalesce(v_rcount,0) >= 20 THEN
      RETURN jsonb_build_object('dimension','reliability','state','RELIABILITY_OBSERVED','known',true,'observable',true,
        'critical',false,'rating',v_rating,'rating_count',v_rcount,'subscore',round(v_rating/5.0*100));
    ELSE
      RETURN jsonb_build_object('dimension','reliability','state','RELIABILITY_PARTIAL','known',true,'observable',true,
        'critical',false,'rating',v_rating,'rating_count',v_rcount,'subscore',round(v_rating/5.0*100),
        'note','rating present but low sample');
    END IF;
  END IF;
  IF v_src = ANY(v_no_reliability_sources) THEN
    RETURN jsonb_build_object('dimension','reliability','state','RELIABILITY_NOT_OBSERVABLE_FROM_SOURCE','known',false,
      'observable',false,'critical',false,'subscore',NULL,
      'note','source exposes no supplier rating/fulfilment/dispute data; not converted to a positive score');
  END IF;
  RETURN jsonb_build_object('dimension','reliability','state','RELIABILITY_UNKNOWN','known',false,'observable',NULL,
    'critical',false,'subscore',NULL);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_supplier_stock_state(p_supplier jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  st jsonb := coalesce(p_supplier->'stock','{}'::jsonb);
  v_explicit text;
  v_cj numeric; v_factory numeric; v_total numeric; v_generic numeric; v_qty numeric;
  v_wh_country text; v_wh text;
  v_state text; v_ready boolean := NULL; v_test boolean; v_known boolean;
BEGIN
  v_explicit := upper(nullif(btrim(coalesce(p_supplier->>'stock_state', st->>'stock_state')),''));
  v_cj      := nullif(btrim(st->>'cj_inventory'),'')::numeric;
  v_factory := nullif(btrim(st->>'factory_inventory'),'')::numeric;
  v_total   := nullif(btrim(st->>'total_inventory'),'')::numeric;
  v_generic := nullif(btrim(coalesce(p_supplier->>'stock_quantity', st->>'quantity', st->>'stock')),'')::numeric;
  v_wh_country := upper(nullif(btrim(coalesce(st->>'warehouse_country', p_supplier->>'warehouse_country')),''));
  v_wh := nullif(btrim(coalesce(st->>'warehouse', p_supplier->>'warehouse')),'');

  -- effective available quantity from strongest available evidence
  v_qty := coalesce(v_total, v_generic,
                    CASE WHEN v_cj IS NOT NULL OR v_factory IS NOT NULL
                         THEN coalesce(v_cj,0)+coalesce(v_factory,0) END);
  IF v_cj IS NOT NULL THEN v_ready := (v_cj > 0); END IF;

  IF v_explicit IN ('IN_STOCK','OUT_OF_STOCK','UNKNOWN_STOCK') THEN
    v_state := v_explicit;
  ELSIF v_qty IS NOT NULL THEN
    v_state := CASE WHEN v_qty > 0 THEN 'IN_STOCK' ELSE 'OUT_OF_STOCK' END;
  ELSE
    v_state := 'UNKNOWN_STOCK';
  END IF;

  v_known := (v_state <> 'UNKNOWN_STOCK');
  v_test  := (v_state = 'IN_STOCK');

  RETURN jsonb_build_object(
    'dimension','stock','stock_state',v_state,
    'known',v_known,'test_eligible',v_test,
    'test_gate', CASE WHEN v_state='IN_STOCK' THEN 'STOCK_OK'
                      WHEN v_state='OUT_OF_STOCK' THEN 'BLOCKED_OUT_OF_STOCK'
                      ELSE 'BLOCKED_UNKNOWN_STOCK' END,
    'quantity',v_qty,'warehouse_ready',v_ready,
    'warehouse_country',v_wh_country,'warehouse',v_wh,
    'source', coalesce(st->>'source', p_supplier->>'stock_source'),
    'observed_at', st->>'observed_at',
    'note', CASE
      WHEN v_state='UNKNOWN_STOCK' THEN 'no stock evidence; missing stock is not availability; cannot become production TEST until verified'
      WHEN v_state='IN_STOCK' AND v_ready IS NOT NULL AND v_ready=false THEN 'available via factory/secondary inventory only; warehouse-ready stock is 0 (slower dispatch)'
      WHEN v_state='OUT_OF_STOCK' THEN 'observed zero available inventory; cannot TEST'
      ELSE 'stock available' END);
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_test_identity_gate(p_supplier_state text, p_market_match text, p_subtype_price_valid boolean DEFAULT false, p_no_critical_risk boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE verdict text; basis text; reason text;
BEGIN
  IF p_supplier_state IS DISTINCT FROM 'SUPPLIER_EXACT' THEN
    verdict := 'REJECT'; basis := 'SUPPLIER_NOT_CANONICAL'; reason := 'CJ product not canonically confirmed (need PID confirmed by product/query)';
  ELSIF p_market_match = 'EXACT_CONFIRMED' THEN
    IF p_no_critical_risk THEN verdict := 'TEST_IDENTITY_SATISFIED'; basis := 'SUPPLIER_EXACT_AND_MARKET_EXACT';
    ELSE verdict := 'WATCH'; basis := 'CRITICAL_RISK'; END IF;
    reason := 'exact market<->supplier identity';
  ELSIF p_market_match = 'STRONG_SAME_PRODUCT' THEN
    IF p_subtype_price_valid AND p_no_critical_risk THEN
      verdict := 'TEST_IDENTITY_SATISFIED'; basis := 'SUPPLIER_EXACT_AND_STRONG_SAME_SUBTYPE'; reason := 'same product at same commercial subtype; price/demand evidence valid at that subtype';
    ELSE
      verdict := 'WATCH'; basis := 'STRONG_BUT_SUBTYPE_PRICE_OR_RISK';
      reason := CASE WHEN NOT p_subtype_price_valid THEN 'price/demand evidence not validated at the same commercial subtype' ELSE 'critical risk present' END;
    END IF;
  ELSE
    verdict := 'WATCH'; basis := 'IDENTITY_TOO_WEAK'; reason := 'market<->supplier identity below STRONG_SAME_PRODUCT';
  END IF;
  RETURN jsonb_build_object('test_identity', verdict, 'basis', basis, 'reason', reason,
    'supplier_identity_state', p_supplier_state, 'market_supplier_match', p_market_match,
    'subtype_price_valid', coalesce(p_subtype_price_valid,false), 'no_critical_risk', coalesce(p_no_critical_risk,true));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_text_tokens(t text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT coalesce(array_agg(DISTINCT tok), '{}')
  FROM (
    SELECT unnest(regexp_split_to_array(lower(coalesce(t,'')), '[^a-z0-9]+')) tok
  ) s
  WHERE length(tok) >= 3
    AND tok NOT IN ('the','for','and','with','usb','led','set','kit','pack','new','gift','mini','pro','plus');
$function$
;

CREATE OR REPLACE FUNCTION public.fn_tracking_readiness(p_tenant uuid, p_cb_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.campaign_builder_drafts; v_ident public.commerce_tracking_identities;
  v_has_ident boolean; v_has_dest boolean; v_vc int; v_pur int; v_pur_valued int; v_meta text; v_state text; v_checks jsonb;
BEGIN
  SELECT * INTO c FROM public.campaign_builder_drafts WHERE id=p_cb_campaign_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO v_ident FROM public.commerce_tracking_identities WHERE campaign_id=p_cb_campaign_id AND tenant_id=p_tenant LIMIT 1;
  v_has_ident := FOUND;
  v_has_dest := v_has_ident AND v_ident.decorated_url IS NOT NULL AND position('pt=' in coalesce(v_ident.decorated_url,''))>0;
  SELECT count(*) INTO v_vc FROM public.commerce_events WHERE tenant_id=p_tenant AND campaign_id=p_cb_campaign_id AND event_name='VIEW_CONTENT';
  SELECT count(*) INTO v_pur FROM public.commerce_events WHERE tenant_id=p_tenant AND campaign_id=p_cb_campaign_id AND event_name='PURCHASE';
  SELECT count(*) INTO v_pur_valued FROM public.commerce_events WHERE tenant_id=p_tenant AND campaign_id=p_cb_campaign_id AND event_name='PURCHASE' AND value IS NOT NULL AND currency IS NOT NULL;
  SELECT state INTO v_meta FROM public.meta_tracking_config WHERE tenant_id=p_tenant;

  v_checks := jsonb_build_object('tracking_identity',v_has_ident,'destination_decorated',v_has_dest,
     'view_content_observable',(v_vc>0),'purchase_observable',(v_pur>0),'purchase_value_captured',(v_pur_valued>0 OR v_pur=0),
     'dedup_operational',true,'attribution_operational',v_has_ident,'meta_tracking_configured',(coalesce(v_meta,'NOT_CONFIGURED')='CONFIGURED'));

  v_state := CASE
    WHEN NOT v_has_ident THEN 'NOT_CONFIGURED'
    WHEN v_pur>0 AND v_pur_valued=0 THEN 'DEGRADED'   -- purchases arriving without value/currency
    WHEN v_has_ident AND v_has_dest AND v_vc>0 AND v_pur>0 AND v_pur_valued>0
         AND coalesce(v_meta,'NOT_CONFIGURED')='CONFIGURED' THEN 'READY'
    ELSE 'PARTIAL' END;

  UPDATE public.campaign_builder_drafts SET tracking_state=v_state, updated_at=now() WHERE id=p_cb_campaign_id;
  -- integrate with Phase 11: readiness only; never authorize spend/activation
  RETURN jsonb_build_object('status','ok','tracking_state',v_state,'checks',v_checks,
    'spend_authorization',c.spend_authorization,'activation_authorization',c.activation_authorization,
    'note','tracking readiness is one prerequisite; does NOT authorize spend or activation');
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_weighted_over_observed(p_dims jsonb, p_weights jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE d text; dim jsonb; st text; sc numeric; wt numeric; total numeric := 0;
        num numeric := 0; den numeric := 0; detail jsonb := '{}'::jsonb; blocked text[] := '{}'; unknown text[] := '{}';
BEGIN
  FOR d IN SELECT jsonb_object_keys(p_weights) LOOP
    wt := (p_weights->>d)::numeric; total := total + wt;
    dim := p_dims->d; st := coalesce(dim->>'state','NOT_OBSERVED'); sc := nullif(dim->>'score','')::numeric;
    IF st='OBSERVED' AND sc IS NOT NULL THEN
      num := num + sc*wt; den := den + wt;
      detail := detail || jsonb_build_object(d, jsonb_build_object('evidence_state',st,'score',sc,'max_weight',wt,
        'weighted_contribution',round(sc*wt/100.0,2),'confidence',dim->>'confidence','freshness',dim->>'freshness',
        'market_alignment',dim->>'market_alignment','provenance',dim->>'provenance',
        'reasoning_factors',dim->'reasoning_factors','unknowns',dim->'unknowns','counts_toward_score',true));
    ELSE
      IF st='SOURCE_BLOCKED' THEN blocked := array_append(blocked,d); ELSE unknown := array_append(unknown,d); END IF;
      detail := detail || jsonb_build_object(d, jsonb_build_object('evidence_state',st,'score',NULL,'max_weight',wt,
        'weighted_contribution',0,'blocked_reason',dim->>'blocked_reason','counts_toward_score',false,
        'note','excluded from score; NOT scored as zero'));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('score', CASE WHEN den>0 THEN round(num/den) ELSE NULL END,
    'observed_weight',den,'total_weight',total,'completeness',round(den/total,2),
    'dimensions',detail,'blocked_sources',to_jsonb(blocked),'unknown_dimensions',to_jsonb(unknown),'insufficient',(den=0));
END; $function$
;

CREATE OR REPLACE FUNCTION public.fn_winner_evaluation(p_prediction jsonb, p_actuals jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  purchases int := nullif(p_actuals->>'purchases','')::int;
  actual_cpa numeric := nullif(p_actuals->>'cpa','')::numeric;
  be_cpa numeric := nullif(p_prediction->>'break_even_cpa','')::numeric;
  contribution numeric := nullif(p_actuals->>'contribution','')::numeric;
  refunds int := nullif(p_actuals->>'refunds','')::int;
  v_class text; v_diag text := NULL;
BEGIN
  IF p_actuals IS NULL OR purchases IS NULL OR purchases < 1 THEN
    RETURN jsonb_build_object('lifecycle','VALIDATING','reason','no_real_purchase_data_yet',
      'note','pre-conversion; cannot be WINNER');
  END IF;
  IF actual_cpa IS NOT NULL AND be_cpa IS NOT NULL AND actual_cpa < be_cpa
     AND coalesce(contribution,0) > 0 AND purchases >= 5 AND coalesce(refunds,0) < purchases*0.2 THEN
    v_class := 'WINNER';
  ELSIF actual_cpa IS NULL OR be_cpa IS NULL THEN
    v_class := 'IMPROVE'; v_diag := 'CHECKOUT_OR_TRACKING';
  ELSIF actual_cpa >= be_cpa AND coalesce(contribution,0) <= 0 THEN
    v_class := 'IMPROVE'; v_diag := 'CREATIVE_OR_OFFER_OR_PRICE';
  ELSIF coalesce(refunds,0) >= purchases*0.2 THEN
    v_class := 'IMPROVE'; v_diag := 'PRODUCT_OR_DELIVERY';
  ELSE
    v_class := 'IMPROVE'; v_diag := 'AUDIENCE_OR_PRODUCT_PAGE';
  END IF;
  RETURN jsonb_build_object('lifecycle',v_class,'improve_diagnosis',v_diag,
    'actual_cpa',actual_cpa,'break_even_cpa',be_cpa,'purchases',purchases,'contribution',contribution,'refunds',refunds,
    'note','WINNER requires actual CPA below break-even, positive contribution, repeat purchases, acceptable refunds');
END; $function$
;

CREATE OR REPLACE FUNCTION public.get_executable_meta_draft(p_draft_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    d public.marketing_campaign_drafts%ROWTYPE; cfg public.meta_platform_config%ROWTYPE;
    v_meta jsonb; v_campaign jsonb; v_acct_ref text; v_page_ref text; v_currency text;
    v_exec public.marketing_campaign_executions%ROWTYPE; v_fp_now text; v_fp_appr text;
BEGIN
    IF p_draft_id IS NULL THEN RETURN jsonb_build_object('status','blocked','reason','no_draft_id'); END IF;
    SELECT * INTO d FROM public.marketing_campaign_drafts WHERE id=p_draft_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','blocked','reason','draft_not_found','draft_id',p_draft_id); END IF;

    SELECT * INTO v_exec FROM public.marketing_campaign_executions
    WHERE draft_id=p_draft_id AND platform='meta' AND status='CREATED_PAUSED';
    IF FOUND THEN
        RETURN jsonb_build_object('status','already_executed','draft_id',p_draft_id,'execution_id',v_exec.id,
            'refs',jsonb_build_object('campaign_id',v_exec.meta_campaign_id,'adset_id',v_exec.meta_adset_id,
                                      'creative_id',v_exec.meta_creative_id,'ad_id',v_exec.meta_ad_id),
            'effective_status',v_exec.effective_status); END IF;

    IF d.user_id IS NULL THEN RETURN jsonb_build_object('status','blocked','reason','no_owner','draft_id',p_draft_id); END IF;
    IF coalesce(d.status,'')<>'APPROVED' THEN
        RETURN jsonb_build_object('status','blocked','reason','not_approved','draft_id',p_draft_id,'draft_status',d.status); END IF;
    IF coalesce(d.lifecycle->>'publishable','false')<>'true'
       OR coalesce(d.lifecycle->'approval'->>'explicit_publish_approval','false')<>'true' THEN
        RETURN jsonb_build_object('status','blocked','reason','lifecycle_gate_failed','lifecycle',d.lifecycle); END IF;

    -- DRAFT_CREATION_AUTHORIZATION must be explicitly true (set by approval).
    IF coalesce(d.lifecycle->'authorizations'->>'draft_creation_authorization','false')<>'true' THEN
        RETURN jsonb_build_object('status','blocked','reason','draft_creation_not_authorized','draft_id',p_draft_id); END IF;

    -- Post-approval invalidation: execution-relevant fields must match what was approved.
    v_fp_now := public.fn_meta_execution_fingerprint(p_draft_id);
    v_fp_appr := d.lifecycle->'approval'->>'execution_fingerprint';
    IF v_fp_appr IS NULL OR v_fp_appr <> v_fp_now THEN
        RETURN jsonb_build_object('status','blocked','reason','approval_stale_revalidate','draft_id',p_draft_id); END IF;

    v_meta := d.platform_payloads->'meta';
    IF v_meta IS NULL OR jsonb_typeof(v_meta)<>'object'
       OR jsonb_typeof(v_meta->'campaigns')<>'array' OR jsonb_array_length(v_meta->'campaigns')=0 THEN
        RETURN jsonb_build_object('status','blocked','reason','no_meta_payload','draft_id',p_draft_id); END IF;
    v_campaign := v_meta->'campaigns'->0;

    SELECT * INTO cfg FROM public.meta_platform_config WHERE id=1;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','blocked','reason','no_platform_config'); END IF;

    v_acct_ref := coalesce(v_meta->>'account_ref','');
    v_page_ref := coalesce(v_meta->>'page_ref','');
    IF v_acct_ref !~ '^act_[0-9]+$' THEN v_acct_ref := cfg.account_id; END IF;
    IF v_page_ref !~ '^[0-9]+$' THEN v_page_ref := cfg.page_id; END IF;
    v_currency := coalesce(nullif(v_meta->>'currency',''), cfg.currency);

    RETURN jsonb_build_object('status','executable','draft_id',p_draft_id,'user_id',d.user_id,
        'idempotency_key',p_draft_id::text||':meta',
        'resolved',jsonb_build_object('account_id',v_acct_ref,'page_id',v_page_ref,'currency',v_currency,'graph_version',cfg.graph_version),
        'campaign',v_campaign,
        'budget',jsonb_build_object(
            'daily_budget_minor',(v_campaign->'ad_sets'->0->>'daily_budget'),
            'spend_cap_minor',(v_campaign->>'spend_cap')),
        'authorizations', d.lifecycle->'authorizations',
        'enforced',jsonb_build_object('status','PAUSED','publish',false,'activation_authorized',false,'spend_authorized',0));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_fx_rate(p_from text, p_to text, p_max_age_hours integer DEFAULT 36)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
    a text := upper(btrim(coalesce(p_from,''))); b text := upper(btrim(coalesce(p_to,'')));
    r_from numeric; r_to numeric; v_src text; v_asof date; v_fetched timestamptz; v_base text; v_stale boolean;
BEGIN
    IF a = '' OR b = '' THEN RETURN jsonb_build_object('available',false,'reason','missing_currency'); END IF;
    IF a = b THEN
        RETURN jsonb_build_object('available',true,'rate',1,'source','identity','stale',false,'path','identity');
    END IF;

    -- Newest (base, as_of) group that carries BOTH currencies (each as the base itself
    -- or as a quoted row). base_currency is constant within a group.
    SELECT base_currency, as_of INTO v_base, v_asof
    FROM public.fx_rates
    GROUP BY base_currency, as_of
    HAVING (bool_or(quote_currency = a) OR bool_or(base_currency = a))
       AND (bool_or(quote_currency = b) OR bool_or(base_currency = b))
    ORDER BY as_of DESC
    LIMIT 1;

    IF v_base IS NULL THEN RETURN jsonb_build_object('available',false,'reason','no_rate'); END IF;

    IF a = v_base THEN r_from := 1;
    ELSE SELECT rate INTO r_from FROM public.fx_rates WHERE base_currency=v_base AND quote_currency=a AND as_of=v_asof; END IF;
    IF b = v_base THEN r_to := 1;
    ELSE SELECT rate INTO r_to FROM public.fx_rates WHERE base_currency=v_base AND quote_currency=b AND as_of=v_asof; END IF;

    IF r_from IS NULL OR r_to IS NULL OR r_from = 0 THEN
        RETURN jsonb_build_object('available',false,'reason','no_rate');
    END IF;

    SELECT source, max(fetched_at) INTO v_src, v_fetched
    FROM public.fx_rates WHERE base_currency=v_base AND as_of=v_asof GROUP BY source ORDER BY max(fetched_at) DESC LIMIT 1;
    v_stale := (now() - v_fetched) > make_interval(hours => p_max_age_hours);

    RETURN jsonb_build_object(
        'available', true, 'rate', (r_to / r_from), 'source', v_src,
        'as_of', v_asof, 'fetched_at', v_fetched, 'stale', v_stale, 'path', v_base);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_global_market_intelligence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_gid uuid := public.fn_global_intelligence_uid(); v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(prod ORDER BY prod->>'title'),'[]'::jsonb) INTO v_out FROM (
    SELECT jsonb_build_object(
      'global_product_id', p.id,
      'product_identity', p.product_identity,
      'title', p.title,
      'category', p.category,
      'family_key', p.extended->>'product_family_key',
      'evidence', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'signal_type', s.signal_type, 'market', s.value->>'market',
                     'value', s.value, 'provenance', s.provenance, 'confidence', s.confidence,
                     'observed_at', s.observed_at, 'source_event_at', s.source_event_at)),'[]'::jsonb)
                   FROM public.commerce_signals s
                   WHERE s.product_id = p.id AND s.user_id = v_gid AND s.visibility='GLOBAL_SAFE'),
      'my_evaluation', (SELECT to_jsonb(e) FROM (
                     SELECT o.overall_score, o.opportunity_class, o.recommended_decision, o.factor_scores
                     FROM public.commerce_product_opportunities o
                     WHERE o.product_id = p.id AND o.user_id = v_uid LIMIT 1) e)
    ) AS prod
    FROM public.commerce_products p
    WHERE p.user_id = v_gid AND p.visibility='GLOBAL_SAFE' AND p.product_role='candidate'
  ) z;
  RETURN jsonb_build_object('status','ok','tenant', v_uid, 'global_products', v_out);
END; $function$
;

CREATE OR REPLACE FUNCTION public.get_member_marketing_context(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_dna    public.member_business_dna%ROWTYPE;
    v_run    uuid;
    v_result jsonb;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'no_context');
    END IF;

    SELECT * INTO v_dna FROM public.member_business_dna WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'no_context');
    END IF;
    v_run := v_dna.source_run_id;

    v_result := jsonb_build_object(
        'status', 'ok',
        'source_run_id', v_run,
        'business_dna', jsonb_build_object(
            'business_model', v_dna.business_model,
            'unique_value_prop', v_dna.unique_value_prop,
            'brand_positioning', v_dna.brand_positioning,
            'growth_stage', v_dna.growth_stage,
            'brand_voice', v_dna.brand_voice,
            'goals', coalesce(v_dna.goals, 'null'::jsonb),
            'extended', coalesce(v_dna.dna_extended, 'null'::jsonb)
        ),
        'icp', coalesce(v_dna.icp, 'null'::jsonb),
        'opportunities', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'rank', mo.rank, 'title', mo.title, 'summary', mo.summary,
                        'why_matters', mo.why_matters, 'why_now', mo.why_now,
                        'recommended_decision', mo.recommended_decision,
                        'business_relevance', mo.business_relevance, 'urgency', mo.urgency,
                        'evidence', coalesce(mo.evidence, '[]'::jsonb),
                        'content_reco', mo.content_reco, 'provenance', mo.provenance)
                    ORDER BY mo.rank NULLS LAST)
            FROM public.member_opportunities mo
            WHERE mo.user_id = p_user_id AND mo.source_run_id = v_run), '[]'::jsonb),
        'actions', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'action_type', a.action_type, 'title', a.title, 'detail', a.detail,
                        'rank', a.rank, 'status', a.status, 'provenance', a.provenance)
                    ORDER BY a.rank NULLS LAST)
            FROM public.member_actions a
            WHERE a.user_id = p_user_id AND a.source_run_id = v_run), '[]'::jsonb)
    );
    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status', 'error');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_own_business_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid          uuid := auth.uid();
    v_member_count integer;
    v_member_id    uuid;
    v_app          uuid;
    v_bp           public.business_profiles%ROWTYPE;
    v_ds_count     integer;
    v_ds_status    text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;

    -- Resolve member via UNIQUE(auth_user_id): count+min from ONE snapshot; no
    -- arbitrary/LIMIT selection; >1 is impossible and fails closed.
    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'business profile resolution cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    -- Resolve profile by UNIQUE(application_id). No claim, no lock, no mutation.
    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'profile_not_ready');
    END IF;

    -- Ownership: unclaimed (NULL) or own may be read; other-owner fails closed.
    IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
    END IF;

    -- Discovery status: EXACTLY one row required (never invent a default status).
    SELECT count(*), min(ds.status)
      INTO v_ds_count, v_ds_status
    FROM public.discovery_state AS ds
    WHERE ds.member_id = v_member_id;
    IF v_ds_count <> 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'status', 'ready',
        'discovery', v_ds_status,
        'profile', jsonb_build_object(
            'business_name', v_bp.business_name,
            'website', v_bp.website,
            'country', v_bp.country,
            'industry', v_bp.industry,
            'business_type', v_bp.business_type,
            'company_size', v_bp.company_size,
            'target_audience', v_bp.target_audience,
            'primary_goal', v_bp.primary_goal,
            'preferred_platforms', coalesce(v_bp.preferred_platforms, '[]'::jsonb),
            'competitors', coalesce(v_bp.competitors, '[]'::jsonb),
            'brief_frequency', v_bp.brief_frequency,
            'brand_voice', v_bp.brand_voice,
            'business_summary', v_bp.business_summary,
            'positioning_summary', v_bp.positioning_summary,
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Translate ANY internal fault (ownership, cardinality, drift) to the single
        -- non-enumerating result. No message/SQLSTATE/identifier is exposed.
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_own_discovery_intelligence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid            uuid := auth.uid();
    v_member_count   integer;
    v_member_id      uuid;
    v_app            uuid;
    v_ds_count       integer;
    v_analysis       text;
    v_profile_status text;
    v_bp             public.business_profiles%ROWTYPE;
    v_dna            public.member_business_dna%ROWTYPE;
    v_run            uuid;
    v_run_website    text;
    v_ident          jsonb;
    v_business_profile jsonb;
    v_business_dna   jsonb;
    v_icp            jsonb;
    v_radar          jsonb;
    v_decisions      jsonb;
    v_actions        jsonb;
    v_content        jsonb;
    v_commerce       jsonb := '[]'::jsonb;
    v_brief          jsonb;
    v_failure_reason text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;

    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'member cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(*), min(ds.analysis_status), min(ds.status)
      INTO v_ds_count, v_analysis, v_profile_status
    FROM public.discovery_state AS ds
    WHERE ds.member_id = v_member_id;
    IF v_ds_count <> 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    IF v_analysis = 'failed' THEN
        SELECT dr.error ->> 'detail' INTO v_failure_reason
        FROM public.discovery_runs AS dr
        WHERE dr.member_id = v_member_id AND dr.run_status = 'failed'
        ORDER BY dr.completed_at DESC NULLS LAST, dr.created_at DESC
        LIMIT 1;
        IF v_failure_reason IS NULL OR v_failure_reason NOT IN
           ('INVALID_URL','DOMAIN_NOT_FOUND','SITE_UNREACHABLE','REDIRECT_BLOCKED',
            'REDIRECT_LIMIT','TIMEOUT','FETCH_BLOCKED','INSUFFICIENT_CONTENT','ANALYSIS_FAILED') THEN
            v_failure_reason := 'TEMPORARY_FAILURE';
        END IF;
    END IF;

    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app;
    IF FOUND THEN
        IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
            RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
        END IF;
        v_business_profile := jsonb_build_object(
            'business_name', v_bp.business_name, 'website', v_bp.website, 'country', v_bp.country,
            'industry', v_bp.industry, 'business_type', v_bp.business_type, 'company_size', v_bp.company_size,
            'target_audience', v_bp.target_audience, 'primary_goal', v_bp.primary_goal,
            'business_summary', v_bp.business_summary, 'positioning_summary', v_bp.positioning_summary,
            'brand_voice', v_bp.brand_voice,
            'preferred_platforms', coalesce(v_bp.preferred_platforms, '[]'::jsonb),
            'competitors', coalesce(v_bp.competitors, '[]'::jsonb),
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        );
    ELSE
        v_business_profile := 'null'::jsonb;
    END IF;

    SELECT * INTO v_dna
    FROM public.member_business_dna
    WHERE user_id = v_uid;
    IF FOUND THEN
        v_run := v_dna.source_run_id;
        v_business_dna := jsonb_build_object(
            'business_model', v_dna.business_model, 'unique_value_prop', v_dna.unique_value_prop,
            'brand_positioning', v_dna.brand_positioning, 'growth_stage', v_dna.growth_stage,
            'brand_voice', v_dna.brand_voice, 'goals', coalesce(v_dna.goals, 'null'::jsonb),
            'extended', coalesce(v_dna.dna_extended, 'null'::jsonb), 'provenance', v_dna.provenance
        );
        v_icp := coalesce(v_dna.icp, 'null'::jsonb);
    ELSE
        v_business_dna := 'null'::jsonb;
        v_icp := 'null'::jsonb;
    END IF;

    SELECT dr.website INTO v_run_website
    FROM public.discovery_runs AS dr
    WHERE dr.member_id = v_member_id AND dr.website IS NOT NULL
    ORDER BY (dr.id = v_run) DESC, dr.created_at DESC
    LIMIT 1;
    IF v_run_website IS NOT NULL
       AND jsonb_typeof(v_business_profile) = 'object'
       AND (v_business_profile ->> 'website') IS NULL THEN
        v_business_profile := jsonb_set(v_business_profile, '{website}', to_jsonb(v_run_website));
    END IF;

    IF jsonb_typeof(v_business_profile) = 'object'
       AND v_dna.dna_extended IS NOT NULL
       AND jsonb_typeof(v_dna.dna_extended -> 'identity') = 'object' THEN
        v_ident := v_dna.dna_extended -> 'identity';
        IF nullif(btrim(coalesce(v_ident ->> 'name','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{business_name}', to_jsonb(v_ident ->> 'name'));
        END IF;
        IF nullif(btrim(coalesce(v_ident ->> 'industry','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{industry}', to_jsonb(v_ident ->> 'industry'));
        END IF;
        IF nullif(btrim(coalesce(v_ident ->> 'geography','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{country}', to_jsonb(v_ident ->> 'geography'));
        END IF;
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'source', CASE WHEN mo.opportunity_id IS NOT NULL THEN 'global' ELSE 'business_specific' END,
                'rank', mo.rank,
                'title', coalesce(o.title, mo.title),
                'summary', mo.summary,
                'opportunity_score', coalesce(mo.personalized_opportunity_score, o.opportunity_score),
                'confidence_score', coalesce(mo.confidence, o.confidence_score),
                'business_relevance', mo.business_relevance,
                'urgency', mo.urgency,
                'status', mo.status,
                'provenance', mo.provenance
            ) ORDER BY mo.rank NULLS LAST, mo.created_at), '[]'::jsonb)
      INTO v_radar
    FROM public.member_opportunities AS mo
    LEFT JOIN public.opportunities AS o ON o.id = mo.opportunity_id
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'rank', mo.rank,
                'title', coalesce(mo.title, (SELECT o2.title FROM public.opportunities o2 WHERE o2.id = mo.opportunity_id)),
                'why_matters', mo.why_matters,
                'why_now', mo.why_now,
                'business_relevance', mo.business_relevance,
                'recommended_decision', mo.recommended_decision,
                'evidence', coalesce(mo.evidence, '[]'::jsonb),
                'provenance', mo.provenance
            ) ORDER BY mo.rank NULLS LAST), '[]'::jsonb)
      INTO v_decisions
    FROM public.member_opportunities AS mo
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'rank', mo.rank,
                'content_reco', mo.content_reco
            ) ORDER BY mo.rank NULLS LAST) FILTER (WHERE mo.content_reco IS NOT NULL), '[]'::jsonb)
      INTO v_content
    FROM public.member_opportunities AS mo
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    v_actions := jsonb_build_object(
        'quick_wins', coalesce((
            SELECT jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'rank', a.rank, 'status', a.status, 'provenance', a.provenance)
                    ORDER BY a.rank NULLS LAST)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'quick_win'), '[]'::jsonb),
        'next_stage', coalesce((
            SELECT jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'rank', a.rank, 'status', a.status, 'provenance', a.provenance)
                    ORDER BY a.rank NULLS LAST)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'next_stage'), '[]'::jsonb),
        'next_best_move', (
            SELECT jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'status', a.status, 'provenance', a.provenance)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'next_best_move'
            ORDER BY a.rank NULLS LAST
            LIMIT 1)
    );

    -- Deterministic commerce opportunities (ECOM-005B). Own tenant + run only.
    -- Nested guard: any failure here yields [] and never breaks the response.
    BEGIN
        IF v_run IS NOT NULL THEN
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'rank', o.rank,
                        'product_id', o.product_id,
                        'product_title', cp.title,
                        'category', cp.category,
                        'product_url', cp.product_url,
                        'source_store', cp.source_store,
                        'observed_price', cp.observed_price,
                        'currency', cp.price_currency,
                        'availability', cp.availability,
                        'opportunity_class', o.opportunity_class,
                        'overall_score', o.overall_score,
                        'confidence', o.confidence,
                        'recommended_decision', o.recommended_decision,
                        'why_this_product', o.why_this_product,
                        'why_now', o.why_now,
                        'positive_factors', coalesce(o.positive_factors, '[]'::jsonb),
                        'risk_factors', coalesce(o.risk_factors, '[]'::jsonb),
                        'factor_scores', coalesce(o.factor_scores, '{}'::jsonb),
                        'evidence', coalesce(o.evidence_refs, '[]'::jsonb),
                        'recommended_actions', coalesce(o.recommended_actions, '[]'::jsonb),
                        'content_context', coalesce(o.content_context, '{}'::jsonb),
                        'provenance', o.provenance,
                        'scoring_version', o.scoring_version
                    ) ORDER BY o.rank NULLS LAST, o.overall_score DESC NULLS LAST), '[]'::jsonb)
              INTO v_commerce
            FROM public.commerce_product_opportunities AS o
            JOIN public.commerce_products AS cp ON cp.id = o.product_id
            WHERE o.user_id = v_uid AND o.source_run_id = v_run;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_commerce := '[]'::jsonb;
    END;

    SELECT to_jsonb(db) INTO v_brief
    FROM (
        SELECT b.date, b.brief_json, b.top_opportunities, b.generated_at
        FROM public.daily_briefs AS b
        WHERE b.user_id = v_uid
        ORDER BY b.date DESC NULLS LAST, b.generated_at DESC NULLS LAST
        LIMIT 1
    ) AS db;

    RETURN jsonb_build_object(
        'status', 'ok',
        'analysis_status', v_analysis,
        'failure_reason', v_failure_reason,
        'profile_completion_status', v_profile_status,
        'business_profile', v_business_profile,
        'business_dna', v_business_dna,
        'icp', v_icp,
        'opportunity_radar', v_radar,
        'decision_intelligence', v_decisions,
        'action_intelligence', v_actions,
        'content_intelligence', v_content,
        'commerce_opportunities', v_commerce,
        'morning_brief', coalesce(v_brief, 'null'::jsonb),
        'provenance_vocabulary', jsonb_build_array('OBSERVED', 'INFERRED', 'RESEARCHED', 'EXISTING_PULSE')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_own_generated_content()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_run uuid; v_items jsonb;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT source_run_id INTO v_run FROM public.member_business_dna WHERE user_id = v_uid;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'content_id', c.id, 'rank', c.rank, 'content_type', c.content_type, 'platform', c.platform,
        'status', c.status, 'content', c.content, 'created_at', c.created_at, 'completed_at', c.completed_at
    ) ORDER BY c.created_at DESC), '[]'::jsonb) INTO v_items
    FROM public.member_generated_content c
    WHERE c.user_id = v_uid AND (v_run IS NULL OR c.source_run_id = v_run);
    RETURN jsonb_build_object('status','ok','content', v_items);
END; $function$
;

CREATE OR REPLACE FUNCTION public.get_own_marketing_campaign_drafts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated', 'drafts', '[]'::jsonb);
    END IF;
    RETURN jsonb_build_object(
        'status', 'ok',
        'drafts', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'id', d.id, 'website', d.website, 'status', d.status,
                        'lifecycle', d.lifecycle, 'business_context', d.business_context,
                        'canonical_campaign', d.canonical_campaign,
                        'platform_payloads', d.platform_payloads,
                        'creative_specs', d.creative_specs, 'brand_assets', d.brand_assets,
                        'preview_payload', d.preview_payload, 'review_payload', d.review_payload,
                        'performance_schema', d.performance_schema,
                        'created_at', d.created_at, 'updated_at', d.updated_at)
                    ORDER BY d.created_at DESC)
            FROM public.marketing_campaign_drafts d
            WHERE d.user_id = v_uid), '[]'::jsonb)
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_own_product_acquisitions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_items jsonb;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'acquisition_id', a.id, 'state', a.state, 'state_reason', a.state_reason,
        'source_run_id', a.source_run_id,
        'winning_product', a.winning_product_snapshot,
        'selected_supplier', a.selected_supplier_snapshot,
        'sourcing_spec', a.sourcing_spec_snapshot,
        'prepared_package', a.prepared_package,
        'generated_content_id', a.generated_content_id,
        'missing_information', a.missing_information,
        'approved_at', a.approved_at,
        'created_at', a.created_at, 'updated_at', a.updated_at
    ) ORDER BY a.created_at DESC), '[]'::jsonb) INTO v_items
    FROM public.product_acquisitions a
    WHERE a.user_id = v_uid;
    RETURN jsonb_build_object('status','ok','acquisitions', v_items);
END; $function$
;

CREATE OR REPLACE FUNCTION public.ingest_advertising_activity(p_user_id uuid, p_source_run_id uuid, p_entity jsonb, p_ads jsonb, p_market text DEFAULT 'UNKNOWN'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_res jsonb; v_pid uuid; v_uid uuid := p_user_id;
  v_matched jsonb; v_active int; v_advertisers int; v_maxdays int; v_sat jsonb;
  v_patterns jsonb; v_conf numeric; v_dedup text; v_adv_sig jsonb; v_comp_sig jsonb;
BEGIN
  v_res := public.resolve_product_entity(p_entity);
  IF (v_res->>'verdict') <> 'ACCEPT' THEN
    RETURN jsonb_build_object('status','skipped','verdict', v_res->>'verdict','reasons', v_res->'reasons');
  END IF;
  v_pid := (public.ingest_commerce_product(v_uid, p_source_run_id, v_res->'product_ready','INFERRED','candidate'))->>'product_id';
  IF v_pid IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;

  -- classify + keep matched (EXACT_OR_CLOSE / RELATED); store references + patterns, not verbatim creative
  SELECT jsonb_agg(jsonb_build_object(
           'ad_id', a->>'id', 'page_name', a->>'page_name', 'page_id', a->>'page_id',
           'ad_snapshot_url', a->>'ad_snapshot_url',
           'match', (public.fn_classify_ad_product_match(v_res->>'normalized_name', a->>'ad_text', a->>'page_name')->>'match'),
           'longevity', public.fn_ad_days_active((a->>'ad_delivery_start_time')::timestamptz, nullif(a->>'ad_delivery_stop_time','')::timestamptz),
           'creative_pattern', public.fn_classify_ad_creative_pattern(a->>'ad_text'),
           'platforms', a->'publisher_platforms',
           'provenance','OBSERVED'))
    INTO v_matched
    FROM jsonb_array_elements(coalesce(p_ads,'[]'::jsonb)) a
    WHERE (public.fn_classify_ad_product_match(v_res->>'normalized_name', a->>'ad_text', a->>'page_name')->>'match')
          IN ('EXACT_OR_CLOSE_MATCH','RELATED');
  v_matched := coalesce(v_matched,'[]'::jsonb);

  v_active := jsonb_array_length(v_matched);
  SELECT count(DISTINCT (e->>'page_id')) INTO v_advertisers FROM jsonb_array_elements(v_matched) e WHERE e->>'page_id' IS NOT NULL;
  SELECT max((e->'longevity'->>'days_observed_active')::int) INTO v_maxdays FROM jsonb_array_elements(v_matched) e;
  v_sat := public.fn_ad_saturation(v_active, v_advertisers);
  SELECT jsonb_object_agg(pat, cnt) INTO v_patterns FROM (
    SELECT e->>'creative_pattern' pat, count(*) cnt FROM jsonb_array_elements(v_matched) e GROUP BY 1) z;
  v_conf := least(0.80, 0.30 + least(0.30, v_active*0.05) + least(0.20, coalesce(v_advertisers,0)*0.05));
  v_dedup := 'meta:'||coalesce(v_res->>'product_family_key','')||':'||p_market;

  v_adv_sig := public.ingest_commerce_signal(
    v_uid, v_pid, p_source_run_id, 'ADVERTISING_ACTIVITY',
    jsonb_build_object('source_platform','meta_ad_library','market',p_market,
      'matched_active_ads', v_active, 'advertiser_count', coalesce(v_advertisers,0),
      'max_days_active', v_maxdays, 'saturation', v_sat, 'creative_patterns', coalesce(v_patterns,'{}'::jsonb),
      'note','advertising presence observed — NOT sales/revenue/ROAS/conversion'),
    (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'claim','Observed Meta ad for this product ('||p_market||') by '||coalesce(e->>'page_name','advertiser'),
        'ad_id', e->>'ad_id','ad_snapshot_url', e->>'ad_snapshot_url','match', e->>'match',
        'days_active', e->'longevity'->>'days_observed_active','creative_pattern', e->>'creative_pattern',
        'source_name','meta_ad_library','provenance','PLATFORM_REPORTED')),'[]'::jsonb)
     FROM jsonb_array_elements(v_matched) e),
    'PLATFORM_REPORTED', v_conf, now(), NULL, v_dedup||':advertising_activity');

  v_comp_sig := public.ingest_commerce_signal(
    v_uid, v_pid, p_source_run_id, 'COMPETITOR_ACTIVITY',
    jsonb_build_object('source_platform','meta_ad_library','market',p_market,
      'advertiser_diversity', coalesce(v_advertisers,0),'active_relevant_ads', v_active,
      'offer_patterns', coalesce(v_patterns,'{}'::jsonb),'saturation', v_sat,
      'note','derived competitive indicator — INFERRED, not demand/sales'),
    jsonb_build_array(jsonb_build_object('claim','Derived competitor advertising indicators for '||p_market,
      'source_name','meta_ad_library','provenance','INFERRED')),
    'INFERRED', v_conf, now(), NULL, v_dedup||':competitor_activity');

  RETURN jsonb_build_object('status','ok','verdict','ACCEPT','product_id',v_pid,
    'product_family_key', v_res->>'product_family_key','matched_active_ads',v_active,
    'advertiser_count',coalesce(v_advertisers,0),'saturation', v_sat->>'class',
    'advertising_signal', v_adv_sig->>'status','competitor_signal', v_comp_sig->>'status');
END; $function$
;

CREATE OR REPLACE FUNCTION public.ingest_cj_global_product(p_source_product_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_sup public.commerce_supplier_products%rowtype; v_material text; v_res jsonb;
BEGIN
  SELECT * INTO v_sup FROM public.commerce_supplier_products WHERE source_product_id = p_source_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cj_product_not_found'); END IF;
  v_material := lower(coalesce(v_sup.raw->'materialKeySet'->>0, v_sup.raw->>'materialKey',''));
  v_res := public.ingest_commerce_product(
    public.fn_global_intelligence_uid(), NULL,
    jsonb_build_object(
      'title', v_sup.title, 'platform_id', v_sup.source_product_id, 'source_store', 'cjdropshipping',
      'product_type', v_sup.category, 'category', v_sup.category, 'provenance', 'PLATFORM_REPORTED',
      'cj_source_product_id', v_sup.source_product_id, 'material', nullif(v_material,'')),
    'PLATFORM_REPORTED', 'candidate');
  RETURN v_res;
END; $function$
;

CREATE OR REPLACE FUNCTION public.ingest_cj_supplier_products(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE it jsonb; v_n int := 0; v_pid text; v_ct bigint;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('status','invalid_input','ingested',0);
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := nullif(btrim(coalesce(it->>'source_product_id','')),'');
    IF v_pid IS NULL THEN CONTINUE; END IF;
    v_ct := CASE WHEN (it->>'source_created_at') ~ '^[0-9]+$' THEN (it->>'source_created_at')::bigint ELSE NULL END;

    INSERT INTO public.commerce_supplier_products
      (source, source_product_id, sku, title, title_original, image_url, category,
       supplier_cost, cost_currency, weight_grams, is_free_shipping, shipping_country_codes,
       listing_count, listed_num, sale_status, supplier_id, supplier_name, product_url,
       source_created_at, provenance, raw, last_seen_at)
    VALUES (
      coalesce(nullif(btrim(it->>'source'),''),'cjdropshipping'), v_pid,
      nullif(btrim(it->>'sku'),''), nullif(btrim(it->>'title'),''), nullif(btrim(it->>'title_original'),''),
      nullif(btrim(it->>'image_url'),''), nullif(btrim(it->>'category'),''),
      CASE WHEN (it->>'supplier_cost') ~ '^[0-9]+(\.[0-9]+)?$' THEN (it->>'supplier_cost')::numeric ELSE NULL END,
      coalesce(nullif(btrim(it->>'cost_currency'),''),'USD'),
      CASE WHEN (it->>'weight_grams') ~ '^[0-9]+(\.[0-9]+)?$' THEN (it->>'weight_grams')::numeric ELSE NULL END,
      CASE WHEN it->>'is_free_shipping' = 'true' THEN true WHEN it->>'is_free_shipping' = 'false' THEN false ELSE NULL END,
      CASE WHEN jsonb_typeof(it->'shipping_country_codes')='array' THEN it->'shipping_country_codes' ELSE '[]'::jsonb END,
      CASE WHEN (it->>'listing_count') ~ '^[0-9]+$' THEN (it->>'listing_count')::int ELSE NULL END,
      CASE WHEN (it->>'listed_num') ~ '^[0-9]+$' THEN (it->>'listed_num')::int ELSE NULL END,
      nullif(btrim(it->>'sale_status'),''), nullif(btrim(it->>'supplier_id'),''), nullif(btrim(it->>'supplier_name'),''),
      nullif(btrim(it->>'product_url'),''),
      CASE WHEN v_ct IS NOT NULL THEN to_timestamp(v_ct/1000.0) ELSE NULL END,
      jsonb_build_object('identity','OBSERVED','supplier_cost','PLATFORM_REPORTED',
                         'listing_counts','PLATFORM_REPORTED','shipping','PLATFORM_REPORTED'),
      CASE WHEN jsonb_typeof(it->'raw')='object' THEN it->'raw' ELSE it END,
      now())
    ON CONFLICT (source, source_product_id) DO UPDATE SET
      sku=excluded.sku, title=excluded.title, title_original=excluded.title_original,
      image_url=excluded.image_url, category=excluded.category, supplier_cost=excluded.supplier_cost,
      cost_currency=excluded.cost_currency, weight_grams=excluded.weight_grams,
      is_free_shipping=excluded.is_free_shipping, shipping_country_codes=excluded.shipping_country_codes,
      listing_count=excluded.listing_count, listed_num=excluded.listed_num, sale_status=excluded.sale_status,
      supplier_id=excluded.supplier_id, supplier_name=excluded.supplier_name, product_url=excluded.product_url,
      source_created_at=excluded.source_created_at, provenance=excluded.provenance, raw=excluded.raw,
      last_seen_at=now();
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('status','ok','ingested',v_n);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_commerce_product(p_user_id uuid, p_source_run_id uuid, p_product jsonb, p_provenance text DEFAULT 'OBSERVED'::text, p_product_role text DEFAULT 'own'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_url text := nullif(btrim(coalesce(p_product->>'product_url','')),'');
  v_pid text := nullif(btrim(coalesce(p_product->>'handle', p_product->>'platform_id','')),'');
  v_title text := nullif(btrim(coalesce(p_product->>'title','')),'');
  v_source text := nullif(btrim(coalesce(p_product->>'source_store', p_product->>'vendor','')),'');
  v_role text := CASE WHEN lower(coalesce(p_product_role,'own')) IN ('competitor','candidate')
                      THEN lower(p_product_role) ELSE 'own' END;
  v_ident jsonb; v_price numeric; v_id uuid;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','missing_user'); END IF;
  IF jsonb_typeof(p_product) IS DISTINCT FROM 'object' THEN RETURN jsonb_build_object('status','invalid_product'); END IF;
  v_ident := public.fn_commerce_product_identity(v_url, v_pid, v_title, v_source);
  IF v_ident IS NULL THEN RETURN jsonb_build_object('status','no_identity'); END IF;
  v_price := CASE WHEN (p_product->>'observed_price') ~ '^[0-9]+(\.[0-9]+)?$' THEN (p_product->>'observed_price')::numeric
                  WHEN (p_product->>'price_min') ~ '^[0-9]+(\.[0-9]+)?$' THEN (p_product->>'price_min')::numeric ELSE NULL END;

  INSERT INTO public.commerce_products
    (user_id, source_run_id, product_identity, identity_basis, title, product_url, source_store,
     category, description, observed_price, price_currency, availability, provenance, extended,
     product_role, competitor_source)
  VALUES
    (p_user_id, p_source_run_id,
     CASE v_role WHEN 'competitor' THEN 'competitor:'||(v_ident->>'identity')
                 WHEN 'candidate'  THEN 'candidate:'||(v_ident->>'identity')
                 ELSE v_ident->>'identity' END,
     v_ident->>'basis', v_title, v_url, v_source,
     nullif(btrim(coalesce(p_product->>'product_type','')),''),
     nullif(btrim(coalesce(p_product->>'description', p_product->>'positioning','')),''),
     v_price, nullif(btrim(coalesce(p_product->>'currency','')),''),
     nullif(btrim(coalesce(p_product->>'availability_signal', p_product->>'availability','')),''),
     jsonb_build_object('product', coalesce(nullif(btrim(coalesce(p_product->>'provenance','')),''), p_provenance)),
     (p_product - 'title' - 'product_url' - 'description'),
     v_role, nullif(btrim(coalesce(p_product->>'competitor_source', p_product->>'source_store','')),''))
  ON CONFLICT (user_id, product_identity) DO UPDATE SET
     source_run_id=excluded.source_run_id, title=coalesce(excluded.title, public.commerce_products.title),
     product_url=coalesce(excluded.product_url, public.commerce_products.product_url),
     source_store=coalesce(excluded.source_store, public.commerce_products.source_store),
     category=coalesce(excluded.category, public.commerce_products.category),
     description=coalesce(excluded.description, public.commerce_products.description),
     observed_price=coalesce(excluded.observed_price, public.commerce_products.observed_price),
     price_currency=coalesce(excluded.price_currency, public.commerce_products.price_currency),
     availability=coalesce(excluded.availability, public.commerce_products.availability),
     provenance=excluded.provenance, extended=excluded.extended,
     product_role=excluded.product_role, competitor_source=excluded.competitor_source,
     last_observed_at=now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','ok','product_id', v_id, 'role', v_role, 'identity', (SELECT product_identity FROM public.commerce_products WHERE id=v_id));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_commerce_signal(p_user_id uuid, p_product_id uuid, p_source_run_id uuid, p_signal_type text, p_value jsonb, p_evidence jsonb, p_provenance text, p_confidence numeric, p_observed_at timestamp with time zone, p_source_event_at timestamp with time zone, p_dedup_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_id uuid; v_owner uuid;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','missing_user'); END IF;
  IF nullif(btrim(coalesce(p_signal_type,'')),'') IS NULL THEN RETURN jsonb_build_object('status','missing_signal_type'); END IF;
  IF nullif(btrim(coalesce(p_dedup_key,'')),'') IS NULL THEN RETURN jsonb_build_object('status','missing_dedup_key'); END IF;
  -- If bound to a product, that product must belong to the same tenant (no cross-tenant linkage).
  IF p_product_id IS NOT NULL THEN
    SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
    IF v_owner IS DISTINCT FROM p_user_id THEN RETURN jsonb_build_object('status','product_tenant_mismatch'); END IF;
  END IF;

  INSERT INTO public.commerce_signals
    (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, confidence,
     observed_at, source_event_at, dedup_key)
  VALUES
    (p_user_id, p_product_id, p_source_run_id, p_signal_type,
     CASE WHEN jsonb_typeof(p_value) = 'object' THEN p_value ELSE NULL END,
     CASE WHEN jsonb_typeof(p_evidence) = 'array' THEN p_evidence ELSE '[]'::jsonb END,
     jsonb_build_object('signal', coalesce(nullif(btrim(coalesce(p_provenance,'')),''), 'OBSERVED')),
     p_confidence,
     coalesce(p_observed_at, now()),
     p_source_event_at,
     p_dedup_key)
  ON CONFLICT (user_id, dedup_key) DO UPDATE SET
     product_id      = excluded.product_id,
     source_run_id   = excluded.source_run_id,
     value           = excluded.value,
     evidence        = excluded.evidence,
     provenance      = excluded.provenance,
     confidence      = excluded.confidence,
     observed_at     = excluded.observed_at,
     source_event_at = excluded.source_event_at
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','ok','signal_id', v_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_fx_rates(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_base text; v_source text; v_asof date; v_rec record; v_n int := 0;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload->'rates') <> 'object' THEN
        RETURN jsonb_build_object('status','error','error','invalid_payload');
    END IF;
    v_base := upper(coalesce(p_payload->>'base',''));
    v_source := coalesce(nullif(p_payload->>'source',''),'unknown');
    v_asof := coalesce(nullif(p_payload->>'as_of','')::date, current_date);
    IF v_base = '' THEN RETURN jsonb_build_object('status','error','error','missing_base'); END IF;

    FOR v_rec IN SELECT key, value FROM jsonb_each(p_payload->'rates') LOOP
        INSERT INTO public.fx_rates (base_currency, quote_currency, rate, source, as_of, fetched_at)
        VALUES (v_base, upper(v_rec.key), (v_rec.value)::text::numeric, v_source, v_asof, now())
        ON CONFLICT (base_currency, quote_currency, as_of)
        DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source, fetched_at = now();
        v_n := v_n + 1;
    END LOOP;
    RETURN jsonb_build_object('status','ok','base',v_base,'as_of',v_asof,'count',v_n);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('status','error','error','ingest_failed','detail',SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_reddit_product_attention(p_user_id uuid, p_source_run_id uuid, p_entity jsonb, p_evidence jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_res jsonb; v_pid uuid; v_conf numeric;
  v_subreddit text; v_url text; v_market text; v_ctx text;
  v_intent boolean; v_reco boolean; v_sig jsonb; v_dedup text; v_seat timestamptz;
BEGIN
  v_res := public.resolve_product_entity(p_entity);
  IF (v_res->>'verdict') <> 'ACCEPT' THEN
    RETURN jsonb_build_object('status','skipped','verdict', v_res->>'verdict','reasons', v_res->'reasons');
  END IF;

  -- Community-attention: the reddit discussion URL is NOT a product URL and must not drive
  -- product identity. Strip it so identity falls back to the normalized name (one canonical
  -- product per generic concept). The discussion URL is preserved in the signal evidence below.
  v_pid := (public.ingest_commerce_product(p_user_id, p_source_run_id,
             (v_res->'product_ready') - 'product_url' - 'source_reference', v_res->>'provenance','candidate'))->>'product_id';
  IF v_pid IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;

  v_subreddit := nullif(btrim(p_evidence->>'subreddit'),'');
  v_url       := nullif(btrim(p_evidence->>'source_reference'),'');
  v_market    := coalesce(nullif(btrim(p_evidence->>'market'),''), 'GLOBAL');
  v_ctx       := nullif(btrim(p_evidence->>'mention_context'),'');
  v_intent    := coalesce((p_evidence->>'purchase_intent')::boolean, false);
  v_reco      := coalesce((p_evidence->>'recommendation')::boolean, false);
  v_seat      := nullif(btrim(p_evidence->>'source_event_at'),'')::timestamptz;
  v_conf := least(0.80, 0.30 + (CASE WHEN v_intent THEN 0.25 ELSE 0 END) + (CASE WHEN v_reco THEN 0.15 ELSE 0 END));
  v_dedup := 'reddit:'||coalesce(nullif(btrim(p_evidence->>'post_id'),''), md5(coalesce(v_url,v_ctx,'')))
             ||':'||coalesce(v_res->>'product_family_key','')||':community_attention';

  v_sig := public.ingest_commerce_signal(
    p_user_id, v_pid, p_source_run_id, 'COMMUNITY_ATTENTION',
    jsonb_build_object('source_platform','reddit','subreddit',v_subreddit,'market',v_market,
      'attention_basis','single_community_mention',
      'intent_indicators', jsonb_build_object('purchase_intent', v_intent, 'recommendation', v_reco),
      'mention_context', left(coalesce(v_ctx,''),300)),
    jsonb_build_array(jsonb_build_object(
      'claim', 'Observed community discussion on reddit'||coalesce(' in r/'||v_subreddit,'')||' mentioning this product',
      'source_name','reddit','source_reference', v_url,
      'signal_type','community_discussion','provenance','OBSERVED')),
    'INFERRED', v_conf, now(), v_seat, v_dedup);

  RETURN jsonb_build_object('status', v_sig->>'status', 'verdict','ACCEPT',
    'product_id', v_pid, 'product_family_key', v_res->>'product_family_key',
    'confidence', v_conf, 'signal', v_sig);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_resolved_product_entity(p_user_id uuid, p_source_run_id uuid, p_entity jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_res jsonb;
  v_ing jsonb;
BEGIN
  v_res := public.resolve_product_entity(p_entity);
  IF (v_res->>'verdict') <> 'ACCEPT' THEN
    RETURN jsonb_build_object('status','skipped','verdict', v_res->>'verdict', 'reasons', v_res->'reasons');
  END IF;
  v_ing := public.ingest_commerce_product(p_user_id, p_source_run_id,
             v_res->'product_ready', v_res->>'provenance', 'candidate');
  RETURN jsonb_build_object('status', v_ing->>'status', 'verdict','ACCEPT',
    'product_id', v_ing->'product_id', 'identity', v_ing->'identity',
    'product_family_key', v_res->>'product_family_key');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_search_demand(p_user_id uuid, p_source_run_id uuid, p_entity jsonb, p_demand jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_res jsonb; v_pid uuid; v_market text; v_lang text; v_source text; v_ref text;
  v_primary jsonb; v_exact int; v_range text; v_comp text; v_compidx numeric;
  v_hist jsonb; v_season jsonb; v_momentum jsonb; v_conf numeric; v_dedup text; v_sig jsonb;
  v_evidence jsonb;
BEGIN
  v_res := public.resolve_product_entity(p_entity);
  IF (v_res->>'verdict') <> 'ACCEPT' THEN
    RETURN jsonb_build_object('status','skipped','verdict', v_res->>'verdict','reasons', v_res->'reasons');
  END IF;
  v_pid := (public.ingest_commerce_product(p_user_id, p_source_run_id, v_res->'product_ready', 'INFERRED','candidate'))->>'product_id';
  IF v_pid IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;

  v_market := coalesce(nullif(btrim(p_demand->>'market'),''),'UNKNOWN');
  v_lang   := coalesce(nullif(btrim(p_demand->>'language'),''),'und');
  v_source := coalesce(nullif(btrim(p_demand->>'source'),''),'google_ads_keyword_planner');
  v_ref    := nullif(btrim(p_demand->>'source_reference'),'');

  -- primary = first DIRECT_PRODUCT query (fall back to first query)
  SELECT e INTO v_primary FROM jsonb_array_elements(coalesce(p_demand->'queries','[]'::jsonb)) e
    WHERE e->>'relevance' = 'DIRECT_PRODUCT' LIMIT 1;
  IF v_primary IS NULL THEN
    SELECT e INTO v_primary FROM jsonb_array_elements(coalesce(p_demand->'queries','[]'::jsonb)) e LIMIT 1;
  END IF;

  v_exact := CASE WHEN (v_primary->>'avg_monthly_searches') ~ '^[0-9]+$' THEN (v_primary->>'avg_monthly_searches')::int ELSE NULL END;
  v_range := nullif(btrim(v_primary->>'volume_range'),'');   -- e.g. '1K-10K' kept verbatim, never invented as exact
  v_comp  := nullif(btrim(v_primary->>'competition'),'');
  v_compidx := CASE WHEN (v_primary->>'competition_index') ~ '^[0-9]+(\.[0-9]+)?$' THEN (v_primary->>'competition_index')::numeric ELSE NULL END;
  v_hist  := v_primary->'monthly_history';
  v_season := public.fn_classify_seasonality(v_hist);
  v_momentum := public.fn_search_momentum(v_hist);

  v_conf := least(0.80, 0.40 + (CASE WHEN v_exact IS NOT NULL THEN 0.20 ELSE 0 END)
                              + (CASE WHEN jsonb_typeof(v_hist)='array' AND jsonb_array_length(v_hist) >= 6 THEN 0.20 ELSE 0 END));
  v_dedup := 'search:'||coalesce(v_res->>'product_family_key','')||':'||v_market||':search_demand';

  -- Evidence: every query, its relevance and its verbatim platform-reported volume (exact OR range).
  SELECT jsonb_agg(jsonb_build_object(
           'claim','Platform-reported Google search metric for query "'||(e->>'query')||'" ('||v_market||')',
           'query', e->>'query', 'relevance', e->>'relevance',
           'avg_monthly_searches', CASE WHEN (e->>'avg_monthly_searches') ~ '^[0-9]+$' THEN (e->>'avg_monthly_searches')::int ELSE NULL END,
           'volume_range', nullif(btrim(e->>'volume_range'),''),
           'competition', nullif(btrim(e->>'competition'),''),
           'source_name', v_source, 'source_reference', v_ref, 'provenance','PLATFORM_REPORTED'))
    INTO v_evidence
    FROM jsonb_array_elements(coalesce(p_demand->'queries','[]'::jsonb)) e;

  v_sig := public.ingest_commerce_signal(
    p_user_id, v_pid, p_source_run_id, 'SEARCH_DEMAND',
    jsonb_strip_nulls(jsonb_build_object(
      'source_platform', v_source, 'market', v_market, 'language', v_lang,
      'headline_query', v_primary->>'query',
      'avg_monthly_searches_exact', v_exact,   -- null when platform only gave a range
      'volume_range', v_range,                  -- verbatim platform bucket when exact absent
      'competition', v_comp, 'competition_index', v_compidx,
      'seasonality', v_season, 'search_momentum', v_momentum,
      'query_count', jsonb_array_length(coalesce(p_demand->'queries','[]'::jsonb)),
      'note','listing/search interest only — NOT sales/revenue/conversion')),
    coalesce(v_evidence,'[]'::jsonb),
    'PLATFORM_REPORTED', v_conf, now(), NULL, v_dedup);

  RETURN jsonb_build_object('status', v_sig->>'status', 'verdict','ACCEPT', 'product_id', v_pid,
    'product_family_key', v_res->>'product_family_key', 'market', v_market,
    'seasonality', v_season->>'class', 'momentum', v_momentum->>'direction', 'confidence', v_conf);
END; $function$
;

CREATE OR REPLACE FUNCTION public.issue_invitation(p_application_ref uuid, p_bound_email text, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_email        text;
    v_now          timestamptz;
    v_active_id    uuid;
    v_active_exp   timestamptz;
    v_active_live  boolean := false;
    v_fa_count     integer;
    v_bp_count     integer;
    v_bp_owner     uuid;
    v_member_count integer;
    v_ds_count     integer;
    v_prior_count  integer;
    v_rows         integer;
    v_new_id       uuid;
    v_outcome      text;
BEGIN
    -- 1. Required application reference.
    IF p_application_ref IS NULL THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 2. Frozen stored-hash representation (U2/D04: exactly 64 lowercase-hex chars).
    IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 3. Canonical email (single rule: lower(btrim)); reject blank; minimal, non-
    --    conflicting structural/length floor (does not relax the downstream
    --    lower(btrim) acceptance comparison; only rejects structurally impossible
    --    bound emails so they are never stored).
    v_email := lower(btrim(coalesce(p_bound_email, '')));
    IF v_email = ''
       OR length(v_email) > 254
       OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    v_now := now();

    -- 4. Serialise ISSUANCE for this application (transaction advisory lock). Safe
    --    when zero predecessor invitation rows exist.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_application_ref::text, 0));

    -- 5. CROSS-FLOW COORDINATION: lock the active issued predecessor row FOR UPDATE
    --    so issuance WAITS for any in-flight accept_invitation holding that same
    --    invitation row. `status='issued' ... FOR UPDATE` re-evaluates after the
    --    wait: a row a committed acceptance consumed no longer matches (v_active_id
    --    stays NULL). No active issued predecessor => nothing to lock, and no
    --    acceptance can create a member for this application without one.
    SELECT id, expires_at
      INTO v_active_id, v_active_exp
    FROM public.invitation
    WHERE application_ref = p_application_ref AND status = 'issued'
    FOR UPDATE;

    -- 6. POST-LOCK eligibility recheck (fresh statements AFTER the predecessor lock
    --    so a committed concurrent acceptance's member/consumption is visible).
    -- 6a. Application exists exactly once (PK guarantees <= 1).
    SELECT count(*) INTO v_fa_count
    FROM public.founding_applications
    WHERE id = p_application_ref;
    IF v_fa_count <> 1 THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 6b. Exactly one business profile for the application; then FOR UPDATE the row
    --     to coordinate with the NULL-only claim path (save_business_profile locks
    --     the profile row). Lock order: invitation predecessor (5) -> profile (6b).
    SELECT count(*) INTO v_bp_count
    FROM public.business_profiles AS bp
    WHERE bp.application_id = p_application_ref;
    IF v_bp_count > 1 THEN
        RAISE EXCEPTION 'issuance cardinality violation' USING ERRCODE = 'P0001';
    END IF;
    IF v_bp_count <> 1 THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    SELECT user_id INTO v_bp_owner
    FROM public.business_profiles
    WHERE application_id = p_application_ref
    FOR UPDATE;
    -- 6c. Profile must be unowned. Issuance never claims ownership / never writes user_id.
    IF v_bp_owner IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 6d. No member bound to this application (now reflects any committed acceptance).
    SELECT count(*) INTO v_member_count
    FROM public.member
    WHERE application_ref = p_application_ref;
    IF v_member_count <> 0 THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 6e. No existing discovery graph on the member path.
    SELECT count(*) INTO v_ds_count
    FROM public.discovery_state AS ds
    JOIN public.member AS m ON m.id = ds.member_id
    WHERE m.application_ref = p_application_ref;
    IF v_ds_count <> 0 THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 7. token_hash replay: reject BEFORE any mutation. UNIQUE(token_hash) remains
    --    the ultimate authority (a residual cross-application race rolls the whole
    --    transaction back at INSERT, never a partial mutation).
    IF EXISTS (SELECT 1 FROM public.invitation WHERE token_hash = p_token_hash) THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;

    -- 8. Lifecycle classification for the outcome: any prior invitation => reissue.
    SELECT count(*) INTO v_prior_count
    FROM public.invitation
    WHERE application_ref = p_application_ref;

    -- 9. Transition the LOCKED predecessor. The lifecycle predicate
    --    (AND status = 'issued') means the UPDATE can NEVER overwrite a concurrently
    --    consumed/revoked/expired row; under our FOR UPDATE it is provably 'issued',
    --    so exactly one row is affected (verified) — otherwise it is drift (RAISE).
    IF v_active_id IS NOT NULL THEN
        IF v_active_exp <= v_now THEN
            -- Expired predecessor: transition to non-active 'expired' (no supersede link).
            UPDATE public.invitation
            SET status = 'expired'
            WHERE id = v_active_id AND status = 'issued';
            GET DIAGNOSTICS v_rows = ROW_COUNT;
            IF v_rows <> 1 THEN
                RAISE EXCEPTION 'issuance predecessor transition drift' USING ERRCODE = 'P0001';
            END IF;
        ELSE
            -- Active predecessor: supersede-and-revoke (D08). Revoke now (frees the
            -- index); link superseded_by to the successor after INSERT.
            v_active_live := true;
            UPDATE public.invitation
            SET status = 'revoked'
            WHERE id = v_active_id AND status = 'issued';
            GET DIAGNOSTICS v_rows = ROW_COUNT;
            IF v_rows <> 1 THEN
                RAISE EXCEPTION 'issuance predecessor transition drift' USING ERRCODE = 'P0001';
            END IF;
        END IF;
    END IF;

    -- 10. Insert the replacement issued invitation. Server-authoritative issued_at
    --     and expires_at = issued_at + 14 days (frozen policy). token_hash ONLY.
    INSERT INTO public.invitation
        (token_hash, bound_email, application_ref, issued_at, expires_at, status)
    VALUES
        (p_token_hash, v_email, p_application_ref, v_now, v_now + interval '14 days', 'issued')
    RETURNING id INTO v_new_id;

    -- 11. Link a revoked ACTIVE predecessor to its successor (revoked + superseded).
    IF v_active_live THEN
        UPDATE public.invitation
        SET superseded_by = v_new_id
        WHERE id = v_active_id AND status = 'revoked';
    END IF;

    -- 12. Outcome: first issuance vs reissuance in the application lifecycle.
    IF v_prior_count = 0 THEN
        v_outcome := 'issued';
    ELSE
        v_outcome := 'reissued';
    END IF;

    RETURN jsonb_build_object(
        'status', 'issued',
        'outcome', v_outcome,
        'invitation_ref', v_new_id
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.issue_open_invitation(p_bound_email text, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_email     text;
    v_now       timestamptz;
    v_active_id uuid;
    v_new_id    uuid;
    v_rows      integer;
BEGIN
    IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;
    v_email := lower(btrim(coalesce(p_bound_email, '')));
    IF v_email = ''
       OR length(v_email) > 254
       OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;
    v_now := now();
    PERFORM pg_advisory_xact_lock(hashtextextended(v_email, 1));
    IF EXISTS (SELECT 1 FROM public.invitation WHERE token_hash = p_token_hash) THEN
        RETURN jsonb_build_object('status', 'rejected');
    END IF;
    SELECT id INTO v_active_id
    FROM public.invitation
    WHERE application_ref IS NULL
      AND status = 'issued'
      AND lower(btrim(bound_email)) = v_email
    ORDER BY issued_at DESC
    LIMIT 1
    FOR UPDATE;
    IF v_active_id IS NOT NULL THEN
        UPDATE public.invitation SET status = 'revoked'
        WHERE id = v_active_id AND status = 'issued';
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 1 THEN
            RAISE EXCEPTION 'open issuance predecessor transition drift' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    INSERT INTO public.invitation
        (token_hash, bound_email, application_ref, issued_at, expires_at, status)
    VALUES
        (p_token_hash, v_email, NULL, v_now, v_now + interval '14 days', 'issued')
    RETURNING id INTO v_new_id;
    IF v_active_id IS NOT NULL THEN
        UPDATE public.invitation SET superseded_by = v_new_id
        WHERE id = v_active_id AND status = 'revoked';
    END IF;
    RETURN jsonb_build_object('status', 'issued', 'invitation_ref', v_new_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_content_failed(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE v_status text;
BEGIN
    SELECT status INTO v_status FROM public.member_generated_content WHERE id = p_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
    IF v_status = 'ready' THEN RETURN jsonb_build_object('status','already_ready','content_id',p_id); END IF;
    UPDATE public.member_generated_content
       SET status='failed',
           error=jsonb_build_object('reason','worker_error',
                 'detail', left(regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]',' ','g'),500)),
           completed_at=now()
     WHERE id = p_id;
    RETURN jsonb_build_object('status','failed','content_id',p_id);
END; $function$
;

CREATE OR REPLACE FUNCTION public.mark_discovery_failed(p_run_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_member_id uuid;
    v_status    text;
    v_reason    text;
BEGIN
    -- Validate the run exists; act only on this run.
    SELECT member_id, run_status INTO v_member_id, v_status
      FROM public.discovery_runs WHERE id = p_run_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status','run_not_found');
    END IF;

    -- Never overwrite a completed run (preserve valid prior discovery intelligence).
    IF v_status = 'succeeded' THEN
        RETURN jsonb_build_object('status','already_succeeded','run_id',p_run_id);
    END IF;

    -- Bound + sanitise the reason (strip control chars; cap at 500). The worker is
    -- responsible for not passing secrets; this is defence-in-depth on storage.
    v_reason := left(regexp_replace(coalesce(p_reason,''), '[[:cntrl:]]', ' ', 'g'), 500);
    IF nullif(btrim(v_reason),'') IS NULL THEN v_reason := 'worker_error'; END IF;

    UPDATE public.discovery_runs
       SET run_status   = 'failed',
           error        = jsonb_build_object('reason','worker_error','detail', v_reason),
           completed_at = now()
     WHERE id = p_run_id;

    UPDATE public.discovery_state
       SET analysis_status = 'failed'
     WHERE member_id = v_member_id;

    RETURN jsonb_build_object('status','failed','run_id',p_run_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_preparation_failed(p_acquisition_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_state text;
begin
  if p_acquisition_id is null then
    return jsonb_build_object('status', 'invalid');
  end if;

  select state
    into v_state
    from public.product_acquisitions
   where id = p_acquisition_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_state = 'PREPARE_FAILED' then
    return jsonb_build_object('status', 'already_failed');
  end if;
  if v_state <> 'PREPARING' then
    return jsonb_build_object('status', 'not_eligible', 'state', v_state);
  end if;

  update public.product_acquisitions
     set state = 'PREPARE_FAILED',
         state_reason = left(coalesce(nullif(btrim(p_reason), ''), 'preparation_failed'), 500),
         updated_at = now()
   where id = p_acquisition_id
     and state = 'PREPARING';

  return jsonb_build_object('status', 'failed');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_product_prepared(p_acquisition_id uuid, p_prepared_package jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_state text;
begin
  if p_acquisition_id is null
     or p_prepared_package is null
     or jsonb_typeof(p_prepared_package) <> 'object' then
    return jsonb_build_object('status', 'invalid');
  end if;

  select state
    into v_state
    from public.product_acquisitions
   where id = p_acquisition_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_state = 'READY_FOR_REVIEW' then
    return jsonb_build_object('status', 'already_ready');
  end if;
  if v_state <> 'PREPARING' then
    return jsonb_build_object('status', 'not_eligible', 'state', v_state);
  end if;

  update public.product_acquisitions
     set prepared_package = p_prepared_package,
         state = 'READY_FOR_REVIEW',
         state_reason = null,
         updated_at = now()
   where id = p_acquisition_id
     and state = 'PREPARING';

  return jsonb_build_object('status', 'ready');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_commerce_demand_from_run(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user uuid; v_cands jsonb; c jsonb; v_ident text; v_pid uuid; v_strength text; v_raw text; v_n int := 0;
BEGIN
  SELECT user_id INTO v_user FROM public.discovery_runs WHERE id=p_source_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;
  SELECT dna_extended->'commerce'->'winning_product_intelligence'->'candidates'
    INTO v_cands FROM public.member_business_dna WHERE user_id=v_user AND source_run_id=p_source_run_id;
  IF v_cands IS NULL OR jsonb_typeof(v_cands) <> 'array' THEN RETURN jsonb_build_object('status','no_demand_research','demand_signals',0); END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_cands) LOOP
    v_raw := lower(coalesce(c->'demand_signal'->>'strength',''));
    v_strength := CASE WHEN v_raw IN ('strong','high') THEN 'STRONG' WHEN v_raw IN ('moderate','medium') THEN 'MODERATE'
                       WHEN v_raw IN ('weak','low') THEN 'LOW' ELSE 'INSUFFICIENT_EVIDENCE' END;
    v_ident := public.fn_commerce_product_identity(nullif(btrim(coalesce(c->>'product_url','')),''), NULL, nullif(btrim(coalesce(c->>'product_title','')),''), NULL) ->> 'identity';
    v_pid := NULL;
    IF v_ident IS NOT NULL THEN
      SELECT id INTO v_pid FROM public.commerce_products WHERE user_id=v_user AND source_run_id=p_source_run_id AND product_role='own' AND product_identity=v_ident LIMIT 1;
    END IF;

    INSERT INTO public.commerce_signals (user_id, product_id, source_run_id, signal_type, value, evidence, provenance, observed_at, dedup_key)
    VALUES (v_user, v_pid, p_source_run_id, 'demand_evidence',
      jsonb_build_object('strength', v_strength, 'direction', c->'demand_signal'->>'direction', 'has_summary', (c->'demand_signal'->>'summary') IS NOT NULL),
      CASE WHEN jsonb_typeof(c->'evidence')='array' THEN c->'evidence' ELSE '[]'::jsonb END,
      jsonb_build_object('signal','RESEARCHED'),   -- grounded research, never OBSERVED
      now(), 'run:'||p_source_run_id::text||':'||coalesce(v_ident, lower(btrim(coalesce(c->>'product_title','?'))))||':demand_evidence')
    ON CONFLICT (user_id, dedup_key) DO UPDATE SET product_id=excluded.product_id, value=excluded.value, evidence=excluded.evidence, provenance=excluded.provenance, observed_at=excluded.observed_at;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('status','ok','demand_signals', v_n);
END; $function$
;

CREATE OR REPLACE FUNCTION public.normalize_commerce_products_from_run(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid; v_website text; v_host text;
  v_products jsonb; v_prod jsonb; v_n int := 0; v_ok int := 0; v_res jsonb;
BEGIN
  IF p_source_run_id IS NULL THEN RETURN jsonb_build_object('status','missing_run'); END IF;
  SELECT user_id, website INTO v_user, v_website FROM public.discovery_runs WHERE id = p_source_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  SELECT dna_extended->'commerce'->'product_intelligence'->'products'
    INTO v_products
  FROM public.member_business_dna
  WHERE user_id = v_user AND source_run_id = p_source_run_id;

  IF v_products IS NULL OR jsonb_typeof(v_products) <> 'array' THEN
    RETURN jsonb_build_object('status','no_products','ingested',0);
  END IF;

  v_host := nullif(regexp_replace(regexp_replace(lower(coalesce(v_website,'')), '^https?://',''), '/.*$',''), '');

  FOR v_prod IN SELECT * FROM jsonb_array_elements(v_products) LOOP
    v_n := v_n + 1;
    -- attach the store host as source_store when the product does not carry one
    IF (v_prod->>'source_store') IS NULL AND v_host IS NOT NULL THEN
      v_prod := v_prod || jsonb_build_object('source_store', v_host);
    END IF;
    v_res := public.ingest_commerce_product(v_user, p_source_run_id, v_prod, 'OBSERVED');
    IF v_res->>'status' = 'ok' THEN v_ok := v_ok + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','seen', v_n, 'ingested', v_ok);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_money(p_amount numeric, p_original_currency text, p_display_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE oc text := upper(btrim(coalesce(p_original_currency,''))); dc text := upper(btrim(coalesce(p_display_currency,'')));
        fx jsonb; v_conv numeric; v_status text;
        v_base jsonb := jsonb_build_object('original_amount',p_amount,'original_currency',nullif(oc,''));
BEGIN
    IF p_amount IS NULL OR oc = '' THEN
        RETURN v_base || jsonb_build_object('conversion_status','no_source');
    END IF;
    IF dc = '' OR dc IS NULL THEN
        -- No display currency resolved: present source as-is.
        RETURN v_base || jsonb_build_object('display_currency',NULL,'converted_amount',NULL,'conversion_status','no_display_currency');
    END IF;
    IF oc = dc THEN
        RETURN v_base || jsonb_build_object('display_currency',dc,'converted_amount',p_amount,
                 'fx_rate',1,'fx_rate_source','identity','fx_rate_timestamp',NULL,'conversion_status','same_currency');
    END IF;

    fx := public.get_fx_rate(oc, dc);
    IF NOT (fx->>'available')::boolean THEN
        -- Do NOT fabricate. Preserve source; mark unavailable.
        RETURN v_base || jsonb_build_object('display_currency',dc,'converted_amount',NULL,
                 'fx_rate',NULL,'fx_rate_source',NULL,'fx_rate_timestamp',NULL,'conversion_status','unavailable');
    END IF;
    IF (fx->>'stale')::boolean THEN
        RETURN v_base || jsonb_build_object('display_currency',dc,'converted_amount',NULL,
                 'fx_rate',(fx->>'rate')::numeric,'fx_rate_source',fx->>'source','fx_rate_timestamp',fx->>'fetched_at',
                 'conversion_status','stale');
    END IF;

    v_conv := round(p_amount * (fx->>'rate')::numeric, 2);
    RETURN v_base || jsonb_build_object('display_currency',dc,'converted_amount',v_conv,
             'fx_rate',(fx->>'rate')::numeric,'fx_rate_source',fx->>'source','fx_rate_timestamp',fx->>'fetched_at',
             'conversion_status','converted');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.persist_discovery_result(p_run_id uuid, p_contract jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_run         public.discovery_runs%ROWTYPE;
    v_user        uuid;
    v_member_id   uuid;
    v_member_auth uuid;
    v_n           integer;
    v_opp_count   integer := 0;
    v_act_count   integer := 0;
    v_failed      boolean := false;
    v_err         text;
BEGIN
    SELECT * INTO v_run FROM public.discovery_runs WHERE id = p_run_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'run_not_found'); END IF;
    IF v_run.run_status = 'succeeded' THEN
        RETURN jsonb_build_object('status', 'already_persisted', 'run_id', p_run_id);
    END IF;
    v_user := v_run.user_id; v_member_id := v_run.member_id;
    BEGIN
        SELECT m.auth_user_id INTO v_member_auth FROM public.member m WHERE m.id = v_member_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'VALIDATION:run_member_mismatch'; END IF;
        IF v_member_auth IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'VALIDATION:run_member_mismatch'; END IF;
        IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = v_user) THEN
            RAISE EXCEPTION 'VALIDATION:identity_bridge_missing'; END IF;
        IF jsonb_typeof(p_contract) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'VALIDATION:contract_not_object'; END IF;
        IF (p_contract->>'contract_version') IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'VALIDATION:unsupported_version'; END IF;
        IF jsonb_typeof(p_contract->'business_dna') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'VALIDATION:missing_business_dna'; END IF;
        IF jsonb_typeof(p_contract->'icp') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'VALIDATION:missing_icp'; END IF;
        IF jsonb_typeof(p_contract->'morning_brief') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'VALIDATION:missing_morning_brief'; END IF;
        IF jsonb_typeof(p_contract->'opportunities') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'VALIDATION:missing_opportunities'; END IF;
        IF jsonb_typeof(p_contract->'actions') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'VALIDATION:missing_actions'; END IF;
        IF (p_contract->'business_dna'->>'provenance') IS NULL
           OR (p_contract->'business_dna'->>'provenance') NOT IN ('OBSERVED','INFERRED','RESEARCHED','EXISTING_PULSE') THEN
            RAISE EXCEPTION 'VALIDATION:dna_provenance'; END IF;
        v_n := jsonb_array_length(p_contract->'opportunities');
        IF v_n < 1 OR v_n > 3 THEN RAISE EXCEPTION 'VALIDATION:opportunity_count'; END IF;
        IF (SELECT count(DISTINCT (e->>'rank')) FROM jsonb_array_elements(p_contract->'opportunities') e) <> v_n THEN
            RAISE EXCEPTION 'VALIDATION:duplicate_rank'; END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_contract->'opportunities') e WHERE
                (e->>'rank') IS NULL
             OR nullif(btrim(coalesce(e->>'why_matters','')),'') IS NULL
             OR nullif(btrim(coalesce(e->>'why_now','')),'') IS NULL
             OR nullif(btrim(coalesce(e->>'recommended_decision','')),'') IS NULL
             OR (e->>'provenance') IS NULL
             OR (e->>'provenance') NOT IN ('OBSERVED','INFERRED','RESEARCHED','EXISTING_PULSE')
             OR ((e->>'opportunity_id') IS NULL AND (
                    nullif(btrim(coalesce(e->>'title','')),'') IS NULL
                 OR jsonb_typeof(e->'evidence') IS DISTINCT FROM 'array'
                 OR coalesce(e->'evidence','[]'::jsonb) = '[]'::jsonb))
        ) THEN RAISE EXCEPTION 'VALIDATION:opportunity_fields'; END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_contract->'opportunities') e
                   WHERE (e->>'opportunity_id') IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM public.opportunities o WHERE o.id = (e->>'opportunity_id')::uuid)) THEN
            RAISE EXCEPTION 'VALIDATION:unknown_opportunity'; END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_contract->'actions') a WHERE
                (a->>'action_type') NOT IN ('quick_win','next_stage','next_best_move')
             OR (a->>'provenance') IS NULL
             OR (a->>'provenance') NOT IN ('OBSERVED','INFERRED','RESEARCHED','EXISTING_PULSE')
        ) THEN RAISE EXCEPTION 'VALIDATION:action_fields'; END IF;
        IF (SELECT count(*) FROM jsonb_array_elements(p_contract->'actions') a WHERE a->>'action_type'='next_best_move') <> 1
           OR (SELECT count(*) FROM jsonb_array_elements(p_contract->'actions') a WHERE a->>'action_type'='quick_win') < 1
           OR (SELECT count(*) FROM jsonb_array_elements(p_contract->'actions') a WHERE a->>'action_type'='next_stage') < 1
        THEN RAISE EXCEPTION 'VALIDATION:action_categories'; END IF;

        INSERT INTO public.member_business_dna
            (user_id, business_model, unique_value_prop, brand_positioning, growth_stage, brand_voice,
             goals, icp, dna_extended, provenance, source_run_id)
        VALUES (v_user, p_contract->'business_dna'->>'business_model',
            p_contract->'business_dna'->>'unique_value_proposition', p_contract->'business_dna'->>'brand_positioning',
            p_contract->'business_dna'->>'growth_stage', p_contract->'business_dna'->>'brand_voice',
            p_contract->'business_dna'->'business_goals', p_contract->'icp', p_contract->'dna_extended',
            jsonb_build_object('business_dna', p_contract->'business_dna'->>'provenance'), p_run_id)
        ON CONFLICT (user_id) DO UPDATE SET
            business_model=excluded.business_model, unique_value_prop=excluded.unique_value_prop,
            brand_positioning=excluded.brand_positioning, growth_stage=excluded.growth_stage,
            brand_voice=excluded.brand_voice, goals=excluded.goals, icp=excluded.icp,
            dna_extended=excluded.dna_extended, provenance=excluded.provenance,
            source_run_id=excluded.source_run_id, updated_at=now();

        DELETE FROM public.member_opportunities WHERE source_run_id = p_run_id;
        INSERT INTO public.member_opportunities
            (user_id, opportunity_id, title, summary, rank, business_relevance,
             personalized_opportunity_score, confidence, urgency, why_matters, why_now,
             recommended_decision, evidence, content_reco, status, extended, provenance, source_run_id)
        SELECT v_user, nullif(e->>'opportunity_id','')::uuid,
               nullif(btrim(coalesce(e->>'title','')),''), nullif(btrim(coalesce(e->>'summary','')),''),
               (e->>'rank')::int, (e->>'business_relevance')::numeric, (e->>'personalized_opportunity_score')::numeric,
               (e->>'confidence')::numeric, e->>'urgency', e->>'why_matters', e->>'why_now',
               e->>'recommended_decision', coalesce(e->'evidence','[]'::jsonb), e->'content_reco',
               'suggested', e->'extended', jsonb_build_object('opportunity', e->>'provenance'), p_run_id
        FROM jsonb_array_elements(p_contract->'opportunities') e
        ON CONFLICT (user_id, opportunity_id) DO UPDATE SET
            title=excluded.title, summary=excluded.summary, rank=excluded.rank,
            business_relevance=excluded.business_relevance,
            personalized_opportunity_score=excluded.personalized_opportunity_score,
            confidence=excluded.confidence, urgency=excluded.urgency, why_matters=excluded.why_matters,
            why_now=excluded.why_now, recommended_decision=excluded.recommended_decision,
            evidence=excluded.evidence, content_reco=excluded.content_reco, extended=excluded.extended,
            provenance=excluded.provenance, source_run_id=excluded.source_run_id, updated_at=now();
        GET DIAGNOSTICS v_opp_count = ROW_COUNT;

        DELETE FROM public.member_actions WHERE source_run_id = p_run_id;
        INSERT INTO public.member_actions
            (user_id, member_opportunity_id, opportunity_id, action_type, title, detail, rank, status,
             provenance, extended, source_run_id)
        SELECT v_user,
               (SELECT mo.id FROM public.member_opportunities mo
                 WHERE mo.user_id = v_user AND mo.opportunity_id = nullif(a->>'opportunity_id','')::uuid
                   AND nullif(a->>'opportunity_id','') IS NOT NULL),
               nullif(a->>'opportunity_id','')::uuid,
               a->>'action_type', a->>'title', a->>'detail', (a->>'rank')::int, 'suggested',
               jsonb_build_object('action', a->>'provenance'), a->'extended', p_run_id
        FROM jsonb_array_elements(p_contract->'actions') a;
        GET DIAGNOSTICS v_act_count = ROW_COUNT;

        INSERT INTO public.daily_briefs (user_id, date, top_opportunities, brief_json, generated_at)
        VALUES (v_user, current_date,
            (SELECT coalesce(jsonb_agg(jsonb_build_object('opportunity_id', e->>'opportunity_id',
                        'title', e->>'title', 'rank', (e->>'rank')::int) ORDER BY (e->>'rank')::int), '[]'::jsonb)
             FROM jsonb_array_elements(p_contract->'opportunities') e),
            p_contract->'morning_brief', now())
        ON CONFLICT (user_id, date) DO UPDATE SET
            top_opportunities=excluded.top_opportunities, brief_json=excluded.brief_json, generated_at=now();

        UPDATE public.discovery_runs SET run_status='succeeded', raw_contract=p_contract, completed_at=now() WHERE id = p_run_id;
        UPDATE public.discovery_state SET analysis_status='ready' WHERE member_id = v_member_id;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_err := SQLERRM;
    END;
    IF v_failed THEN
        UPDATE public.discovery_runs
           SET run_status='failed',
               error=jsonb_build_object('reason', CASE WHEN v_err LIKE 'VALIDATION:%' THEN substring(v_err from 12) ELSE 'persistence_error' END),
               completed_at=now()
         WHERE id = p_run_id;
        UPDATE public.discovery_state SET analysis_status='failed' WHERE member_id = v_member_id;
        RETURN jsonb_build_object('status', CASE WHEN v_err LIKE 'VALIDATION:%' THEN 'invalid_contract' ELSE 'failed' END,
            'reason', CASE WHEN v_err LIKE 'VALIDATION:%' THEN substring(v_err from 12) ELSE 'persistence_error' END);
    END IF;
    RETURN jsonb_build_object('status','ready','run_id',p_run_id,'opportunities', v_opp_count, 'actions', v_act_count);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.persist_generated_content(p_id uuid, p_content jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_row public.member_generated_content%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM public.member_generated_content WHERE id = p_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
    IF v_row.status = 'ready' THEN RETURN jsonb_build_object('status','already_ready','content_id',p_id); END IF;
    IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' OR p_content = '{}'::jsonb
       OR (nullif(btrim(coalesce(p_content->>'title','')),'') IS NULL
           AND nullif(btrim(coalesce(p_content->>'hook','')),'') IS NULL) THEN
        UPDATE public.member_generated_content
           SET status='failed', error=jsonb_build_object('reason','malformed_content'), completed_at=now()
         WHERE id = p_id;
        RETURN jsonb_build_object('status','invalid_content','content_id',p_id);
    END IF;
    UPDATE public.member_generated_content
       SET status='ready', content=p_content, error=NULL, completed_at=now()
     WHERE id = p_id;
    RETURN jsonb_build_object('status','ready','content_id',p_id);
END; $function$
;

CREATE OR REPLACE FUNCTION public.persist_marketing_campaign_draft(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_status text;
    v_id     uuid;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RETURN jsonb_build_object('status', 'error', 'error', 'invalid_payload');
    END IF;
    IF NOT (p_payload ? 'report')
       OR jsonb_typeof(p_payload -> 'report') <> 'object'
       OR p_payload -> 'report' = '{}'::jsonb THEN
        RETURN jsonb_build_object('status', 'error', 'error', 'missing_report');
    END IF;

    v_status := coalesce(nullif(p_payload ->> 'status', ''), 'DRAFT');
    IF v_status NOT IN ('DRAFT', 'READY_FOR_REVIEW', 'APPROVED', 'ARCHIVED') THEN
        v_status := 'DRAFT';
    END IF;

    INSERT INTO public.marketing_campaign_drafts (
        user_id, source_run_id, website, business_context, report,
        canonical_campaign, platform_payloads, creative_specs, brand_assets,
        preview_payload, review_payload, performance_schema, lifecycle, status
    ) VALUES (
        nullif(p_payload ->> 'user_id', '')::uuid,
        nullif(p_payload ->> 'source_run_id', '')::uuid,
        p_payload ->> 'website',
        coalesce(p_payload -> 'business_context', '{}'::jsonb),
        p_payload -> 'report',
        p_payload -> 'canonical_campaign',
        p_payload -> 'platform_payloads',
        p_payload -> 'creative_specs',
        p_payload -> 'brand_assets',
        p_payload -> 'preview_payload',
        p_payload -> 'review_payload',
        p_payload -> 'performance_schema',
        coalesce(p_payload -> 'lifecycle', jsonb_build_object('status', v_status)),
        v_status
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('status', 'ok', 'id', v_id, 'draft_status', v_status);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status', 'error', 'error', 'persist_failed');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_meta_execution_refs(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_draft_id uuid; v_status text; v_id uuid; v_eff jsonb;
    v_c text; v_as text; v_ad text;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RETURN jsonb_build_object('status','error','error','invalid_payload');
    END IF;
    v_draft_id := nullif(p_payload->>'draft_id','')::uuid;
    IF v_draft_id IS NULL THEN
        RETURN jsonb_build_object('status','error','error','missing_draft_id');
    END IF;
    v_status := coalesce(nullif(p_payload->>'status',''),'PENDING');
    IF v_status NOT IN ('PENDING','CREATED_PAUSED','FAILED','BLOCKED') THEN
        v_status := 'PENDING';
    END IF;
    v_eff := coalesce(p_payload->'effective_status','{}'::jsonb);

    IF v_status = 'CREATED_PAUSED' THEN
        v_c  := upper(coalesce(v_eff->>'campaign',''));
        v_as := upper(coalesce(v_eff->>'adset',''));
        v_ad := upper(coalesce(v_eff->>'ad',''));
        -- Read-back must be present for every delivery-capable object.
        IF v_c = '' OR v_as = '' OR v_ad = '' THEN
            RETURN jsonb_build_object('status','error','error','missing_readback','effective_status',v_eff);
        END IF;
        -- Refuse to record if ANY object is actually delivering (ACTIVE).
        IF v_c = 'ACTIVE' OR v_as = 'ACTIVE' OR v_ad = 'ACTIVE' THEN
            RETURN jsonb_build_object('status','error','error','delivering_object_detected','effective_status',v_eff);
        END IF;
    END IF;

    INSERT INTO public.marketing_campaign_executions (
        draft_id, user_id, platform, status,
        meta_account_ref, meta_page_ref,
        meta_campaign_id, meta_adset_id, meta_creative_id, meta_ad_id,
        effective_status, notes
    ) VALUES (
        v_draft_id, nullif(p_payload->>'user_id','')::uuid, 'meta', v_status,
        p_payload->>'account_ref', p_payload->>'page_ref',
        p_payload->>'campaign_id', p_payload->>'adset_id', p_payload->>'creative_id', p_payload->>'ad_id',
        v_eff, coalesce(p_payload->'notes','{}'::jsonb)
    )
    ON CONFLICT (draft_id, platform) DO UPDATE
    SET status           = EXCLUDED.status,
        user_id          = coalesce(EXCLUDED.user_id, public.marketing_campaign_executions.user_id),
        meta_account_ref = coalesce(EXCLUDED.meta_account_ref, public.marketing_campaign_executions.meta_account_ref),
        meta_page_ref    = coalesce(EXCLUDED.meta_page_ref, public.marketing_campaign_executions.meta_page_ref),
        meta_campaign_id = coalesce(EXCLUDED.meta_campaign_id, public.marketing_campaign_executions.meta_campaign_id),
        meta_adset_id    = coalesce(EXCLUDED.meta_adset_id, public.marketing_campaign_executions.meta_adset_id),
        meta_creative_id = coalesce(EXCLUDED.meta_creative_id, public.marketing_campaign_executions.meta_creative_id),
        meta_ad_id       = coalesce(EXCLUDED.meta_ad_id, public.marketing_campaign_executions.meta_ad_id),
        effective_status = EXCLUDED.effective_status,
        notes            = EXCLUDED.notes
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('status','ok','execution_id',v_id,'record_status',v_status);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('status','error','error','record_failed','detail',SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.reddit_product_candidate_batch(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) FROM (
    SELECT DISTINCT ON (ts.raw_topic)
      ts.id AS signal_id,
      ts.raw_topic,
      (regexp_match(ts.raw_data::text, 'reddit\.com/r/([a-zA-Z0-9_]+)/'))[1] AS subreddit,
      (regexp_match(ts.raw_data::text, '(https://www\.reddit\.com/r/[a-zA-Z0-9_]+/comments/[a-z0-9]+)'))[1] AS url,
      coalesce(ts.region,'GLOBAL') AS region,
      coalesce(ts.language,'en') AS language,
      ts.collected_at,
      (ts.raw_topic ~* '\y(recommend|worth it|looking for|best|vs|alternative to|anyone (tried|used)|just bought|which one|any good|suggestions?)\y') AS has_intent
    FROM public.trend_signals ts
    WHERE ts.source='reddit'
      AND ts.raw_topic ~* '\y(blender|humidifier|thermometer|massager|feeder|diffuser|projector|kettle|air ?fryer|earbuds|headphones|tumbler|charger|purifier|backpack|standing desk|desk lamp|ring light|razor|trimmer|mechanical keyboard|pillow|mattress|smartwatch|scooter|dash cam|power bank|water flosser|espresso|grinder)\y'
      AND ts.raw_topic !~* '\y(market|stock|shares|funding|startup|senate|congress|war|ukraine|gaza|trump|hacker|nato|military|protest)\y'
    ORDER BY ts.raw_topic, ts.collected_at DESC
    LIMIT greatest(1, least(p_limit, 50))
  ) x;
$function$
;

CREATE OR REPLACE FUNCTION public.reject_marketing_campaign_draft(p_draft_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid   uuid := auth.uid();
    d       public.marketing_campaign_drafts%ROWTYPE;
    v_now   timestamptz;
    v_life  jsonb;
    v_exec_id uuid;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status','unauthenticated');
    END IF;
    IF p_draft_id IS NULL THEN
        RETURN jsonb_build_object('status','invalid_request');
    END IF;

    SELECT * INTO d FROM public.marketing_campaign_drafts WHERE id = p_draft_id;
    IF NOT FOUND OR d.user_id IS DISTINCT FROM v_uid THEN
        RETURN jsonb_build_object('status','not_found');
    END IF;

    -- Never archive a draft that already produced live PAUSED Meta objects.
    SELECT e.id INTO v_exec_id
    FROM public.marketing_campaign_executions e
    WHERE e.draft_id = p_draft_id AND e.platform = 'meta' AND e.status = 'CREATED_PAUSED'
    LIMIT 1;
    IF v_exec_id IS NOT NULL THEN
        RETURN jsonb_build_object('status','already_executed','draft_id',p_draft_id,'execution_id',v_exec_id);
    END IF;

    -- Idempotent no-op if already archived.
    IF d.status = 'ARCHIVED' THEN
        RETURN jsonb_build_object('status','archived','draft_id',p_draft_id,'draft_status','ARCHIVED','idempotent',true);
    END IF;

    v_now := now();
    v_life := coalesce(d.lifecycle, '{}'::jsonb)
              || jsonb_build_object('status','ARCHIVED','publishable',false)
              || jsonb_build_object('rejection', jsonb_build_object(
                    'rejected_at', to_jsonb(v_now),
                    'rejected_by', to_jsonb(v_uid),
                    'reason', coalesce(p_reason,'rejected_by_owner')));
    v_life := jsonb_set(
                v_life, '{history}',
                coalesce(v_life->'history','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object(
                     'stage','ARCHIVED','at', to_jsonb(v_now), 'by', to_jsonb(v_uid),
                     'reason', coalesce(p_reason,'rejected_by_owner'))));

    UPDATE public.marketing_campaign_drafts
       SET status = 'ARCHIVED', lifecycle = v_life, updated_at = v_now
     WHERE id = p_draft_id AND user_id = v_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status','invalid_transition');
    END IF;

    RETURN jsonb_build_object('status','archived','draft_id',p_draft_id,'draft_status','ARCHIVED','rejected_at',to_jsonb(v_now));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_display_currency(p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_pref text; v_bcountry text; v_ucountry text; v_ccy text; v_basis text;
BEGIN
    IF p_uid IS NULL THEN RETURN jsonb_build_object('display_currency',NULL,'basis','no_user'); END IF;

    SELECT nullif(upper(btrim(preferred_display_currency)),''), nullif(upper(btrim(country_code)),'')
      INTO v_pref, v_ucountry FROM public.users WHERE id = p_uid;
    SELECT nullif(btrim(country),'') INTO v_bcountry FROM public.business_profiles WHERE user_id = p_uid
      ORDER BY updated_at DESC NULLS LAST LIMIT 1;

    IF v_pref IS NOT NULL THEN
        RETURN jsonb_build_object('display_currency',v_pref,'basis','explicit_preference');
    END IF;
    v_ccy := public.fn_currency_for_country(v_bcountry);
    IF v_ccy IS NOT NULL THEN
        RETURN jsonb_build_object('display_currency',v_ccy,'basis','business_home_market','country',v_bcountry);
    END IF;
    v_ccy := public.fn_currency_for_country(v_ucountry);
    IF v_ccy IS NOT NULL THEN
        RETURN jsonb_build_object('display_currency',v_ccy,'basis','user_country','country',v_ucountry);
    END IF;
    -- No hardcoded global default: undetermined -> UI shows source currency.
    RETURN jsonb_build_object('display_currency',NULL,'basis','undetermined');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_product_entity(p_entity jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_name text;
  v_gate jsonb;
  v_verdict text;
  v_reasons jsonb;
  v_ident jsonb;
  v_prov text;
  v_url text;
  v_ready jsonb;
BEGIN
  IF jsonb_typeof(p_entity) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('verdict','REJECT','reasons',jsonb_build_array('invalid_entity'));
  END IF;
  v_name := coalesce(nullif(btrim(p_entity->>'canonical_name'),''),
                     nullif(btrim(p_entity->>'product_type'),''),
                     nullif(btrim(p_entity->>'source_phrase'),''));
  v_gate := public.fn_is_sellable_product_entity(v_name);
  v_verdict := v_gate->>'verdict';
  v_reasons := v_gate->'reasons';

  IF lower(coalesce(p_entity->>'is_physical_sellable','true')) IN ('false','no','0') THEN
    v_verdict := 'REJECT';
    v_reasons := (coalesce(v_reasons,'[]'::jsonb)) || jsonb_build_array('llm_not_physical_sellable');
  END IF;

  v_prov := upper(coalesce(nullif(btrim(p_entity->>'provenance'),''), 'INFERRED'));
  IF v_prov NOT IN ('OBSERVED','PLATFORM_REPORTED','RESEARCHED','INFERRED','EXISTING_PULSE') THEN
    v_prov := 'INFERRED';
  END IF;

  -- source_reference is only a product URL when it is one; otherwise identity falls back to name.
  v_url := CASE WHEN p_entity->>'source_reference' ~ '^https?://'
                THEN nullif(btrim(p_entity->>'source_reference'),'') ELSE NULL END;
  v_ident := public.fn_commerce_product_identity(v_url, p_entity->>'platform_id', v_name, p_entity->>'source');

  IF v_verdict <> 'ACCEPT' THEN
    RETURN jsonb_build_object('verdict', v_verdict, 'reasons', v_reasons,
      'normalized_name', v_gate->>'normalized_name', 'input_name', v_name);
  END IF;

  v_ready := jsonb_strip_nulls(jsonb_build_object(
    'title',              v_name,
    'product_type',       nullif(btrim(coalesce(p_entity->>'product_type', p_entity->>'category','')),''),
    'category',           nullif(btrim(p_entity->>'category'),''),
    'source_store',       nullif(btrim(p_entity->>'source'),''),
    'platform_id',        nullif(btrim(p_entity->>'platform_id'),''),
    'product_url',        v_url,
    'provenance',         v_prov,
    'brand',              nullif(btrim(p_entity->>'brand_if_observed'),''),
    'market',             nullif(btrim(p_entity->>'market'),''),
    'language',           nullif(btrim(p_entity->>'language'),''),
    'source_phrase',      nullif(btrim(p_entity->>'source_phrase'),''),
    'source_reference',   nullif(btrim(p_entity->>'source_reference'),''),
    'extraction_confidence', p_entity->'extraction_confidence',
    'product_family_key', v_gate->>'product_family_key',
    'normalized_name',    v_gate->>'normalized_name',
    'is_physical_sellable', true,
    'candidate_method',   'product_entity_resolution'));

  RETURN jsonb_build_object(
    'verdict','ACCEPT', 'reasons', v_reasons,
    'normalized_name', v_gate->>'normalized_name',
    'product_family_key', v_gate->>'product_family_key',
    'exact_identity', v_ident, 'provenance', v_prov,
    'market', nullif(btrim(p_entity->>'market'),''),
    'product_ready', v_ready);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.save_business_profile(p_content jsonb, p_complete boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid          uuid := auth.uid();
    v_member_count integer;
    v_member_id    uuid;
    v_app          uuid;
    v_bp           public.business_profiles%ROWTYPE;
    v_invalid      text[] := ARRAY[]::text[];
    v_bd           jsonb;   -- submitted businessDiscovery (object or NULL)
    v_con          jsonb;   -- submitted constraints (object or NULL)
    v_bd_existing  jsonb;
    v_bd_new       jsonb;
    v_con_existing jsonb;
    v_con_new      jsonb;
    v_new_opp      jsonb;
    v_ds_status    text;
    v_ds_rows      integer;
    c_top   constant text[] := ARRAY['business_name','website','country','industry','business_type','company_size','target_audience','primary_goal','preferred_platforms','competitors','brief_frequency','brand_voice','business_summary','positioning_summary','businessDiscovery'];
    c_bd    constant text[] := ARRAY['schemaVersion','productsOrServices','customerPainPoints','desiredOutcomes','constraints','differentiation','opportunityFocus'];
    c_con   constant text[] := ARRAY['budgetRange','teamCapacity','timeCapacity','geographicFocus'];
    k    text;
    b    integer;
    eff_name text; eff_industry text; eff_audience text; eff_goal text; eff_summary text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;
    IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('status', 'invalid', 'fields', jsonb_build_array('content'));
    END IF;

    -- 1. Reject unknown top-level client keys.
    FOR k IN SELECT jsonb_object_keys(p_content) LOOP
        IF NOT (k = ANY (c_top)) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    -- 2. Validate top-level text fields (present -> string|null, bounded length).
    FOR k, b IN SELECT key, bound FROM (VALUES
        ('business_name',500),('website',500),('country',500),('industry',500),
        ('business_type',500),('company_size',500),('target_audience',500),('primary_goal',500),
        ('brief_frequency',500),('brand_voice',500),('business_summary',4000),('positioning_summary',4000)
    ) AS t(key,bound) LOOP
        IF p_content ? k AND NOT (
            jsonb_typeof(p_content->k) IN ('string','null')
            AND (jsonb_typeof(p_content->k) <> 'string' OR length(btrim(p_content->>k)) <= b)
        ) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    -- 3. Validate top-level string arrays (<=20 string items, each trimmed <=200).
    FOR k IN SELECT unnest(ARRAY['preferred_platforms','competitors']) LOOP
        IF p_content ? k AND NOT (
            jsonb_typeof(p_content->k) = 'array'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_content->k) e WHERE jsonb_typeof(e.value) <> 'string')
            AND (SELECT count(*) FROM jsonb_array_elements_text(p_content->k)) <= 20
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_content->k) e WHERE length(btrim(e.value)) > 200)
        ) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    -- 4. Validate the submitted businessDiscovery namespace (known keys + shapes).
    IF p_content ? 'businessDiscovery' THEN
        v_bd := p_content -> 'businessDiscovery';
        IF jsonb_typeof(v_bd) IS DISTINCT FROM 'object' THEN
            v_invalid := array_append(v_invalid, 'businessDiscovery');
            v_bd := NULL;
        ELSE
            FOR k IN SELECT jsonb_object_keys(v_bd) LOOP
                IF NOT (k = ANY (c_bd)) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.' || k); END IF;
            END LOOP;
            IF v_bd ? 'schemaVersion' AND v_bd->'schemaVersion' IS DISTINCT FROM to_jsonb(1) THEN
                v_invalid := array_append(v_invalid, 'businessDiscovery.schemaVersion');
            END IF;
            FOR k IN SELECT unnest(ARRAY['productsOrServices','customerPainPoints','desiredOutcomes','opportunityFocus']) LOOP
                IF v_bd ? k AND NOT (
                    jsonb_typeof(v_bd->k) = 'array'
                    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_bd->k) e WHERE jsonb_typeof(e.value) <> 'string')
                    AND (SELECT count(*) FROM jsonb_array_elements_text(v_bd->k)) <= 20
                    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_bd->k) e WHERE length(btrim(e.value)) > 200)
                ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.' || k); END IF;
            END LOOP;
            IF v_bd ? 'differentiation' AND NOT (
                jsonb_typeof(v_bd->'differentiation') IN ('string','null')
                AND (jsonb_typeof(v_bd->'differentiation') <> 'string' OR length(btrim(v_bd->>'differentiation')) <= 4000)
            ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.differentiation'); END IF;
            IF v_bd ? 'constraints' THEN
                v_con := v_bd -> 'constraints';
                IF jsonb_typeof(v_con) IS DISTINCT FROM 'object' THEN
                    v_invalid := array_append(v_invalid, 'businessDiscovery.constraints');
                    v_con := NULL;
                ELSE
                    FOR k IN SELECT jsonb_object_keys(v_con) LOOP
                        IF NOT (k = ANY (c_con)) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.' || k); END IF;
                    END LOOP;
                    FOR k IN SELECT unnest(ARRAY['budgetRange','teamCapacity','timeCapacity']) LOOP
                        IF v_con ? k AND NOT (
                            jsonb_typeof(v_con->k) IN ('string','null')
                            AND (jsonb_typeof(v_con->k) <> 'string' OR length(btrim(v_con->>k)) <= 500)
                        ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.' || k); END IF;
                    END LOOP;
                    IF v_con ? 'geographicFocus' AND NOT (
                        jsonb_typeof(v_con->'geographicFocus') = 'array'
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_con->'geographicFocus') e WHERE jsonb_typeof(e.value) <> 'string')
                        AND (SELECT count(*) FROM jsonb_array_elements_text(v_con->'geographicFocus')) <= 20
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_con->'geographicFocus') e WHERE length(btrim(e.value)) > 200)
                    ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.geographicFocus'); END IF;
                END IF;
            END IF;
        END IF;
    END IF;

    -- 5. Resolve member (UNIQUE) then profile (UNIQUE), locked. (Read + lock only;
    --    no mutation. Preserves no_member / profile_not_ready / other-owner ordering.)
    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'business profile resolution cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'profile_not_ready');
    END IF;
    IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
    END IF;

    -- 6. Existing businessDiscovery namespace (approved existing values only).
    v_bd_existing := CASE WHEN jsonb_typeof(v_bp.opportunity_preferences -> 'businessDiscovery') = 'object'
                          THEN v_bp.opportunity_preferences -> 'businessDiscovery' ELSE '{}'::jsonb END;

    -- 7. Completion-required validation (effective = submitted-if-present else
    --    existing). The three required businessDiscovery arrays are evaluated
    --    directly with explicit jsonb_typeof(...) = 'array' guards so no scalar is
    --    ever passed to jsonb_array_elements_text, and a field already flagged by
    --    structural validation is not duplicated.
    IF p_complete THEN
        eff_name     := CASE WHEN p_content ? 'business_name'    THEN nullif(btrim(p_content->>'business_name'), '')    ELSE v_bp.business_name END;
        eff_industry := CASE WHEN p_content ? 'industry'         THEN nullif(btrim(p_content->>'industry'), '')         ELSE v_bp.industry END;
        eff_audience := CASE WHEN p_content ? 'target_audience'  THEN nullif(btrim(p_content->>'target_audience'), '')  ELSE v_bp.target_audience END;
        eff_goal     := CASE WHEN p_content ? 'primary_goal'     THEN nullif(btrim(p_content->>'primary_goal'), '')     ELSE v_bp.primary_goal END;
        eff_summary  := CASE WHEN p_content ? 'business_summary' THEN nullif(btrim(p_content->>'business_summary'), '') ELSE v_bp.business_summary END;
        IF eff_name IS NULL     THEN v_invalid := array_append(v_invalid, 'business_name'); END IF;
        IF eff_industry IS NULL THEN v_invalid := array_append(v_invalid, 'industry'); END IF;
        IF eff_audience IS NULL THEN v_invalid := array_append(v_invalid, 'target_audience'); END IF;
        IF eff_goal IS NULL     THEN v_invalid := array_append(v_invalid, 'primary_goal'); END IF;
        IF eff_summary IS NULL  THEN v_invalid := array_append(v_invalid, 'business_summary'); END IF;

        IF NOT ('businessDiscovery.productsOrServices' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'productsOrServices' AND jsonb_typeof(v_bd->'productsOrServices') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'productsOrServices') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'productsOrServices')) AND jsonb_typeof(v_bd_existing->'productsOrServices') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'productsOrServices') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.productsOrServices'); END IF;

        IF NOT ('businessDiscovery.customerPainPoints' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'customerPainPoints' AND jsonb_typeof(v_bd->'customerPainPoints') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'customerPainPoints') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'customerPainPoints')) AND jsonb_typeof(v_bd_existing->'customerPainPoints') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'customerPainPoints') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.customerPainPoints'); END IF;

        IF NOT ('businessDiscovery.desiredOutcomes' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'desiredOutcomes' AND jsonb_typeof(v_bd->'desiredOutcomes') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'desiredOutcomes') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'desiredOutcomes')) AND jsonb_typeof(v_bd_existing->'desiredOutcomes') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'desiredOutcomes') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.desiredOutcomes'); END IF;
    END IF;

    -- 8. INVALID SHORT-CIRCUIT — after ALL validation, before ANY normalization,
    --    jsonb_array_elements_text, canonical rebuild, claim, profile UPDATE or
    --    discovery_state UPDATE. NO mutation and NO ownership claim occur here.
    IF cardinality(v_invalid) > 0 THEN
        RETURN jsonb_build_object('status', 'invalid', 'fields', to_jsonb(v_invalid));
    END IF;

    -- 9. Rebuild the CANONICAL businessDiscovery object from an approved-key
    --    allowlist: for each approved key use the submitted value else the approved
    --    existing value; unknown existing/submitted keys cannot survive. Arrays are
    --    normalized inline (trim, drop blanks, case-insensitive de-duplicate,
    --    deterministic order; no LIMIT, no truncation). schemaVersion is pinned to 1.
    --    Every submitted array branch is additionally guarded by jsonb_typeof = 'array'
    --    (defensive; unreachable for invalid types after the short-circuit above).
    v_bd_new := jsonb_build_object('schemaVersion', 1);

    IF v_bd IS NOT NULL AND v_bd ? 'productsOrServices' AND jsonb_typeof(v_bd->'productsOrServices') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('productsOrServices', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'productsOrServices') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'productsOrServices') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('productsOrServices', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'productsOrServices') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'customerPainPoints' AND jsonb_typeof(v_bd->'customerPainPoints') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('customerPainPoints', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'customerPainPoints') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'customerPainPoints') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('customerPainPoints', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'customerPainPoints') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'desiredOutcomes' AND jsonb_typeof(v_bd->'desiredOutcomes') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('desiredOutcomes', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'desiredOutcomes') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'desiredOutcomes') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('desiredOutcomes', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'desiredOutcomes') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'opportunityFocus' AND jsonb_typeof(v_bd->'opportunityFocus') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('opportunityFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'opportunityFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'opportunityFocus') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('opportunityFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'opportunityFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'differentiation' THEN
        v_bd_new := v_bd_new || jsonb_build_object('differentiation', nullif(btrim(v_bd->>'differentiation'), ''));
    ELSIF jsonb_typeof(v_bd_existing->'differentiation') = 'string' THEN
        v_bd_new := v_bd_new || jsonb_build_object('differentiation', nullif(btrim(v_bd_existing->>'differentiation'), ''));
    END IF;

    -- constraints: rebuilt from approved keys only (submitted else approved existing).
    v_con_existing := CASE WHEN jsonb_typeof(v_bd_existing -> 'constraints') = 'object' THEN v_bd_existing -> 'constraints' ELSE '{}'::jsonb END;
    v_con_new := jsonb_build_object();
    FOR k IN SELECT unnest(ARRAY['budgetRange','teamCapacity','timeCapacity']) LOOP
        IF v_con IS NOT NULL AND v_con ? k THEN
            v_con_new := v_con_new || jsonb_build_object(k, nullif(btrim(v_con->>k), ''));
        ELSIF jsonb_typeof(v_con_existing->k) = 'string' THEN
            v_con_new := v_con_new || jsonb_build_object(k, nullif(btrim(v_con_existing->>k), ''));
        END IF;
    END LOOP;
    IF v_con IS NOT NULL AND v_con ? 'geographicFocus' AND jsonb_typeof(v_con->'geographicFocus') = 'array' THEN
        v_con_new := v_con_new || jsonb_build_object('geographicFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_con->'geographicFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_con_existing->'geographicFocus') = 'array' THEN
        v_con_new := v_con_new || jsonb_build_object('geographicFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_con_existing->'geographicFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;
    IF v_con_new <> jsonb_build_object() THEN
        v_bd_new := v_bd_new || jsonb_build_object('constraints', v_con_new);
    END IF;

    -- 10. Replace ONLY the businessDiscovery namespace; preserve every other
    --     top-level opportunity_preferences key (never replace the whole object).
    v_new_opp := (CASE WHEN jsonb_typeof(v_bp.opportunity_preferences) = 'object'
                       THEN v_bp.opportunity_preferences ELSE '{}'::jsonb END)
                 || jsonb_build_object('businessDiscovery', v_bd_new);

    -- 11. Atomically claim (NULL->uid; self stays uid) and update ONLY approved
    --     contract columns; absent fields keep their existing value (partial save).
    --     Submitted array branches are guarded by jsonb_typeof = 'array' (defensive).
    UPDATE public.business_profiles SET
        user_id = v_uid,
        business_name       = CASE WHEN p_content ? 'business_name'       THEN nullif(btrim(p_content->>'business_name'), '')       ELSE business_name END,
        website             = CASE WHEN p_content ? 'website'             THEN nullif(btrim(p_content->>'website'), '')             ELSE website END,
        country             = CASE WHEN p_content ? 'country'             THEN nullif(btrim(p_content->>'country'), '')             ELSE country END,
        industry            = CASE WHEN p_content ? 'industry'            THEN nullif(btrim(p_content->>'industry'), '')            ELSE industry END,
        business_type       = CASE WHEN p_content ? 'business_type'       THEN nullif(btrim(p_content->>'business_type'), '')       ELSE business_type END,
        company_size        = CASE WHEN p_content ? 'company_size'        THEN nullif(btrim(p_content->>'company_size'), '')        ELSE company_size END,
        target_audience     = CASE WHEN p_content ? 'target_audience'     THEN nullif(btrim(p_content->>'target_audience'), '')     ELSE target_audience END,
        primary_goal        = CASE WHEN p_content ? 'primary_goal'        THEN nullif(btrim(p_content->>'primary_goal'), '')        ELSE primary_goal END,
        preferred_platforms = CASE WHEN p_content ? 'preferred_platforms' AND jsonb_typeof(p_content->'preferred_platforms') = 'array' THEN
            (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(p_content->'preferred_platforms') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d)
            ELSE preferred_platforms END,
        competitors         = CASE WHEN p_content ? 'competitors' AND jsonb_typeof(p_content->'competitors') = 'array' THEN
            (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(p_content->'competitors') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d)
            ELSE competitors END,
        brief_frequency     = CASE WHEN p_content ? 'brief_frequency'     THEN nullif(btrim(p_content->>'brief_frequency'), '')     ELSE brief_frequency END,
        brand_voice         = CASE WHEN p_content ? 'brand_voice'         THEN nullif(btrim(p_content->>'brand_voice'), '')         ELSE brand_voice END,
        business_summary    = CASE WHEN p_content ? 'business_summary'    THEN nullif(btrim(p_content->>'business_summary'), '')    ELSE business_summary END,
        positioning_summary = CASE WHEN p_content ? 'positioning_summary' THEN nullif(btrim(p_content->>'positioning_summary'), '') ELSE positioning_summary END,
        opportunity_preferences = v_new_opp,
        updated_at          = now()
    WHERE application_id = v_app
    RETURNING * INTO v_bp;

    -- 12. Atomic discovery_state transition — EXACTLY one row must update, else the
    --     whole transaction rolls back (-> temporary_failure). No insert-if-missing.
    v_ds_status := CASE WHEN p_complete THEN 'complete' ELSE 'in_progress' END;
    UPDATE public.discovery_state SET status = v_ds_status WHERE member_id = v_member_id;
    GET DIAGNOSTICS v_ds_rows = ROW_COUNT;
    IF v_ds_rows <> 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'status', 'saved',
        'discovery', v_ds_status,
        'profile', jsonb_build_object(
            'business_name', v_bp.business_name,
            'website', v_bp.website,
            'country', v_bp.country,
            'industry', v_bp.industry,
            'business_type', v_bp.business_type,
            'company_size', v_bp.company_size,
            'target_audience', v_bp.target_audience,
            'primary_goal', v_bp.primary_goal,
            'preferred_platforms', coalesce(v_bp.preferred_platforms, '[]'::jsonb),
            'competitors', coalesce(v_bp.competitors, '[]'::jsonb),
            'brief_frequency', v_bp.brief_frequency,
            'brand_voice', v_bp.brand_voice,
            'business_summary', v_bp.business_summary,
            'positioning_summary', v_bp.positioning_summary,
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Ownership conflict, impossible cardinality, missing/duplicate discovery_state
        -- and any unexpected drift roll back the whole save and are translated to the
        -- single non-enumerating result. No message/SQLSTATE/identifier is exposed.
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.score_commerce_products(p_source_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_ver text := 'ecom005c-v1';
  v_user uuid; v_niche text; v_industry text; p record;
  v_n_observed int; v_sources int; v_last timestamptz; v_age numeric;
  v_avail text; v_price_known boolean; v_fit boolean; v_fresh numeric; v_stale boolean;
  v_comp_level text; v_mom text; v_demand text; v_gap boolean; v_att text; v_haspf boolean;
  v_factors jsonb; v_sum numeric; v_wsum numeric;
  v_score int; v_conf numeric; v_class text; v_decision text;
  v_pos jsonb; v_risk jsonb; v_prov text; v_why text; v_whynow text;
  v_evidence jsonb; v_signals jsonb; v_scored int := 0;
  base_types text[] := ARRAY['product_discovered','price_observed','availability_observed','promotion_observed','market_attention_observed'];
  pf_types text[] := ARRAY['product_discovered','price_observed','availability_observed','promotion_observed'];
BEGIN
  IF p_source_run_id IS NULL THEN RETURN jsonb_build_object('status','missing_run'); END IF;
  SELECT user_id INTO v_user FROM public.discovery_runs WHERE id=p_source_run_id;
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  PERFORM public.derive_commerce_competition(p_source_run_id);
  PERFORM public.normalize_commerce_demand_from_run(p_source_run_id);
  PERFORM public.derive_commerce_gaps(p_source_run_id);
  PERFORM public.derive_commerce_momentum(p_source_run_id);

  SELECT dna_extended->'commerce'->>'niche' INTO v_niche FROM public.member_business_dna WHERE user_id=v_user AND source_run_id=p_source_run_id;
  SELECT industry INTO v_industry FROM public.business_profiles WHERE user_id=v_user LIMIT 1;

  FOR p IN SELECT * FROM public.commerce_products WHERE source_run_id=p_source_run_id AND user_id=v_user AND product_role='own' LOOP
    SELECT count(DISTINCT s.signal_type) FILTER (WHERE s.provenance->>'signal'='OBSERVED' AND s.signal_type = ANY(base_types)),
           max(s.observed_at) FILTER (WHERE s.signal_type = ANY(base_types))
      INTO v_n_observed, v_last FROM public.commerce_signals s WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id;
    v_n_observed := coalesce(v_n_observed,0);
    SELECT count(DISTINCT coalesce(nullif(btrim(e->>'source_url'),''), nullif(btrim(e->>'claim'),''), lower(btrim(e->>'source_name'))))
      INTO v_sources FROM public.commerce_signals s, jsonb_array_elements(s.evidence) e
      WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id AND s.signal_type = ANY(base_types);
    v_sources := coalesce(v_sources,0);

    -- has at least one OBSERVED product fact (excludes attention) -> gates high_potential
    SELECT EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id
                  AND s.signal_type = ANY(pf_types) AND s.provenance->>'signal'='OBSERVED') INTO v_haspf;

    v_age := CASE WHEN v_last IS NULL THEN NULL ELSE extract(epoch FROM (now()-v_last))/86400.0 END;
    v_fresh := CASE WHEN v_age IS NULL THEN 0 WHEN v_age<=7 THEN 1 WHEN v_age<=30 THEN 0.75 WHEN v_age<=90 THEN 0.45 ELSE 0.2 END;
    v_stale := v_age IS NOT NULL AND v_age>90;
    v_avail := lower(coalesce(p.availability,'')); v_price_known := p.observed_price IS NOT NULL;
    v_fit := v_niche IS NOT NULL AND (coalesce(p.category,'') ILIKE '%'||split_part(v_niche,' ',1)||'%' OR coalesce(p.title,'') ILIKE '%'||split_part(v_niche,' ',1)||'%');

    SELECT (value->>'level') INTO v_comp_level FROM public.commerce_signals
      WHERE user_id=v_user AND source_run_id=p_source_run_id AND signal_type='competition_density' AND lower(value->>'category')=lower(coalesce(p.category,'')) LIMIT 1;
    SELECT signal_type INTO v_mom FROM public.commerce_signals
      WHERE product_id=p.id AND source_run_id=p_source_run_id AND signal_type IN ('price_down','price_up','back_in_stock','out_of_stock','product_appeared','prominence_up','prominence_down') ORDER BY observed_at DESC LIMIT 1;
    SELECT (value->>'strength') INTO v_demand FROM public.commerce_signals
      WHERE product_id=p.id AND source_run_id=p_source_run_id AND signal_type='demand_evidence' LIMIT 1;
    SELECT EXISTS(SELECT 1 FROM public.commerce_signals WHERE product_id=p.id AND source_run_id=p_source_run_id AND signal_type='differentiation_gap') INTO v_gap;
    SELECT (value->>'strength') INTO v_att FROM public.commerce_signals
      WHERE product_id=p.id AND source_run_id=p_source_run_id AND signal_type='market_attention_observed' LIMIT 1;

    v_factors := '{}'::jsonb; v_sum := 0; v_wsum := 0;
    IF v_avail IN ('in_stock','out_of_stock') THEN
      v_factors := v_factors || jsonb_build_object('availability_health', jsonb_build_object('score',CASE WHEN v_avail='in_stock' THEN 80 ELSE 20 END,'weight',0.20));
      v_sum := v_sum + (CASE WHEN v_avail='in_stock' THEN 80 ELSE 20 END)*0.20; v_wsum := v_wsum+0.20; END IF;
    IF v_price_known THEN
      v_factors := v_factors || jsonb_build_object('pricing_clarity', jsonb_build_object('score',60,'weight',0.08));
      v_sum := v_sum + 60*0.08; v_wsum := v_wsum+0.08; END IF;
    IF v_niche IS NOT NULL THEN
      v_factors := v_factors || jsonb_build_object('dna_fit', jsonb_build_object('score',CASE WHEN v_fit THEN 75 ELSE 30 END,'weight',0.22));
      v_sum := v_sum + (CASE WHEN v_fit THEN 75 ELSE 30 END)*0.22; v_wsum := v_wsum+0.22; END IF;
    IF v_comp_level IS NOT NULL AND v_comp_level <> 'LOW_EVIDENCE' THEN
      v_factors := v_factors || jsonb_build_object('competition_opportunity', jsonb_build_object('score',CASE v_comp_level WHEN 'LOW' THEN 80 WHEN 'MODERATE' THEN 50 ELSE 25 END,'weight',0.15,'basis',v_comp_level));
      v_sum := v_sum + (CASE v_comp_level WHEN 'LOW' THEN 80 WHEN 'MODERATE' THEN 50 ELSE 25 END)*0.15; v_wsum := v_wsum+0.15; END IF;
    IF v_mom IS NOT NULL THEN
      v_factors := v_factors || jsonb_build_object('momentum', jsonb_build_object('score',CASE WHEN v_mom IN ('price_down','back_in_stock','product_appeared','prominence_up') THEN 70 WHEN v_mom IN ('price_up','out_of_stock','product_disappeared','prominence_down') THEN 40 ELSE 50 END,'weight',0.10,'basis',v_mom));
      v_sum := v_sum + (CASE WHEN v_mom IN ('price_down','back_in_stock','product_appeared','prominence_up') THEN 70 WHEN v_mom IN ('price_up','out_of_stock','product_disappeared','prominence_down') THEN 40 ELSE 50 END)*0.10; v_wsum := v_wsum+0.10; END IF;
    IF v_demand IS NOT NULL AND v_demand <> 'INSUFFICIENT_EVIDENCE' THEN
      v_factors := v_factors || jsonb_build_object('demand_strength', jsonb_build_object('score',CASE v_demand WHEN 'STRONG' THEN 80 WHEN 'MODERATE' THEN 55 ELSE 35 END,'weight',0.15,'basis',v_demand,'provenance','RESEARCHED'));
      v_sum := v_sum + (CASE v_demand WHEN 'STRONG' THEN 80 WHEN 'MODERATE' THEN 55 ELSE 35 END)*0.15; v_wsum := v_wsum+0.15; END IF;
    IF v_att IS NOT NULL THEN
      v_factors := v_factors || jsonb_build_object('attention_strength', jsonb_build_object('score',CASE v_att WHEN 'STRONG' THEN 80 WHEN 'MODERATE' THEN 55 ELSE 35 END,'weight',0.15,'basis',v_att,'provenance','OBSERVED'));
      v_sum := v_sum + (CASE v_att WHEN 'STRONG' THEN 80 WHEN 'MODERATE' THEN 55 ELSE 35 END)*0.15; v_wsum := v_wsum+0.15; END IF;
    IF v_gap THEN
      v_factors := v_factors || jsonb_build_object('differentiation_gap', jsonb_build_object('score',75,'weight',0.10,'basis','demand_with_low_competition'));
      v_sum := v_sum + 75*0.10; v_wsum := v_wsum+0.10; END IF;

    v_score := CASE WHEN v_wsum=0 THEN NULL ELSE greatest(0, least(100, round(v_sum/v_wsum)::int)) END;

    -- CONFIDENCE: OBSERVED base evidence only (RESEARCHED demand / INFERRED competition never inflate it)
    v_conf := 0.30*least(v_n_observed,3)/3.0 + 0.30*least(v_sources,3)/3.0 + 0.25*v_fresh + 0.15*(CASE WHEN v_n_observed>0 THEN 1 ELSE 0 END);
    IF v_stale THEN v_conf := least(v_conf,0.60); END IF;
    v_conf := round(greatest(0, least(1, v_conf))::numeric, 2);
    v_factors := v_factors || jsonb_build_object('_confidence', jsonb_build_object('observed_signal_types',v_n_observed,'evidence_families',v_sources,'freshness',round(v_fresh*100)::int,'stale_capped',v_stale,'has_product_fact',v_haspf));

    v_class := CASE WHEN v_n_observed=0 OR v_conf<0.25 THEN 'insufficient_evidence'
      WHEN coalesce(v_score,0)>=70 AND v_conf>=0.65 AND v_haspf THEN 'high_potential'
      WHEN coalesce(v_score,0)>=55 THEN 'emerging' WHEN coalesce(v_score,0)>=35 THEN 'watch' ELSE 'deprioritized' END;
    v_decision := CASE v_class WHEN 'insufficient_evidence' THEN 'VALIDATE_FURTHER'
      WHEN 'high_potential' THEN CASE WHEN v_avail='in_stock' THEN 'PREPARE_OFFER' ELSE 'TEST' END
      WHEN 'emerging' THEN 'VALIDATE_FURTHER' WHEN 'watch' THEN 'WATCH' ELSE 'DEPRIORITIZE' END;

    v_pos := '[]'::jsonb; v_risk := '[]'::jsonb;
    IF v_avail='in_stock' THEN v_pos := v_pos||to_jsonb('In stock at observation'::text); END IF;
    IF v_fit THEN v_pos := v_pos||to_jsonb('Fits stated niche/category'::text); END IF;
    IF v_att IN ('STRONG','MODERATE') THEN v_pos := v_pos||to_jsonb(('Observed market attention: '||v_att)::text); END IF;
    IF v_demand IN ('STRONG','MODERATE') THEN v_pos := v_pos||to_jsonb(('Demand evidence: '||v_demand||' (researched)')::text); END IF;
    IF v_gap THEN v_pos := v_pos||to_jsonb('Differentiation gap (demand + low competition)'::text); END IF;
    IF v_comp_level='LOW' THEN v_pos := v_pos||to_jsonb('Low observed competition (proxy)'::text); END IF;
    IF v_mom IN ('price_down','back_in_stock','prominence_up','product_appeared') THEN v_pos := v_pos||to_jsonb(('Favorable momentum: '||v_mom)::text); END IF;
    IF v_n_observed>=2 THEN v_pos := v_pos||to_jsonb(('Observed across '||v_n_observed||' signal types')::text); END IF;

    IF v_avail='out_of_stock' THEN v_risk := v_risk||to_jsonb('Out of stock at observation'::text); END IF;
    IF v_comp_level='HIGH' THEN v_risk := v_risk||to_jsonb('High observed competition (proxy)'::text); END IF;
    IF v_demand='LOW' THEN v_risk := v_risk||to_jsonb('Weak demand evidence'::text); END IF;
    IF NOT v_haspf THEN v_risk := v_risk||to_jsonb('No observed product facts yet (attention/demand only) — validate before investing'::text); END IF;
    IF v_mom IN ('price_up','out_of_stock','prominence_down') THEN v_risk := v_risk||to_jsonb(('Unfavorable momentum: '||v_mom)::text); END IF;
    IF v_n_observed<=1 THEN v_risk := v_risk||to_jsonb('Thin observed evidence (≤1 type)'::text); END IF;
    IF v_sources<=1 THEN v_risk := v_risk||to_jsonb('Single evidence-family dependency'::text); END IF;
    IF v_stale THEN v_risk := v_risk||to_jsonb('Stale evidence (>90 days)'::text); END IF;
    IF v_niche IS NOT NULL AND NOT v_fit THEN v_risk := v_risk||to_jsonb('Unclear fit with stated niche'::text); END IF;

    SELECT CASE WHEN bool_or(s.provenance->>'signal'='OBSERVED') THEN 'OBSERVED'
                WHEN bool_or(s.provenance->>'signal'='RESEARCHED') THEN 'RESEARCHED'
                WHEN bool_or(s.provenance->>'signal'='INFERRED') THEN 'INFERRED' ELSE 'EXISTING_PULSE' END
      INTO v_prov FROM public.commerce_signals s WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id AND s.signal_type = ANY(base_types);
    v_prov := coalesce(v_prov,'INFERRED');

    v_why := CASE WHEN jsonb_array_length(v_pos)>0 THEN 'Strongest factors: '||(SELECT string_agg(x,'; ') FROM jsonb_array_elements_text(v_pos) x) ELSE 'Insufficient observed evidence to establish product-specific strengths.' END;
    v_whynow := CASE WHEN v_mom IN ('price_down','back_in_stock','prominence_up') THEN 'Recent change ('||v_mom||') supports acting soon.'
                     WHEN v_att IN ('STRONG','MODERATE') THEN 'Observed attention is currently '||v_att||' — worth investigating now.'
                     WHEN v_age IS NOT NULL AND v_age<=7 THEN 'Recent observation (within 7 days) supports acting soon.'
                     ELSE 'Current evidence does not establish unusual urgency.' END;
    SELECT coalesce(jsonb_agg(DISTINCT e),'[]'::jsonb) INTO v_evidence FROM public.commerce_signals s, jsonb_array_elements(s.evidence) e WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id;
    SELECT coalesce(jsonb_agg(s.id),'[]'::jsonb) INTO v_signals FROM public.commerce_signals s WHERE s.product_id=p.id AND s.source_run_id=p_source_run_id;

    INSERT INTO public.commerce_product_opportunities
      (user_id, product_id, source_run_id, overall_score, confidence, opportunity_class, factor_scores,
       positive_factors, risk_factors, evidence_refs, signal_refs, why_this_product, why_now,
       recommended_decision, recommended_actions, content_context, provenance, scoring_version, last_evidence_at)
    VALUES (v_user, p.id, p_source_run_id, v_score, v_conf, v_class, v_factors, v_pos, v_risk, v_evidence, v_signals, v_why, v_whynow, v_decision,
       CASE v_class WHEN 'high_potential' THEN jsonb_build_array('validate_supplier','test_price_point','create_product_creative','monitor_product_signal')
         WHEN 'emerging' THEN jsonb_build_array('inspect_competitor_positioning','monitor_product_signal') WHEN 'watch' THEN jsonb_build_array('monitor_product_signal')
         WHEN 'insufficient_evidence' THEN jsonb_build_array('gather_more_evidence') ELSE jsonb_build_array('deprioritize') END,
       jsonb_build_object('product_title',p.title,'category',p.category,'price',p.observed_price,'currency',p.price_currency,'availability',p.availability,
         'audience',coalesce(v_industry,v_niche),'angle',v_why,'differentiator',(v_pos->0),
         'claim_restrictions','No unverified sales/revenue/ROAS/units or best-seller claims.','cta',CASE WHEN v_class IN ('high_potential','emerging') THEN 'Learn more' ELSE NULL END),
       jsonb_build_object('opportunity',v_prov), v_ver, v_last)
    ON CONFLICT (user_id, product_id, source_run_id) DO UPDATE SET
       overall_score=excluded.overall_score, confidence=excluded.confidence, opportunity_class=excluded.opportunity_class,
       factor_scores=excluded.factor_scores, positive_factors=excluded.positive_factors, risk_factors=excluded.risk_factors,
       evidence_refs=excluded.evidence_refs, signal_refs=excluded.signal_refs, why_this_product=excluded.why_this_product,
       why_now=excluded.why_now, recommended_decision=excluded.recommended_decision, recommended_actions=excluded.recommended_actions,
       content_context=excluded.content_context, provenance=excluded.provenance, scoring_version=excluded.scoring_version, last_evidence_at=excluded.last_evidence_at;
    v_scored := v_scored+1;
  END LOOP;

  WITH ranked AS (
    SELECT id, row_number() OVER (ORDER BY (opportunity_class='insufficient_evidence') ASC, overall_score DESC NULLS LAST, confidence DESC NULLS LAST, last_evidence_at DESC NULLS LAST, product_id ASC) AS rn
    FROM public.commerce_product_opportunities WHERE user_id=v_user AND source_run_id=p_source_run_id)
  UPDATE public.commerce_product_opportunities o SET rank=ranked.rn FROM ranked WHERE o.id=ranked.id;

  RETURN jsonb_build_object('status','ok','scoring_version',v_ver,'scored',v_scored);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.select_product_supplier(p_acquisition_id uuid, p_supplier_index integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_row public.product_acquisitions%ROWTYPE;
    v_sup jsonb;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT * INTO v_row FROM public.product_acquisitions WHERE id = p_acquisition_id;
    IF NOT FOUND OR v_row.user_id <> v_uid THEN
        RETURN jsonb_build_object('status','not_found'); END IF;  -- no cross-tenant inference
    IF v_row.state <> 'SOURCED' THEN
        RETURN jsonb_build_object('status','invalid_transition','state', v_row.state); END IF;
    IF p_supplier_index IS NULL OR p_supplier_index < 0 THEN
        RETURN jsonb_build_object('status','invalid_request'); END IF;
    v_sup := v_row.sourcing_spec_snapshot->'supplier_options'->p_supplier_index;
    IF v_sup IS NULL THEN RETURN jsonb_build_object('status','supplier_not_found'); END IF;

    UPDATE public.product_acquisitions
       SET state='SELECTED', selected_supplier_snapshot = v_sup
     WHERE id = p_acquisition_id AND user_id = v_uid AND state='SOURCED';
    RETURN jsonb_build_object('status','selected','acquisition_id', p_acquisition_id, 'state','SELECTED');
END; $function$
;

CREATE OR REPLACE FUNCTION public.set_action_status(p_action_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_new   text;
  v_owner uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','unauthenticated');
  END IF;

  v_new := lower(btrim(coalesce(p_status, '')));
  IF v_new NOT IN ('open','done','dismissed') THEN
    RETURN jsonb_build_object('status','invalid_status');
  END IF;

  SELECT user_id INTO v_owner FROM public.member_actions WHERE id = p_action_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','not_found');
  END IF;
  IF v_owner IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('status','forbidden');
  END IF;

  UPDATE public.member_actions
     SET status = v_new
   WHERE id = p_action_id AND user_id = v_uid;

  RETURN jsonb_build_object('status','ok','action_id', p_action_id, 'action_status', v_new);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.start_content_generation(p_rank integer, p_content_type text, p_platform text DEFAULT NULL::text, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_member_id uuid;
    v_run uuid;
    v_opp public.member_opportunities%ROWTYPE;
    v_existing uuid;
    v_id uuid;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    IF p_content_type NOT IN ('SOCIAL_POST','SHORT_VIDEO_SCRIPT','LONG_VIDEO_SCRIPT') THEN
        RETURN jsonb_build_object('status','invalid_content_type'); END IF;
    SELECT m.id INTO v_member_id FROM public.member m WHERE m.auth_user_id = v_uid;
    IF v_member_id IS NULL THEN RETURN jsonb_build_object('status','no_member'); END IF;
    SELECT source_run_id INTO v_run FROM public.member_business_dna WHERE user_id = v_uid;
    IF v_run IS NULL THEN RETURN jsonb_build_object('status','no_intelligence'); END IF;
    SELECT * INTO v_opp FROM public.member_opportunities
        WHERE user_id = v_uid AND source_run_id = v_run AND rank = p_rank;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','opportunity_not_found'); END IF;

    -- De-dup: reuse an already-queued identical request instead of enqueuing again.
    SELECT id INTO v_existing FROM public.member_generated_content
     WHERE user_id = v_uid AND source_run_id = v_run AND rank = p_rank
       AND content_type = p_content_type AND status = 'queued'
     ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('status','queued','content_id',v_existing,
            'rank',p_rank,'content_type',p_content_type,'deduped',true);
    END IF;

    INSERT INTO public.member_generated_content
        (user_id, member_opportunity_id, source_run_id, rank, content_type, platform, request, status)
    VALUES (v_uid, v_opp.id, v_run, p_rank, p_content_type,
        nullif(btrim(coalesce(p_platform,'')),''),
        jsonb_build_object('platform', nullif(btrim(coalesce(p_platform,'')),''),
                           'options', coalesce(p_options,'{}'::jsonb)),
        'queued')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('status','queued','content_id', v_id, 'rank', p_rank, 'content_type', p_content_type);
END; $function$
;

CREATE OR REPLACE FUNCTION public.submit_feedback(p_subject_type text, p_rank integer DEFAULT NULL::integer, p_content_id uuid DEFAULT NULL::uuid, p_useful boolean DEFAULT NULL::boolean, p_acted boolean DEFAULT NULL::boolean, p_comment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_run uuid; v_id uuid; v_ok boolean;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    IF p_subject_type NOT IN ('opportunity','content') THEN RETURN jsonb_build_object('status','invalid_subject'); END IF;
    SELECT source_run_id INTO v_run FROM public.member_business_dna WHERE user_id = v_uid;

    IF p_subject_type = 'opportunity' THEN
        IF p_rank IS NULL OR v_run IS NULL THEN RETURN jsonb_build_object('status','invalid_target'); END IF;
        SELECT EXISTS (SELECT 1 FROM public.member_opportunities
            WHERE user_id = v_uid AND source_run_id = v_run AND rank = p_rank) INTO v_ok;
        IF NOT v_ok THEN RETURN jsonb_build_object('status','not_owned'); END IF;
    ELSE
        IF p_content_id IS NULL THEN RETURN jsonb_build_object('status','invalid_target'); END IF;
        SELECT EXISTS (SELECT 1 FROM public.member_generated_content
            WHERE id = p_content_id AND user_id = v_uid) INTO v_ok;
        IF NOT v_ok THEN RETURN jsonb_build_object('status','not_owned'); END IF;
    END IF;

    INSERT INTO public.member_feedback (user_id, subject_type, source_run_id, rank, content_id, useful, acted, comment)
    VALUES (v_uid, p_subject_type, v_run,
        CASE WHEN p_subject_type='opportunity' THEN p_rank ELSE NULL END,
        CASE WHEN p_subject_type='content' THEN p_content_id ELSE NULL END,
        p_useful, p_acted,
        nullif(left(regexp_replace(coalesce(p_comment,''),'[[:cntrl:]]',' ','g'), 2000),''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('status','ok','feedback_id', v_id);
END; $function$
;

CREATE OR REPLACE FUNCTION public.tg_marketing_campaign_drafts_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tg_marketing_campaign_executions_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin new.updated_at = now(); return new; end;
$function$
;

CREATE OR REPLACE FUNCTION public.upsert_tenant_product_evaluation(p_product_id uuid, p_factor_scores jsonb, p_overall_score integer, p_opportunity_class text, p_recommended_decision text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_gid uuid := public.fn_global_intelligence_uid();
        v_owner uuid; v_vis text; v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT user_id, visibility INTO v_owner, v_vis FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF NOT ((v_owner = v_gid AND v_vis = 'GLOBAL_SAFE') OR v_owner = v_uid) THEN
    RETURN jsonb_build_object('status','forbidden_reference');
  END IF;

  UPDATE public.commerce_product_opportunities
     SET factor_scores = coalesce(p_factor_scores,'{}'::jsonb), overall_score = p_overall_score,
         opportunity_class = p_opportunity_class, recommended_decision = p_recommended_decision,
         provenance = jsonb_build_object('source','tenant_evaluation','classification','TENANT_PRIVATE'),
         scoring_version = 'tenancy_foundation_v1', updated_at = now()
   WHERE user_id = v_uid AND product_id = p_product_id AND source_run_id IS NULL
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO public.commerce_product_opportunities
      (user_id, product_id, source_run_id, overall_score, opportunity_class, factor_scores,
       recommended_decision, provenance, scoring_version)
    VALUES (v_uid, p_product_id, NULL, p_overall_score, p_opportunity_class, coalesce(p_factor_scores,'{}'::jsonb),
       p_recommended_decision, jsonb_build_object('source','tenant_evaluation','classification','TENANT_PRIVATE'),'tenancy_foundation_v1')
    RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('status','ok','evaluation_id', v_id, 'references_global', (v_owner = v_gid));
END; $function$
;

CREATE OR REPLACE FUNCTION public.upsert_tenant_product_evaluation_v2(p_product_id uuid, p_target_market text, p_factor_scores jsonb, p_overall_score integer, p_opportunity_class text, p_recommended_decision text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_gid uuid := public.fn_global_intelligence_uid();
        v_owner uuid; v_vis text; v_id uuid; v_mkt text := upper(nullif(btrim(p_target_market),''));
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_mkt IS NULL THEN RETURN jsonb_build_object('status','target_market_required'); END IF;
  SELECT user_id, visibility INTO v_owner, v_vis FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF NOT ((v_owner = v_gid AND v_vis = 'GLOBAL_SAFE') OR v_owner = v_uid) THEN
    RETURN jsonb_build_object('status','forbidden_reference');
  END IF;

  UPDATE public.commerce_product_opportunities
     SET factor_scores = coalesce(p_factor_scores,'{}'::jsonb), overall_score = p_overall_score,
         opportunity_class = p_opportunity_class, recommended_decision = p_recommended_decision,
         provenance = jsonb_build_object('source','tenant_evaluation_v2','classification','TENANT_PRIVATE','target_market',v_mkt),
         scoring_version = 'wps_v2', updated_at = now()
   WHERE user_id = v_uid AND product_id = p_product_id AND source_run_id IS NULL AND coalesce(target_market,'__GLOBAL__') = v_mkt
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO public.commerce_product_opportunities
      (user_id, product_id, source_run_id, target_market, overall_score, opportunity_class, factor_scores,
       recommended_decision, provenance, scoring_version)
    VALUES (v_uid, p_product_id, NULL, v_mkt, p_overall_score, p_opportunity_class, coalesce(p_factor_scores,'{}'::jsonb),
       p_recommended_decision, jsonb_build_object('source','tenant_evaluation_v2','classification','TENANT_PRIVATE','target_market',v_mkt),'wps_v2')
    RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('status','ok','evaluation_id', v_id, 'target_market', v_mkt, 'references_global', (v_owner = v_gid));
END; $function$
;

CREATE OR REPLACE FUNCTION public.validate_invitation(p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE PARALLEL RESTRICTED
 SET search_path TO ''
AS $function$
DECLARE
    v_count       integer;
    v_id          uuid;
    v_app_ref     uuid;
    v_status      text;
    v_expires_at  timestamptz;
    v_effective   text;
BEGIN
    -- 1. Canonical stored-hash structural guard: exactly 64 lowercase hexadecimal
    --    characters. NULL, empty, wrong-length, uppercase, and non-hex inputs all
    --    fail closed here and are externally indistinguishable from an absent
    --    invitation. The value is never trimmed, lowercased, repaired, echoed,
    --    logged, or surfaced as a diagnostic.
    IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN jsonb_build_object('result', 'not_found');
    END IF;

    -- 2. Single-snapshot aggregate over the UNIQUE token_hash key. count(*) and the
    --    aggregated single-row values derive from one scan; there is no second scan,
    --    no arbitrary single-row pick, and no row lock. PostgreSQL 17 has no built-in
    --    min(uuid), so uuids are aggregated via canonical text and cast back; the
    --    aggregated values are consumed only when the count is exactly 1 (min over a
    --    single value returns that value).
    SELECT count(*),
           min(i.id::text)::uuid,
           min(i.application_ref::text)::uuid,
           min(i.status),
           min(i.expires_at)
      INTO v_count, v_id, v_app_ref, v_status, v_expires_at
    FROM public.invitation AS i
    WHERE i.token_hash = p_token_hash;

    -- 3. Cardinality. Zero matches is not_found; more than one match is impossible
    --    under the UNIQUE key and fails closed with a fixed generic message that
    --    carries no hash, identifier, row value, constraint name, or error detail.
    IF v_count = 0 THEN
        RETURN jsonb_build_object('result', 'not_found');
    ELSIF v_count > 1 THEN
        RAISE EXCEPTION 'invitation validation cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    -- 4. Effective lifecycle status from PostgreSQL transaction time. An issued
    --    invitation whose expiry moment has passed (inclusive) is effectively
    --    expired without mutating the stored row. Successor linkage is neither read
    --    nor classified here; the atomic acceptance function remains the sole
    --    authority for successor and revocation integrity.
    IF v_status = 'issued' AND v_expires_at <= transaction_timestamp() THEN
        v_effective := 'expired';
    ELSE
        v_effective := v_status;
    END IF;

    -- 5. Minimum non-secret projection. The observed nullable application reference
    --    is preserved as JSON null and is never rejected here (U4 classifies an
    --    issued invitation with a null application reference). No hash, no email
    --    binding, no timestamps, and no successor linkage are returned.
    RETURN jsonb_build_object(
        'result', 'found',
        'invitation_id', v_id,
        'application_ref', v_app_ref,
        'effective_status', v_effective
    );
END;
$function$
;

