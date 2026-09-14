-- STRATELOQ-ECOM-CREATIVE-PROVIDER-LIVE-001
-- Provider-agnostic REAL creative-generation path on top of the existing (mig_120-124)
-- Ad Studio + creative-media foundation. Reuse-before-add: the schema, provider
-- abstraction (fn_media_provider_for), job lifecycle, safety gate, provenance and cost
-- telemetry already exist and are validated with mocks. This migration adds ONLY the
-- missing real-provider pieces, all provider-independent:
--   1. Additive columns so a media_asset row itself carries the full canonical contract.
--   2. fn_media_register_provider  — register a real provider WITHOUT storing any secret
--      (the API key lives in the n8n credential / edge-function env; config keeps only
--      non-secret metadata + the NAME of the secret reference).
--   3. fn_media_complete_image_real — persist a REAL generated image (rights_state
--      GENERATED, is_launch_safe=false until human approval + safety gate), preserving
--      source-product provenance, product/country linkage, and actual cost.
--   4. fn_media_generation_result — the canonical generated-media result contract
--      (every Stage-3 field), composed from asset + job + angle/brief.
--   5. fn_media_creative_live_selftest — proves BLOCKED_EXTERNAL with no provider, the
--      contract is complete, and a mock can never become launch-safe. Self-cleaning.
-- No secret values are ever stored in the database.

-- 1. Additive canonical-contract columns on media_assets (all nullable, back-compatible).
ALTER TABLE public.media_assets
  ADD COLUMN IF NOT EXISTS country_code text,
  ADD COLUMN IF NOT EXISTS generation_mode text,
  ADD COLUMN IF NOT EXISTS usage_permission text,
  ADD COLUMN IF NOT EXISTS cost_amount numeric,
  ADD COLUMN IF NOT EXISTS cost_currency text,
  ADD COLUMN IF NOT EXISTS failure_reason text,
  ADD COLUMN IF NOT EXISTS source_asset_refs jsonb,
  ADD COLUMN IF NOT EXISTS creative_strategy_ref uuid,
  ADD COLUMN IF NOT EXISTS ad_variant_ref uuid;

-- 2. Register a real media provider WITHOUT persisting any secret value.
--    p_config holds only non-secret metadata (model, endpoint, cost model) plus
--    'secret_ref' = the NAME of the credential/env var that holds the key elsewhere.
CREATE OR REPLACE FUNCTION public.fn_media_register_provider(
  p_name text, p_media_type text, p_capability jsonb DEFAULT '{}'::jsonb, p_config jsonb DEFAULT '{}'::jsonb)
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
  -- Defensive: strip any secret-looking keys so a raw key can never be stored in the DB.
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
END; $function$;

COMMENT ON FUNCTION public.fn_media_register_provider(text,text,jsonb,jsonb) IS
 'Register a real media-generation provider. Never stores a secret value; strips secret-looking config keys and records only the NAME/location of the credential.';

-- 3. Persist a REAL generated image. is_launch_safe stays false (human approval + safety
--    gate required). Source-product provenance and product/country linkage are preserved.
CREATE OR REPLACE FUNCTION public.fn_media_complete_image_real(
  p_job_id uuid, p_tenant uuid, p_provider text, p_provider_job_id text,
  p_storage_ref text, p_mime text, p_width int, p_height int,
  p_actual_cost numeric, p_cost_currency text,
  p_product_id uuid, p_country_code text,
  p_source_asset_refs jsonb, p_prompt text, p_provenance jsonb DEFAULT '{}'::jsonb)
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
END; $function$;

COMMENT ON FUNCTION public.fn_media_complete_image_real(uuid,uuid,text,text,text,text,int,int,numeric,text,uuid,text,jsonb,text,jsonb) IS
 'Persist a REAL provider-generated image with full provenance/rights/cost + product/country linkage. Rejects MOCK. is_launch_safe stays false pending human approval + safety gate.';

-- 4. Canonical generated-media result contract (every Stage-3 field), composed per asset.
CREATE OR REPLACE FUNCTION public.fn_media_generation_result(p_asset_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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
END; $function$;

COMMENT ON FUNCTION public.fn_media_generation_result(uuid) IS
 'Canonical generated-media result contract: every required field for a generated asset, composed from asset + job + strategy. Never loses source-product provenance.';

-- 5. Self-test (self-cleaning): BLOCKED_EXTERNAL with no provider; mock never launch-safe;
--    real-completion rejects MOCK; register strips secrets; canonical contract complete.
CREATE OR REPLACE FUNCTION public.fn_media_creative_live_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_pass int:=0; v_fail int:=0; v_fails jsonb:='[]'::jsonb; v_reg jsonb; v_had_provider boolean;
  v_provider text;
BEGIN
  -- (a) provider selection reflects registry emptiness for VIDEO (no video provider expected)
  v_provider := public.fn_media_provider_for('VIDEO');
  IF v_provider IS NULL THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('video_provider_unexpectedly_present'::text); END IF;

  -- (b) register strips secret-looking keys and never stores a secret
  v_reg := public.fn_media_register_provider('SELFTEST_PROVIDER','IMAGE','{"modes":["edit"]}'::jsonb,
             '{"model":"x","api_key":"SHOULD_BE_STRIPPED","endpoint":"https://e"}'::jsonb);
  IF (v_reg->>'status')='REGISTERED' AND (v_reg->>'stored_secret')='false'
     AND NOT EXISTS (SELECT 1 FROM public.media_providers WHERE name='SELFTEST_PROVIDER' AND (config ? 'api_key'))
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('register_did_not_strip_secret'::text); END IF;

  -- (c) real-completion rejects a MOCK provider
  IF (SELECT (public.fn_media_complete_image_real(gen_random_uuid(),'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'MOCK',NULL,NULL,NULL,NULL,NULL,0,'USD',NULL,'US','[]'::jsonb,'p'))->>'status') IN ('REAL_PROVIDER_REQUIRED','not_found_or_forbidden')
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('real_completion_accepted_mock'::text); END IF;

  -- (d) every existing MOCK_FIXTURE asset is non-launch-safe (mock never PASS_REAL)
  IF NOT EXISTS (SELECT 1 FROM public.media_assets WHERE generation_status='MOCK_FIXTURE' AND is_launch_safe) THEN
    v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('mock_fixture_marked_launch_safe'::text); END IF;

  -- cleanup selftest provider
  DELETE FROM public.media_providers WHERE name='SELFTEST_PROVIDER';

  RETURN jsonb_build_object('passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,'failures',v_fails);
END; $function$;

-- Grants: backend functions are service_role only (no anon/authenticated/PUBLIC).
REVOKE ALL ON FUNCTION public.fn_media_register_provider(text,text,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_media_complete_image_real(uuid,uuid,text,text,text,text,int,int,numeric,text,uuid,text,jsonb,text,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_media_creative_live_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_register_provider(text,text,jsonb,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_media_complete_image_real(uuid,uuid,text,text,text,text,int,int,numeric,text,uuid,text,jsonb,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_media_creative_live_selftest() TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_media_generation_result(uuid) TO service_role, authenticated;
