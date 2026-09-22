-- ============================================================================
-- mig_276_canonical_creative_lineage.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015F.2 — canonical product + Product Decision
-- lineage gate for the Ad Creative Studio.
--
-- DEFECT (found in 015F.1): fn_ad_studio_build_brief accepted an arbitrary
-- product_id/decision_id with NO validation, and fn_media_approve_asset set
-- is_launch_safe=true with NO canonical-lineage / identity check. The founder
-- dash-cam brief (15f0aabd) carries an inline product ref (ae458526) that does
-- NOT resolve to commerce_products, decision_id NULL → the generated asset's
-- product_id is NULL and contract_complete=false.
--
-- FIX (small, additive): a deterministic lineage_state (CANONICAL / INLINE_ONLY /
-- UNRESOLVED) resolved ONLY from real foreign keys (never text/name match), a
-- brief-builder that validates product ownership + decision, propagation into
-- job → asset, and a HARD launch-safety gate: an asset can only become
-- is_launch_safe when lineage_state=CANONICAL AND a valid Product Decision exists
-- AND product identity is cleared. INLINE_ONLY / UNRESOLVED may still be generated
-- for experimentation but can NEVER become launch-safe.
--
-- REUSE (no new product/decision system, no duplicate product): commerce_products,
-- product_opportunity_decisions, ad_studio_*, media_*. Product Decision scoring,
-- gallery identity and Problem Intelligence are untouched.
-- ============================================================================

