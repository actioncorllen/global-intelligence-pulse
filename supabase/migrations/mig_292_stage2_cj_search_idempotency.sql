-- mig_292_stage2_cj_search_idempotency
-- Stage-2E persistent, concurrency-safe idempotency for the CJ supplier-search operation.
-- Invariant: one logical request (tenant_id, product_id, market, request_id) must not create
-- multiple CJ searches. A duplicate (double-click, retry, duplicate webhook, replay) reuses the
-- existing state and must NOT reach CJ again. Mirrors the existing Strateloq idempotency pattern
-- (social_publish_attempts.idempotency_key + unique index).

create table if not exists public.commerce_stage2_search_request (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null,
  opportunity_product_id uuid not null,
  market                 text not null,
  request_id             text not null,
  search_query           text,
  status                 text not null default 'CLAIMED',   -- CLAIMED -> DONE
  provider_called        boolean not null default false,
  result                 jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint commerce_stage2_search_request_idem_uk
    unique (tenant_id, opportunity_product_id, market, request_id)
);

comment on table public.commerce_stage2_search_request is
  'Stage-2E CJ supplier-search idempotency ledger. One row per logical request (tenant,product,market,request_id). The unique constraint is the concurrency-safe gate: only the single INSERT that wins may call CJ.';

alter table public.commerce_stage2_search_request enable row level security;
-- No policies: reachable only via SECURITY DEFINER functions / service_role (least privilege).

-- Atomic claim. Returns proceed=true to EXACTLY ONE caller per logical key (the one whose INSERT wins).
-- Fails closed if the tenant does not own the product or any key field is missing.
create or replace function public.fn_stage2_cj_search_claim(
  p_tenant uuid, p_product_id uuid, p_market text, p_request_id text, p_search_query text default null
) returns jsonb
  language plpgsql
  security definer
  set search_path to ''
as $function$
declare
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_rid text := btrim(coalesce(p_request_id,''));
  v_id uuid; r record;
begin
  if p_tenant is null then return jsonb_build_object('ok',false,'error','tenant_required'); end if;
  if p_product_id is null then return jsonb_build_object('ok',false,'error','product_required'); end if;
  if v_mkt = '' then return jsonb_build_object('ok',false,'error','market_required'); end if;
  if v_rid = '' then return jsonb_build_object('ok',false,'error','request_id_required'); end if;

  perform 1 from public.commerce_products where id = p_product_id and user_id = p_tenant;
  if not found then
    return jsonb_build_object('ok',false,'error','product_not_found_for_tenant');
  end if;

  insert into public.commerce_stage2_search_request
    (tenant_id, opportunity_product_id, market, request_id, search_query)
  values (p_tenant, p_product_id, v_mkt, v_rid, p_search_query)
  on conflict (tenant_id, opportunity_product_id, market, request_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('ok',true,'proceed',true,'claimed',true,'duplicate',false,'status','CLAIMED',
      'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
  end if;

  select * into r from public.commerce_stage2_search_request
   where tenant_id = p_tenant and opportunity_product_id = p_product_id and market = v_mkt and request_id = v_rid;
  return jsonb_build_object('ok',true,'proceed',false,'claimed',false,'duplicate',true,
    'status', r.status, 'provider_called', r.provider_called, 'result', r.result,
    'logical_key', jsonb_build_object('tenant_id',p_tenant,'product_id',p_product_id,'market',v_mkt,'request_id',v_rid));
end;
$function$;

-- Record the result for the claimed row (idempotent; only the owning logical key is updated).
create or replace function public.fn_stage2_cj_search_complete(
  p_tenant uuid, p_product_id uuid, p_market text, p_request_id text, p_result jsonb, p_provider_called boolean default true
) returns jsonb
  language plpgsql
  security definer
  set search_path to ''
as $function$
declare
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_rid text := btrim(coalesce(p_request_id,''));
  r record;
begin
  update public.commerce_stage2_search_request as t
     set status = 'DONE', provider_called = coalesce(p_provider_called,true), result = p_result, updated_at = now()
   where t.tenant_id = p_tenant and t.opportunity_product_id = p_product_id and t.market = v_mkt and t.request_id = v_rid
   returning * into r;
  if not found then return jsonb_build_object('ok',false,'error','claim_not_found'); end if;
  return jsonb_build_object('ok',true,'status',r.status,'provider_called',r.provider_called);
end;
$function$;

grant execute on function public.fn_stage2_cj_search_claim(uuid,uuid,text,text,text) to service_role;
grant execute on function public.fn_stage2_cj_search_complete(uuid,uuid,text,text,jsonb,boolean) to service_role;
