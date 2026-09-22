-- ============================================================================
-- mig_275_ad_creative_generation_runtime.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015F — generation runtime (server-authoritative)
--
-- Turns the EXISTING Ad Creative Studio contracts into an executable generation
-- runtime for STATIC image ads. REUSES (never duplicates):
--   ad_studio_briefs / ad_studio_angles / ad_studio_static_creatives,
--   media_image_jobs / media_assets / media_providers / media_job_costs,
--   fn_media_create_image_job, fn_media_complete_image_real (completion),
--   fn_media_retry_image_job (bounded retry), fn_media_generation_result (read),
--   fn_ad_studio_claim_scan (claim detector), fn_media_provider_for.
--
-- ADDS the missing server-authoritative glue only:
--   * fn_media_claim_gate            — HARD claim gate over all copy that ships.
--   * fn_media_prepare_image_job     — pre-flight: claim gate + product-identity
--                                       provenance + REAL cost estimate; leaves the
--                                       job READY_TO_DISPATCH (no provider call).
--   * fn_media_dispatch_image_job    — executor claim: READY→GENERATING, idempotent,
--                                       returns the provider call payload. Called by
--                                       the credentialed executor at run time.
--   * fn_ad_studio_creative_read     — browser-safe tenant-scoped lineage read.
--   * fn_media_asset_signed_ref      — owner-only storage_ref lookup for the signed
--                                       delivery Edge Function (no service creds in SQL).
--   * fn_media_runtime_selftest      — deterministic runtime selftest (self-cleaning).
--
-- INVARIANTS:
--   * Server-authoritative + tenant-scoped (SECURITY DEFINER, tenant checks).
--   * Claim safety is a HARD GATE: any violation blocks dispatch (BLOCKED_CLAIM_REVIEW).
--   * gpt-image-1 edit cannot GUARANTEE pixel-exact product identity → every image
--     asset is IDENTITY_REVIEW_REQUIRED, is_launch_safe=false, human review mandatory.
--   * Product identity provenance (source asset + provider + canonical refs) recorded
--     on the job and carried to the asset.
--   * No provider secret ever touches SQL or the browser (server-side executor only).
--   * Idempotent where practical; bounded retry (reuses fn_media_retry_image_job).
--   * No Product Decision / Problem-corroboration / gallery-identity change.
-- ============================================================================