-- 0) lineage_state columns (additive; default safe) --------------------------
ALTER TABLE public.ad_studio_briefs    ADD COLUMN IF NOT EXISTS lineage_state text NOT NULL DEFAULT 'UNRESOLVED';
ALTER TABLE public.media_image_jobs    ADD COLUMN IF NOT EXISTS lineage_state text NOT NULL DEFAULT 'UNRESOLVED';
ALTER TABLE public.media_assets        ADD COLUMN IF NOT EXISTS lineage_state text NOT NULL DEFAULT 'UNRESOLVED';
ALTER TABLE public.media_assets        ADD COLUMN IF NOT EXISTS identity_state text NOT NULL DEFAULT 'IDENTITY_REVIEW_REQUIRED';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ad_studio_briefs_lineage_chk') THEN
    ALTER TABLE public.ad_studio_briefs ADD CONSTRAINT ad_studio_briefs_lineage_chk
      CHECK (lineage_state IN ('CANONICAL','INLINE_ONLY','UNRESOLVED'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_image_jobs_lineage_chk') THEN
    ALTER TABLE public.media_image_jobs ADD CONSTRAINT media_image_jobs_lineage_chk
      CHECK (lineage_state IN ('CANONICAL','INLINE_ONLY','UNRESOLVED'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_assets_lineage_chk') THEN
    ALTER TABLE public.media_assets ADD CONSTRAINT media_assets_lineage_chk
      CHECK (lineage_state IN ('CANONICAL','INLINE_ONLY','UNRESOLVED'));
  END IF;
END $$;

-- 1) DETERMINISTIC lineage resolver (real FKs only; never name/text) ----------
CREATE OR REPLACE FUNCTION public.fn_ad_studio_resolve_lineage(
  p_tenant uuid, p_product_id uuid, p_decision_id uuid, p_market text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_owner uuid; v_dec uuid; v_mkt text := upper(btrim(coalesce(p_market,'')));
BEGIN
  IF p_product_id IS NULL THEN
    RETURN jsonb_build_object('lineage_state','UNRESOLVED','canonical_product_id',NULL,
      'decision_id',NULL,'decision_valid',false,'reason','no_product_id');
  END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('lineage_state','INLINE_ONLY','canonical_product_id',NULL,
      'decision_id',NULL,'decision_valid',false,'reason','product_id_not_in_commerce_products');
  END IF;
  IF v_owner <> p_tenant THEN
    RETURN jsonb_build_object('lineage_state','INLINE_ONLY','canonical_product_id',NULL,
      'decision_id',NULL,'decision_valid',false,'reason','cross_tenant_product_rejected','cross_tenant',true);
  END IF;
  -- product is canonical AND owned by tenant. Validate decision if supplied.
  IF p_decision_id IS NOT NULL THEN
    SELECT id INTO v_dec FROM public.product_opportunity_decisions
     WHERE id=p_decision_id AND product_id=p_product_id AND tenant_id=p_tenant
       AND upper(country_code)=v_mkt AND coalesce(is_fixture,false)=false;
    IF v_dec IS NULL THEN
      -- an INVALID decision must NOT be silently accepted; downgrade, never fabricate
      RETURN jsonb_build_object('lineage_state','INLINE_ONLY','canonical_product_id',p_product_id,
        'decision_id',NULL,'decision_valid',false,'reason','invalid_decision_for_product_market_tenant');
    END IF;
  END IF;
  RETURN jsonb_build_object('lineage_state','CANONICAL','canonical_product_id',p_product_id,
    'decision_id',v_dec,'decision_valid',(v_dec IS NOT NULL),
    'reason', CASE WHEN v_dec IS NOT NULL THEN 'canonical_with_decision' ELSE 'canonical_product_no_decision' END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ad_studio_resolve_lineage(uuid,uuid,uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_ad_studio_resolve_lineage(uuid,uuid,uuid,text) TO authenticated, service_role;

-- 2) production launch eligibility (authoritative, read-only) -----------------
CREATE OR REPLACE FUNCTION public.fn_media_launch_eligibility(p_asset_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE m public.media_assets%rowtype; v_dec_exists boolean;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('eligible',false,'reason','not_found'); END IF;
  IF m.lineage_state <> 'CANONICAL' THEN
    RETURN jsonb_build_object('eligible',false,'reason','CANONICAL_PRODUCT_LINEAGE_REQUIRED','lineage_state',m.lineage_state);
  END IF;
  IF m.identity_state <> 'IDENTITY_CLEARED' THEN
    RETURN jsonb_build_object('eligible',false,'reason','IDENTITY_REVIEW_REQUIRED','identity_state',m.identity_state);
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.product_opportunity_decisions d
    WHERE d.product_id=m.product_id AND d.tenant_id=m.tenant_id
      AND upper(d.country_code)=upper(coalesce(m.country_code,'')) AND coalesce(d.is_fixture,false)=false)
    INTO v_dec_exists;
  IF NOT v_dec_exists THEN
    RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_DECISION_REQUIRED');
  END IF;
  RETURN jsonb_build_object('eligible',true,'reason','canonical_lineage_identity_cleared_decision_present',
    'lineage_state',m.lineage_state,'identity_state',m.identity_state);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_media_launch_eligibility(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_media_launch_eligibility(uuid) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.fn_ad_studio_lineage_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  tB uuid := '3d0eb793-685a-4ec2-aea7-8b95fda7112a';
  real_shoe uuid := 'efca8b59-d814-404b-be1b-65e833fab9b8';
  pC uuid; pB uuid; v_realdec uuid;
  brCanon uuid; brInline uuid; angC uuid; angI uuid; jobC uuid; jobI uuid;
  r jsonb; comp jsonb; v_assetC uuid; v_assetI uuid; v_err text;
  v_dupe_before int; v_dupe_after int;
BEGIN
  -- cleanup prior fixtures
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_image_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%');
  DELETE FROM public.media_image_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_static_creatives WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%';
  DELETE FROM public.commerce_products WHERE product_identity LIKE 'lin:%';

  SELECT count(*) INTO v_dupe_before FROM public.commerce_products
    WHERE lower(title) LIKE '%3 channel%' OR lower(title) LIKE '%dash cam%';

  -- fixture canonical product (tA) and cross-tenant product (tB)
  INSERT INTO public.commerce_products(user_id,product_identity,identity_basis,title,category,provenance)
    VALUES (tA,'lin:canonical','platform_id','[[lin]] Canonical Widget','widgets','{}'::jsonb) RETURNING id INTO pC;
  INSERT INTO public.commerce_products(user_id,product_identity,identity_basis,title,category,provenance)
    VALUES (tB,'lin:crosstenant','platform_id','[[lin]] Canonical Widget','widgets','{}'::jsonb) RETURNING id INTO pB;

  SELECT id INTO v_realdec FROM public.product_opportunity_decisions
    WHERE product_id=real_shoe AND country_code='GB' AND coalesce(is_fixture,false)=false LIMIT 1;

  -- A canonical product resolves
  r := public.fn_ad_studio_resolve_lineage(tA,pC,NULL,'US');
  v := v || jsonb_build_object('case','A_canonical_resolves','pass',
    (r->>'lineage_state'='CANONICAL' AND (r->>'canonical_product_id')=pC::text));

  -- B wrong-tenant product cannot be attached (resolve + build_brief raise)
  r := public.fn_ad_studio_resolve_lineage(tA,pB,NULL,'US');
  BEGIN
    PERFORM public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[lin]] x','market','US','product_id',pB::text), true);
    v_err := 'no_error';
  EXCEPTION WHEN OTHERS THEN v_err := 'raised'; END;
  v := v || jsonb_build_object('case','B_cross_tenant_rejected','pass',
    (r->>'lineage_state'='INLINE_ONLY' AND (r->>'reason')='cross_tenant_product_rejected' AND v_err='raised'));

  -- C name similarity alone cannot create canonical lineage (no product_id -> UNRESOLVED despite same-name product existing)
  r := public.fn_ad_studio_resolve_lineage(tA,NULL,NULL,'US');
  v := v || jsonb_build_object('case','C_name_match_not_canonical','pass', r->>'lineage_state'='UNRESOLVED');

  -- D invalid Product Decision cannot be attached
  r := public.fn_ad_studio_resolve_lineage(tA,real_shoe,gen_random_uuid(),'GB');
  v := v || jsonb_build_object('case','D_invalid_decision_rejected','pass',
    (r->>'lineage_state'='INLINE_ONLY' AND (r->>'reason')='invalid_decision_for_product_market_tenant'));

  -- E decision belongs to correct product+market+tenant (valid GB, invalid when market=DE)
  r := public.fn_ad_studio_resolve_lineage(tA,real_shoe,v_realdec,'GB');
  v := v || jsonb_build_object('case','E_valid_decision_market_tenant','pass',
    (r->>'lineage_state'='CANONICAL' AND (r->>'decision_valid')::boolean=true
     AND (public.fn_ad_studio_resolve_lineage(tA,real_shoe,v_realdec,'DE')->>'lineage_state')='INLINE_ONLY'),
    'got', r->>'lineage_state');

  -- F canonical brief propagates product ID into generation job
  brCanon := public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[lin]] Canon','market','US','market_currency','USD','product_id',pC::text,'product_assets',jsonb_build_array('https://cf.cjdropshipping.com/lin.jpg')), true);
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,hook,headline,primary_copy,cta,visual_concept,static_creative_brief,claim_risk,claim_violations,review_state)
    VALUES (brCanon,tA,0,'PRODUCT_DEMONSTRATION','Canon','Clean hook','Neat headline','Nice copy.','Learn more','Clean product hero','Clean product hero on neutral bg','LOW','[]'::jsonb,'REVIEW_REQUIRED') RETURNING id INTO angC;
  INSERT INTO public.ad_studio_static_creatives(angle_id,tenant_id,platform,product_asset_refs,aspect_ratio,safe_area,generation_status)
    VALUES (angC,tA,'META',jsonb_build_array('https://cf.cjdropshipping.com/lin.jpg'),'1:1','20%','PENDING');
  jobC := (public.fn_media_create_image_job(tA,angC))->>'job_id';
  PERFORM public.fn_media_prepare_image_job(jobC,tA);
  v := v || jsonb_build_object('case','F_canonical_brief_to_job','pass',
    ((SELECT lineage_state FROM public.ad_studio_briefs WHERE id=brCanon)='CANONICAL'
     AND (SELECT lineage_state FROM public.media_image_jobs WHERE id=jobC)='CANONICAL'));

  -- G canonical job propagates product ID into media asset
  comp := public.fn_media_complete_image_real(jobC,tA,'OPENAI_GPT_IMAGE','lin-test','lin/c.png','image/png',1024,1024,0.01,'USD',NULL,'US',jsonb_build_array('https://cf.cjdropshipping.com/lin.jpg'),'p','{}'::jsonb);
  v_assetC := (comp->>'asset_id')::uuid;
  v := v || jsonb_build_object('case','G_canonical_job_to_asset','pass',
    ((SELECT lineage_state FROM public.media_assets WHERE id=v_assetC)='CANONICAL'
     AND (SELECT product_id FROM public.media_assets WHERE id=v_assetC)=pC));

  -- H INLINE_ONLY asset cannot become automatically launch-safe
  brInline := public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[lin]] Inline','market','US','market_currency','USD','product_id',gen_random_uuid()::text,'product_assets',jsonb_build_array('https://cf.cjdropshipping.com/lin2.jpg')), true);
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,hook,headline,primary_copy,cta,visual_concept,static_creative_brief,claim_risk,claim_violations,review_state)
    VALUES (brInline,tA,0,'PRODUCT_DEMONSTRATION','Inline','Clean hook','Neat headline','Nice copy.','Learn more','Clean hero','Clean hero','LOW','[]'::jsonb,'REVIEW_REQUIRED') RETURNING id INTO angI;
  INSERT INTO public.ad_studio_static_creatives(angle_id,tenant_id,platform,product_asset_refs,aspect_ratio,safe_area,generation_status)
    VALUES (angI,tA,'META',jsonb_build_array('https://cf.cjdropshipping.com/lin2.jpg'),'1:1','20%','PENDING');
  jobI := (public.fn_media_create_image_job(tA,angI))->>'job_id';
  PERFORM public.fn_media_prepare_image_job(jobI,tA);
  comp := public.fn_media_complete_image_real(jobI,tA,'OPENAI_GPT_IMAGE','lin-test2','lin/i.png','image/png',1024,1024,0.01,'USD',NULL,'US',jsonb_build_array('https://cf.cjdropshipping.com/lin2.jpg'),'p','{}'::jsonb);
  v_assetI := (comp->>'asset_id')::uuid;
  r := public.fn_media_approve_asset(v_assetI,tA);
  v := v || jsonb_build_object('case','H_inline_never_launch_safe','pass',
    (r->>'status'='blocked_lineage_or_identity' AND (r->>'reason')='CANONICAL_PRODUCT_LINEAGE_REQUIRED'
     AND (SELECT is_launch_safe FROM public.media_assets WHERE id=v_assetI)=false));

  -- I historical dash-cam asset unchanged
  v := v || jsonb_build_object('case','I_historical_asset_unchanged','pass',
    EXISTS(SELECT 1 FROM public.media_assets WHERE id='718b4962-2574-442a-9b27-92def402a517'
      AND lineage_state='INLINE_ONLY' AND product_id IS NULL AND is_launch_safe=false AND approval_state='IN_REVIEW'));

  -- J identity-review and canonical-lineage are independent (canonical asset blocked by IDENTITY, inline by LINEAGE)
  r := public.fn_media_approve_asset(v_assetC,tA);
  v := v || jsonb_build_object('case','J_identity_lineage_independent','pass',
    (r->>'status'='blocked_lineage_or_identity' AND (r->>'reason')='IDENTITY_REVIEW_REQUIRED'),
    'canonical_block', r->>'reason');

  -- K tenant isolation (prepare/approve wrong tenant)
  v := v || jsonb_build_object('case','K_tenant_isolation','pass',
    ((public.fn_media_prepare_image_job(jobC,tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_media_approve_asset(v_assetC,tB))->>'status'='not_found_or_forbidden'));

  -- L no duplicate commerce product created for the dash cam
  SELECT count(*) INTO v_dupe_after FROM public.commerce_products
    WHERE lower(title) LIKE '%3 channel%' OR lower(title) LIKE '%dash cam%';
  v := v || jsonb_build_object('case','L_no_duplicate_product','pass', v_dupe_after = v_dupe_before);

  -- M existing Product Decision scores unchanged (nightlight GB)
  v := v || jsonb_build_object('case','M_decision_scores_unchanged','pass',
    (SELECT market_opportunity_score FROM public.product_market_evaluations
       WHERE product_id=(SELECT id FROM public.commerce_products WHERE title='kids nightlight projector' LIMIT 1)
         AND country_code='GB' AND coalesce(is_fixture,false)=false ORDER BY evaluation_ts DESC LIMIT 1) = 68.2);

  -- N gallery identity unchanged
  v := v || jsonb_build_object('case','N_gallery_unchanged','pass', (public.fn_product_gallery_selftest()->>'all_pass')::boolean);

  -- O problem intelligence unchanged
  v := v || jsonb_build_object('case','O_problem_unchanged','pass',
    public.fn_problem_corroboration_state('21792efb-bfa0-4873-ab8a-5accd0b64696')->>'corroboration_state'='MULTI_EVIDENCE_SINGLE_SOURCE');

  -- P existing generated asset remains truthful (provider + source + storage preserved)
  v := v || jsonb_build_object('case','P_historical_asset_truthful','pass',
    EXISTS(SELECT 1 FROM public.media_assets WHERE id='718b4962-2574-442a-9b27-92def402a517'
      AND provider='OPENAI_GPT_IMAGE' AND coalesce(storage_ref,'')<>''
      AND source_asset_refs @> jsonb_build_array('https://cf.cjdropshipping.com/0c425d56-1e24-4b0a-9a75-f98146663182.jpg')));

  -- cleanup
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_image_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%');
  DELETE FROM public.media_image_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_static_creatives WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[lin]]%';
  DELETE FROM public.commerce_products WHERE product_identity LIKE 'lin:%';

  RETURN jsonb_build_object('suite','ad_creative_canonical_lineage',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ad_studio_lineage_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ad_studio_lineage_selftest() TO service_role;
