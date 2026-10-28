-- ============================================================================
-- mig_294_stage2_research_vs_confirmation_eligibility.sql
-- STRATELOQ-STAGE4B-SUPPLIER-RESEARCH-ELIGIBILITY
--
-- DEFECT (proven): the Stage-2 CJ dispatch gate fn_stage2_cj_search_claim admitted a
-- product for CJ SUPPLIER RESEARCH only when fn_stage1_supplier_resolution_qualified was
-- true, i.e. (>=2 qualifying evidence families) AND NOT (observed_high_saturation OR
-- branded_or_ip OR identity_ambiguous). That conflates RESEARCH eligibility with
-- CONFIRMATION eligibility: it refused to even SEARCH CJ for identity-ambiguous or
-- market-saturated products — exactly the products where CJ evidence could RESOLVE the
-- ambiguity. Result: all 89 current opportunities were gated out of dispatch.
--
-- FIX (smallest safe change — only this RPC changes): split the two gates.
--   RESEARCH eligibility (this gate): (qualifying_family_count >= 2) AND NOT branded_or_ip.
--     Identity ambiguity and observed saturation NO LONGER block research. Research stays
--     bounded: still needs >=2 independent country-specific evidence families (fail-closed
--     on thin evidence), still blocks branded/IP, still tenant+country scoped, still
--     deduplicated via commerce_stage2_search_request, still budget/rate-limited downstream.
--   CONFIRMATION eligibility (UNCHANGED): fn_stage1_supplier_resolution_qualified stays the
--     strict "worth exact resolution" gate (its selftests + fn_stage1_early_opportunity_state
--     are untouched), and the resolver fn_stage2_resolve_from_pages still requires exact
--     product + variant evidence before binding a SKU. So identity ambiguity can justify
--     research but can NEVER produce a confirmed binding.
--
-- Contract preserved: same error code 'STAGE2_NOT_SUPPLIER_QUALIFIED' on rejection (so the
-- fail-closed boundary selftest stays green), same claim/dedup insert, same ok/proceed/
-- duplicate shape n8n consumes. Advisory fields added: research_eligible,
-- confirmation_qualified, research_block_reason. No CJ call is made by this RPC.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_search_claim(p_tenant uuid, p_product_id uuid, p_market text, p_request_id text, p_search_query text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_rid text := btrim(coalesce(p_request_id,''));
  v_id uuid; r record; v_q jsonb;
  v_qfc int; v_branded boolean; v_confirm boolean; v_research boolean;
begin
  if p_tenant is null then return jsonb_build_object('ok',false,'error','tenant_required'); end if;
  if p_product_id is null then return jsonb_build_object('ok',false,'error','product_required'); end if;
  if v_mkt = '' then return jsonb_build_object('ok',false,'error','market_required'); end if;
  if v_rid = '' then return jsonb_build_object('ok',false,'error','request_id_required'); end if;

  perform 1 from public.commerce_products where id = p_product_id and user_id = p_tenant;
  if not found then
    return jsonb_build_object('ok',false,'error','product_not_found_for_tenant');
  end if;

  v_q := public.fn_stage1_supplier_resolution_qualified(p_tenant, p_product_id, v_mkt);
  v_qfc     := coalesce((v_q->>'qualifying_family_count')::int, 0);
  v_branded := coalesce((v_q->'disqualifiers'->>'branded_or_ip')::boolean, false);
  v_confirm := coalesce((v_q->>'stage1_supplier_resolution_qualified')::boolean, false);
  -- RESEARCH gate: enough independent evidence + not branded/IP. Saturation and identity
  -- ambiguity are NOT research blockers (they remain confirmation blockers).
  v_research := (v_qfc >= 2) and not v_branded;

  if not v_research then
    return jsonb_build_object(
      'ok', false, 'proceed', false, 'claimed', false,
      'error','STAGE2_NOT_SUPPLIER_QUALIFIED',
      'research_eligible', false,
      'research_block_reason', case when v_branded then 'BRANDED_OR_IP' else 'INSUFFICIENT_EVIDENCE_FAMILIES' end,
      'confirmation_qualified', v_confirm,
      'qualifying_family_count', v_q->'qualifying_family_count',
      'disqualifiers', v_q->'disqualifiers',
      'reasons', v_q->'reasons',
      'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
  end if;

  insert into public.commerce_stage2_search_request
    (tenant_id, opportunity_product_id, market, request_id, search_query)
  values (p_tenant, p_product_id, v_mkt, v_rid, p_search_query)
  on conflict (tenant_id, opportunity_product_id, market, request_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('ok',true,'proceed',true,'claimed',true,'duplicate',false,'status','CLAIMED',
      'research_eligible', true, 'confirmation_qualified', v_confirm,
      'disqualifiers', v_q->'disqualifiers', 'qualifying_family_count', v_q->'qualifying_family_count',
      'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
  end if;

  select * into r from public.commerce_stage2_search_request
   where tenant_id = p_tenant and opportunity_product_id = p_product_id and market = v_mkt and request_id = v_rid;
  return jsonb_build_object('ok',true,'proceed',false,'claimed',false,'duplicate',true,
    'status', r.status, 'provider_called', r.provider_called, 'result', r.result,
    'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
end;
$function$;