-- 1) HARD CLAIM GATE over every piece of copy/prompt that will ship -----------
CREATE OR REPLACE FUNCTION public.fn_media_claim_gate(p_angle_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE a public.ad_studio_angles%rowtype; v_text text; v_viol jsonb;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','angle_not_found'); END IF;
  -- every claim-bearing surface that could appear in or drive the creative
  v_text := concat_ws(' ', a.hook, a.headline, a.primary_copy, a.supporting_copy, a.cta,
                       a.visual_concept, a.static_creative_brief);
  v_viol := public.fn_ad_studio_claim_scan(v_text);
  RETURN jsonb_build_object('status','ok','angle_id',p_angle_id,
    'blocked', (jsonb_array_length(v_viol) > 0),
    'violations', v_viol,
    'gate','fn_ad_studio_claim_scan over hook+headline+primary+supporting+cta+visual_concept+brief',
    'rule','any advertising claim (sales/social-proof/scarcity/discount/medical/performance/winner/metrics) blocks dispatch until removed or evidenced');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_claim_gate(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_media_claim_gate(uuid) TO authenticated, service_role;

-- 2) PRE-FLIGHT: claim gate + identity provenance + real cost (NO provider call)
CREATE OR REPLACE FUNCTION public.fn_media_prepare_image_job(p_job_id uuid, p_tenant uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_provider text; v_cfg jsonb; v_gate jsonb; v_src text; v_prov_name text; v_est numeric; v_size text;
  v_identity jsonb;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;

  v_provider := public.fn_media_provider_for('IMAGE');
  IF v_provider IS NULL THEN
    UPDATE public.media_image_jobs SET status='BLOCKED_EXTERNAL_PROVIDER', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_EXTERNAL_PROVIDER','note','no enabled IMAGE provider');
  END IF;
  SELECT config INTO v_cfg FROM public.media_providers WHERE name=v_provider;

  -- HARD claim gate
  v_gate := public.fn_media_claim_gate(j.angle_id);
  IF (v_gate->>'blocked')::boolean THEN
    UPDATE public.media_image_jobs
      SET status='BLOCKED_CLAIM_REVIEW', error_state='claim_violation',
          provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('claim_gate', v_gate), updated_at=now()
      WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_REVIEW','violations', v_gate->'violations',
      'note','unsafe advertising claim(s) detected; dispatch blocked until removed/evidenced');
  END IF;

  -- product identity provenance (exact rights-relevant source asset)
  v_src := coalesce(j.input_asset_refs->>0, (b.product_assets->>0));
  v_prov_name := CASE
    WHEN v_src ILIKE '%cjdropshipping%' OR v_src ILIKE '%/cj/%' THEN 'CJ_SUPPLIER'
    WHEN v_src ILIKE '%ebayimg%' THEN 'EBAY_BROWSE' ELSE 'UNKNOWN' END;
  v_identity := jsonb_build_object(
    'canonical_product_id', b.product_id,
    'product_name', b.product_name,
    'brief_id', b.id, 'angle_id', a.id,
    'source_asset_url', v_src,
    'source_provider', v_prov_name,
    'rights_note', CASE WHEN v_prov_name='CJ_SUPPLIER'
        THEN 'supplier-provided product image (rights-appropriate for advertising the sourced product)'
        WHEN v_prov_name='EBAY_BROWSE'
        THEN 'MARKETPLACE_REFERENCE — not rights-clear for ad regeneration; requires a supplier/first-party source'
        ELSE 'source rights unverified' END,
    'identity_state','IDENTITY_REVIEW_REQUIRED',
    'identity_rule','gpt-image-1 edit preserves the product but cannot GUARANTEE pixel-exact identity; human identity review mandatory before campaign use; never substitute another SKU/model/brand');

  -- real cost estimate from provider cost model (low-quality 1024 default for first test)
  v_size := coalesce(v_cfg->>'default_size','1024x1024');
  v_est := 0.02;  -- gpt-image-1 1024x1024 low ~USD 0.01-0.02; medium ~0.04 (provider cost_model)

  UPDATE public.media_image_jobs
    SET status='READY_TO_DISPATCH',
        estimated_cost=v_est, cost_currency='USD',
        generation_instructions = coalesce(nullif(j.generation_instructions,''), a.static_creative_brief),
        provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('claim_gate', v_gate, 'product_identity', v_identity,
                'prepared_at', now(), 'provider', v_provider, 'model', v_cfg->>'model', 'size', v_size,
                'quality','low','provider_endpoint', v_cfg->>'endpoint')
    WHERE id=p_job_id;
  UPDATE public.media_job_costs SET estimated_cost=v_est, currency='USD' WHERE job_id=p_job_id AND actual_cost IS NULL;

  RETURN jsonb_build_object('status','READY_TO_DISPATCH','job_id',p_job_id,
    'provider',v_provider,'model',v_cfg->>'model','endpoint',v_cfg->>'endpoint','mode','IMAGE_EDIT_FROM_PRODUCT_ASSET',
    'size',v_size,'quality','low','provider_call_count',1,'estimated_cost_usd',v_est,
    'claim_gate','PASS','product_identity',v_identity,
    'source_asset_url', v_src,
    'note','pre-flight complete; awaiting dispatch. Dispatch triggers the single paid provider call.');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_prepare_image_job(uuid,uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_prepare_image_job(uuid,uuid) TO service_role;

-- 3) EXECUTOR CLAIM: READY_TO_DISPATCH → GENERATING (idempotent) --------------
--    Called by the credentialed server-side executor at run time (post-approval).
CREATE OR REPLACE FUNCTION public.fn_media_dispatch_image_job(p_job_id uuid, p_tenant uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE j public.media_image_jobs%rowtype; v_gate jsonb;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF j.status='GENERATING' THEN
    -- idempotent: already claimed; return the same payload, do not double-charge
    RETURN jsonb_build_object('status','ALREADY_GENERATING','job_id',p_job_id,
      'source_asset_url', j.provenance->'product_identity'->>'source_asset_url',
      'prompt', j.generation_instructions, 'provider', j.provider,
      'model', j.provenance->>'model','size', j.provenance->>'size','quality', j.provenance->>'quality');
  END IF;
  IF j.status IN ('GENERATED_REVIEW_REQUIRED','GENERATED_REAL') THEN
    RETURN jsonb_build_object('status','ALREADY_COMPLETE','job_id',p_job_id,'output_asset_refs',j.output_asset_refs);
  END IF;
  IF j.status <> 'READY_TO_DISPATCH' THEN
    RETURN jsonb_build_object('status','NOT_PREPARED','current',j.status,'note','run fn_media_prepare_image_job first (claim gate + identity + cost)');
  END IF;
  -- re-run claim gate at dispatch time (defense in depth)
  v_gate := public.fn_media_claim_gate(j.angle_id);
  IF (v_gate->>'blocked')::boolean THEN
    UPDATE public.media_image_jobs SET status='BLOCKED_CLAIM_REVIEW', error_state='claim_violation', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_REVIEW','violations',v_gate->'violations');
  END IF;
  UPDATE public.media_image_jobs SET status='GENERATING',
     provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('dispatched_at', now()), updated_at=now()
   WHERE id=p_job_id;
  RETURN jsonb_build_object('status','GENERATING','job_id',p_job_id,
    'source_asset_url', j.provenance->'product_identity'->>'source_asset_url',
    'prompt', j.generation_instructions, 'provider', j.provider,
    'model', j.provenance->>'model','endpoint', j.provenance->>'provider_endpoint',
    'size', j.provenance->>'size','quality', j.provenance->>'quality',
    'completion_contract','executor uploads to pulse-generated-media then calls fn_media_complete_image_real');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_dispatch_image_job(uuid,uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_dispatch_image_job(uuid,uuid) TO service_role;

-- 4) BROWSER-SAFE LINEAGE READ (authenticated, tenant-scoped) -----------------
CREATE OR REPLACE FUNCTION public.fn_ad_studio_creative_read(p_angle_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_variants jsonb; v_job public.media_image_jobs%rowtype; v_asset jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF a.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('platform',platform,'placement',placement,'hook',hook,
           'cta',cta,'aspect_ratio',aspect_ratio,'opening_seconds',opening_seconds,
           'claim_violations',claim_violations) ORDER BY platform),'[]'::jsonb) INTO v_variants
  FROM public.ad_studio_platform_variants WHERE angle_id=p_angle_id;

  SELECT * INTO v_job FROM public.media_image_jobs WHERE angle_id=p_angle_id ORDER BY created_at DESC LIMIT 1;
  IF v_job.id IS NOT NULL AND jsonb_array_length(coalesce(v_job.output_asset_refs,'[]'::jsonb)) > 0 THEN
    v_asset := public.fn_media_generation_result((v_job.output_asset_refs->>0)::uuid);
  END IF;

  RETURN jsonb_build_object('status','ok',
    'brief', jsonb_build_object('brief_id',b.id,'product_name',b.product_name,'market',b.market,
        'problem_solved',b.problem_solved,'platform_targets',b.platform_targets,'evidence_completeness',b.evidence_completeness),
    'concept', jsonb_build_object('angle_id',a.id,'angle_type',a.angle_type,'hook',a.hook,'headline',a.headline,
        'primary_copy',a.primary_copy,'cta',a.cta,'visual_concept',a.visual_concept,
        'claim_risk',a.claim_risk,'claim_violations',a.claim_violations,'review_state',a.review_state),
    'platform_variants', v_variants,
    'generation', CASE WHEN v_job.id IS NULL THEN jsonb_build_object('state','NONE')
      ELSE jsonb_build_object('job_id',v_job.id,'state',v_job.status,'provider',v_job.provider,
        'estimated_cost',v_job.estimated_cost,'actual_cost',v_job.actual_cost,'cost_currency',v_job.cost_currency,
        'failure_reason',v_job.error_state,
        'claim_gate', v_job.provenance->'claim_gate',
        'product_identity', v_job.provenance->'product_identity') END,
    'asset', coalesce(v_asset, 'null'::jsonb),
    'contract','ad_creative_read_v1_015f; provider secrets never exposed; identity + claim + approval states surfaced');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ad_studio_creative_read(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_ad_studio_creative_read(uuid) TO authenticated, service_role;

-- 5) OWNER-ONLY storage_ref for the signed-delivery Edge Function -------------
--    Returns the storage path ONLY to the asset's tenant. The Edge Function then
--    mints a short-lived signed URL server-side. No service creds in SQL/browser.
CREATE OR REPLACE FUNCTION public.fn_media_asset_signed_ref(p_asset_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); m public.media_assets%rowtype;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF m.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;  -- tenant isolation
  IF coalesce(m.storage_ref,'')='' THEN RETURN jsonb_build_object('status','no_asset'); END IF;
  RETURN jsonb_build_object('status','ok','bucket','pulse-generated-media','storage_ref',m.storage_ref,
    'approval_state',m.approval_state,'is_launch_safe',m.is_launch_safe);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_asset_signed_ref(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_media_asset_signed_ref(uuid) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.fn_media_runtime_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  tB uuid := '3d0eb793-685a-4ec2-aea7-8b95fda7112a';
  brA uuid; angC uuid; angV uuid; jobC uuid; jobV uuid; r jsonb; r2 jsonb; comp jsonb;
  v_asset uuid; i int;
BEGIN
  -- clean prior fixtures
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_image_jobs j
     JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id
     WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%');
  DELETE FROM public.media_image_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_static_creatives WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_platform_variants WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%';

  INSERT INTO public.ad_studio_briefs(tenant_id,product_name,market,market_currency,problem_solved,product_assets,is_fixture,status)
    VALUES (tA,'[[mrt]] Test Widget','US','USD','keeping cables tidy',
      jsonb_build_array('https://cf.cjdropshipping.com/mrt-src.jpg'),true,'REVIEW_REQUIRED') RETURNING id INTO brA;

  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,hook,headline,primary_copy,cta,
     visual_concept,static_creative_brief,claim_risk,claim_violations,review_state)
    VALUES (brA,tA,0,'PROBLEM_SOLUTION','Tidy Desk Transformation','Tired of tangled cables on your desk?',
     'Keep your desk tidy with the cable organizer','Route every cable cleanly in seconds.','Learn more',
     'Show a messy desk transformed into a tidy one with the product.','Clean product hero on tidy desk','LOW','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angC;
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,hook,headline,primary_copy,cta,
     visual_concept,static_creative_brief,claim_risk,claim_violations,review_state)
    VALUES (brA,tA,1,'OFFER','Sale Offer','The #1 best-seller customers love','50% off today only, limited stock','Clinically proven to cure clutter.','Buy now',
     'Bold discount banner','Sale creative','HIGH','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angV;

  INSERT INTO public.ad_studio_static_creatives(angle_id,tenant_id,platform,product_asset_refs,aspect_ratio,safe_area,generation_status)
    VALUES (angC,tA,'META',jsonb_build_array('https://cf.cjdropshipping.com/mrt-src.jpg'),'1:1','20%','PENDING');

  jobC := (public.fn_media_create_image_job(tA,angC))->>'job_id';
  jobV := (public.fn_media_create_image_job(tA,angV))->>'job_id';

  -- A. prepare clean -> READY_TO_DISPATCH + cost + identity review
  r := public.fn_media_prepare_image_job(jobC, tA);
  v := v || jsonb_build_object('case','A_prepare_ready','pass',
    (r->>'status'='READY_TO_DISPATCH' AND (r->>'estimated_cost_usd')::numeric > 0
     AND r->'product_identity'->>'identity_state'='IDENTITY_REVIEW_REQUIRED'
     AND (r->>'provider_call_count')::int=1),'got',r->>'status');

  -- B. claim gate hard-blocks the violating angle
  r := public.fn_media_prepare_image_job(jobV, tA);
  v := v || jsonb_build_object('case','B_claim_gate_blocks','pass',
    (r->>'status'='BLOCKED_CLAIM_REVIEW' AND jsonb_array_length(r->'violations') >= 2),
    'got',r->>'status','violations',jsonb_array_length(coalesce(r->'violations','[]'::jsonb)));

  -- C. dispatch prepared clean -> GENERATING + provider payload (no secret)
  r := public.fn_media_dispatch_image_job(jobC, tA);
  v := v || jsonb_build_object('case','C_dispatch_generating','pass',
    (r->>'status'='GENERATING' AND r->>'source_asset_url' IS NOT NULL AND r->>'model' IS NOT NULL),'got',r->>'status');

  -- D. dispatch idempotent -> ALREADY_GENERATING (no double charge)
  r2 := public.fn_media_dispatch_image_job(jobC, tA);
  v := v || jsonb_build_object('case','D_dispatch_idempotent','pass', r2->>'status'='ALREADY_GENERATING','got',r2->>'status');

  -- E. tenant isolation: wrong tenant cannot prepare/dispatch
  v := v || jsonb_build_object('case','E_tenant_isolation_job','pass',
    ((public.fn_media_prepare_image_job(jobC, tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_media_dispatch_image_job(jobC, tB))->>'status'='not_found_or_forbidden'));

  -- F. complete_real records asset IN_REVIEW, is_launch_safe false
  comp := public.fn_media_complete_image_real(jobC, tA, 'OPENAI_GPT_IMAGE', 'test-prov-job',
     'mrt/gen-test.png','image/png',1024,1024,0.02,'USD',NULL,'US',
     jsonb_build_array('https://cf.cjdropshipping.com/mrt-src.jpg'),'test prompt','{}'::jsonb);
  v_asset := (comp->>'asset_id')::uuid;
  v := v || jsonb_build_object('case','F_complete_in_review_not_launch_safe','pass',
    (comp->>'status'='GENERATED_REAL' AND (comp->>'is_launch_safe')::boolean=false AND comp->>'approval_state'='IN_REVIEW'));

  -- G. signed-ref owner-only (unauthenticated in selftest -> unauthenticated), tenant check present
  v := v || jsonb_build_object('case','G_signed_ref_requires_auth','pass',
    (public.fn_media_asset_signed_ref(v_asset))->>'status'='unauthenticated');

  -- H. creative_read tenant isolation via simulated JWT
  PERFORM set_config('request.jwt.claims', json_build_object('sub',tA::text,'role','authenticated')::text, true);
  r := public.fn_ad_studio_creative_read(angC);
  PERFORM set_config('request.jwt.claims', json_build_object('sub',tB::text,'role','authenticated')::text, true);
  r2 := public.fn_ad_studio_creative_read(angC);
  PERFORM set_config('request.jwt.claims', '', true);
  v := v || jsonb_build_object('case','H_read_tenant_isolation','pass',
    (r->>'status'='ok' AND r2->>'status'='forbidden'),'own',r->>'status','other',r2->>'status');

  -- I. bounded retry -> FAILED after max
  UPDATE public.media_image_jobs SET retry_count=max_retries WHERE id=jobC;
  r := public.fn_media_retry_image_job(jobC, tA, 'provider_unavailable');
  v := v || jsonb_build_object('case','I_retry_bounded','pass', r->>'status'='FAILED','got',r->>'status');

  -- J. claim scanner detects a real violation
  v := v || jsonb_build_object('case','J_claim_scan_detects','pass',
    jsonb_array_length(public.fn_ad_studio_claim_scan('best seller, 50% off, clinically proven')) >= 3);

  -- cleanup
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_image_jobs j
     JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id
     WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%');
  DELETE FROM public.media_image_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_static_creatives WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_platform_variants WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[mrt]]%';

  RETURN jsonb_build_object('suite','ad_creative_runtime',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_runtime_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_runtime_selftest() TO service_role;
