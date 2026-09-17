-- STRATELOQ-ECOM-P8-HOSTED-STOREFRONT-PUBLISHING-006
-- Audit outcome: the Pulse-hosted publishing lifecycle already exists and is
-- hardened (mig_227 transitions, mig_230 fn_storefront_publish + public renderer,
-- mig_229 grant lockdown). No behavioral change is required. This migration ONLY
-- adds durable regression coverage for the lifecycle transitions the unit closes
-- that were not previously covered by a committed selftest: owner publish,
-- unpublish (owner + cross-tenant), post-unpublish NOT_FOUND, draft preservation,
-- republish, invalid-destination block, unsafe-claims block. Self-cleaning;
-- service_role only; writes nothing durable (creates + deletes synthetic tenants).
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_lifecycle_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; r jsonb; render jsonb;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  pid uuid; pid_bad_dest uuid; pid_bad_claim uuid; slug text;
  v_review text; v_pub text; v_model_intact boolean;
  ok_gate jsonb := '{"recommendation":"TEST","decision_tier":"STRONG_TEST","supplier_identity_state":"SUPPLIER_EXACT","market_supplier_match":"EXACT_CONFIRMED","subtype_price_valid":true,"stock_state":"IN_STOCK","economics_state":"VIABLE","product_confidence":"ACCEPTABLE","fulfilment_evidence":true,"no_critical_risk":true}'::jsonb;
  rc jsonb := jsonb_build_object('hero_variant','HERO_FEATURE_SPOTLIGHT','cta_structure','{}'::jsonb,'sections','[]'::jsonb,
       'claim_safety', jsonb_build_object('claim_scan_clean', true),
       'supplier_asset_refs', jsonb_build_object('state','ASSETS_AVAILABLE','usable_count',1,'rejected_count',0,
          'fulfilment_supplier','cjdropshipping','supplier_product_id','LIFECYCLE_PUB',
          'primary_image', jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg'),
          'gallery', jsonb_build_array(jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg'))));
  pm jsonb := '{"product_title":"Lifecycle Cam","hero":{"headline":"Lifecycle Cam"},"benefits":["a"],"trust":{"copy":"New."},"shipping":{"copy":"Estimate"},"seo":{"title":"Lifecycle"}}'::jsonb;
BEGIN
  INSERT INTO public.commerce_product_pages(user_id,market,country_code,destination,decision_classification,page_model,status,source_kind,review_state,publication_state,selling_price,display_currency,source_currency,runtime_contract)
   VALUES (u1,'US','US','PULSE_STORE','QUALIFIED_TEST_NOT_HIGH_CONFIDENCE',pm,'READY_FOR_REVIEW','REAL','APPROVED','UNPUBLISHED',91.79,'USD','USD',rc) RETURNING id INTO pid;
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,source_kind)
   VALUES (u1,pid,'DRAFT','lifecycle-'||left(replace(pid::text,'-',''),8),'REAL');

  r := public.fn_storefront_publish(pid, ok_gate, u1); slug := r->>'slug';
  v := v || jsonb_build_object('case','owner_publish_ok','pass',(r->>'status'='ok' AND r->>'publication_state'='PUBLISHED'),'got',r->>'status');
  v := v || jsonb_build_object('case','slug_shape_valid','pass',(slug ~ '^p[0-9a-f]{12}$'),'got',slug);
  render := public.fn_public_storefront_render(slug);
  v := v || jsonb_build_object('case','render_published_ok','pass',(render->>'status'='OK'),'got',render->>'status');
  r := public.fn_storefront_transition_state(pid,'APPROVED',u2);
  v := v || jsonb_build_object('case','unpublish_cross_tenant_denied','pass',(r->>'status'='DENIED_CROSS_TENANT'),'got',r->>'status');
  r := public.fn_storefront_transition_state(pid,'APPROVED',u1);
  v := v || jsonb_build_object('case','owner_unpublish_ok','pass',(r->>'status'='ok' AND r->>'publication_state'='UNPUBLISHED'),'got',r->>'publication_state');
  render := public.fn_public_storefront_render(slug);
  v := v || jsonb_build_object('case','render_notfound_after_unpublish','pass',(render->>'status'='NOT_FOUND'),'got',render->>'status');
  SELECT review_state, publication_state, (page_model->>'product_title'='Lifecycle Cam') INTO v_review, v_pub, v_model_intact
    FROM public.commerce_product_pages WHERE id=pid;
  v := v || jsonb_build_object('case','draft_preserved_after_unpublish','pass',(v_review='APPROVED' AND v_model_intact),'got',v_review);
  r := public.fn_storefront_publish(pid, ok_gate, u1);
  v := v || jsonb_build_object('case','republish_ok','pass',(r->>'status'='ok' AND r->>'publication_state'='PUBLISHED'),'got',r->>'status');

  INSERT INTO public.commerce_product_pages(user_id,market,country_code,destination,decision_classification,page_model,status,source_kind,review_state,publication_state,selling_price,display_currency,source_currency,runtime_contract)
   VALUES (u1,'US','US','EXISTING_STORE','QUALIFIED_TEST_NOT_HIGH_CONFIDENCE',pm,'READY_FOR_REVIEW','REAL','APPROVED','UNPUBLISHED',91.79,'USD','USD',rc) RETURNING id INTO pid_bad_dest;
  r := public.fn_storefront_publish(pid_bad_dest, ok_gate, u1);
  v := v || jsonb_build_object('case','invalid_destination_blocked','pass',(r->>'status'='BLOCKED_DESTINATION'),'got',r->>'status');

  INSERT INTO public.commerce_product_pages(user_id,market,country_code,destination,decision_classification,page_model,status,source_kind,review_state,publication_state,selling_price,display_currency,source_currency,runtime_contract)
   VALUES (u1,'US','US','PULSE_STORE','QUALIFIED_TEST_NOT_HIGH_CONFIDENCE',pm,'READY_FOR_REVIEW','REAL','APPROVED','UNPUBLISHED',91.79,'USD','USD',
     rc || jsonb_build_object('claim_safety', jsonb_build_object('claim_scan_clean', false))) RETURNING id INTO pid_bad_claim;
  r := public.fn_storefront_publish(pid_bad_claim, ok_gate, u1);
  v := v || jsonb_build_object('case','unsafe_claims_blocked','pass',(r->>'status'='BLOCKED_CLAIM_SAFETY'),'got',r->>'status');

  -- cleanup (self-cleaning; no residue)
  DELETE FROM public.commerce_store_projects WHERE product_page_id IN (pid,pid_bad_dest,pid_bad_claim);
  DELETE FROM public.commerce_product_pages WHERE id IN (pid,pid_bad_dest,pid_bad_claim);

  RETURN jsonb_build_object('suite','pulse_hosted_publish_lifecycle',
    'total', jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_storefront_publish_lifecycle_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish_lifecycle_selftest() TO service_role;
COMMENT ON FUNCTION public.fn_storefront_publish_lifecycle_selftest() IS
 'Publish lifecycle regression (self-cleaning, service_role only): owner publish, stable slug, published render, cross-tenant unpublish denial, owner unpublish, post-unpublish NOT_FOUND, draft preservation, republish, invalid-destination + unsafe-claims fail-closed.';
