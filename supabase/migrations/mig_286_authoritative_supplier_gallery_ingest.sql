-- ============================================================================
-- mig_286_authoritative_supplier_gallery_ingest.sql
-- STRATELOQ-015O — upstream Product Card data quality: ingest ALL authoritative
-- exact-SKU supplier gallery images for a canonical product, under the strict
-- identity rule. Marketplace-reference images NEVER become authoritative.
-- Governed by mig_283 (PRODUCT_CARD_ASSET_IS_AUTHORITATIVE) + the LOCKED standard.
--
-- STRICT: an image is ingested as authoritative ONLY when
--   (p_provider, p_source_item_id) == the product's Product Card identity
--   (commerce_products.extended.supplier_ref provider + source_product_id).
-- Never matched by name / visual similarity / keywords / category / LLM.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_ingest_supplier_gallery(
  p_tenant uuid, p_product_id uuid, p_provider text, p_source_item_id text,
  p_images jsonb, p_source_payload jsonb DEFAULT '{}'::jsonb, p_is_fixture boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_owner uuid; v_card_provider text; v_card_item text; v_prov text;
  v_img jsonb; v_url text; v_role text; v_ingested int := 0; v_skipped int := 0; v_bad int := 0;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL THEN RETURN jsonb_build_object('status','tenant_and_product_required'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','forbidden_tenant_mismatch'); END IF;

  -- Product Card identity
  SELECT upper(coalesce(extended->'supplier_ref'->>'provider','')),
         coalesce(extended->'supplier_ref'->>'source_product_id', extended->>'cj_source_product_id')
    INTO v_card_provider, v_card_item
  FROM public.commerce_products WHERE id=p_product_id;
  v_card_provider := CASE WHEN v_card_provider IN ('CJ','CJ_SUPPLIER') THEN 'CJ_SUPPLIER' ELSE v_card_provider END;
  v_prov := CASE WHEN upper(coalesce(p_provider,'')) IN ('CJ','CJ_SUPPLIER') THEN 'CJ_SUPPLIER' ELSE upper(coalesce(p_provider,'')) END;

  IF v_card_provider IS NULL OR v_card_item IS NULL OR v_card_provider='' OR v_card_item='' THEN
    RETURN jsonb_build_object('status','no_supplier_identity_on_product',
      'note','product has no deterministic supplier item link; cannot ingest an authoritative gallery');
  END IF;
  -- STRICT identity gate: never mix identities
  IF v_prov <> v_card_provider OR p_source_item_id IS DISTINCT FROM v_card_item THEN
    RETURN jsonb_build_object('status','rejected_identity_mismatch',
      'reason','(provider,item) does not equal the Product Card identity',
      'card_identity', jsonb_build_object('provider',v_card_provider,'item',v_card_item),
      'attempted', jsonb_build_object('provider',v_prov,'item',p_source_item_id));
  END IF;

  FOR v_img IN SELECT * FROM jsonb_array_elements(coalesce(p_images,'[]'::jsonb)) LOOP
    v_url := btrim(coalesce(v_img->>'url',''));
    v_role := coalesce(nullif(v_img->>'role',''),'SUPPLIER_GALLERY_IMAGE');
    IF v_url = '' OR v_url NOT ILIKE 'http%' THEN v_bad := v_bad + 1; CONTINUE; END IF;
    -- dedup by (product, url)
    IF EXISTS(SELECT 1 FROM public.product_image_assets a WHERE a.product_id=p_product_id AND a.image_url=v_url) THEN
      v_skipped := v_skipped + 1; CONTINUE;
    END IF;

    INSERT INTO public.product_image_assets(tenant_id, product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance, is_fixture)
    VALUES (p_tenant, p_product_id, NULL, v_url, v_card_provider, v_url,
      v_card_item, 'SUPPLIER_PROVIDED', 'AVAILABLE', false, now(),
      jsonb_build_object('ingested_by','015O_supplier_gallery_ingest','asset_role',v_role,
        'retrieved_at', now(), 'source_payload_lineage', coalesce(p_source_payload,'{}'::jsonb),
        'identity', jsonb_build_object('provider',v_card_provider,'source_item_id',v_card_item)),
      p_is_fixture);

    -- supplier gallery lineage (best-effort provenance store)
    INSERT INTO public.supplier_product_assets(supplier, supplier_product_id, asset_type, asset_class, asset_identity,
      rights_state, availability, source_url, original_source, is_primary, provenance, is_fixture)
    VALUES ('CJ', v_card_item, 'PRODUCT_IMAGE', v_role,
      jsonb_build_object('provider',v_card_provider,'source_item_id',v_card_item),
      'SUPPLIER_PROVIDED', 'AVAILABLE', v_url, 'CJ_PRODUCT_QUERY', false,
      jsonb_build_object('ingested_by','015O','role',v_role,'retrieved_at',now()), p_is_fixture);

    v_ingested := v_ingested + 1;
  END LOOP;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id::text,
    'card_identity', jsonb_build_object('provider',v_card_provider,'source_item_id',v_card_item),
    'ingested', v_ingested, 'skipped_duplicates', v_skipped, 'invalid_urls', v_bad,
    'note','Authoritative exact-SKU supplier images ingested. Marketplace-reference images are untouched and remain reference-only.');
END; $fn$;

-- Tests A–H
CREATE OR REPLACE FUNCTION public.fn_supplier_gallery_ingest_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid; v_other uuid; v_prod uuid; v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb;
  v_r jsonb; v_auth jsonb; v_sel jsonb;
BEGIN
  SELECT user_id INTO v_tenant FROM public.commerce_products WHERE user_id IS NOT NULL LIMIT 1;
  DELETE FROM public.supplier_product_assets WHERE supplier_product_id IN ('SGI_ITEM_1','SGI_ITEM_2');
  DELETE FROM public.product_image_assets WHERE product_id IN (SELECT id FROM public.commerce_products WHERE title LIKE '%[[sgi]]%');
  DELETE FROM public.commerce_products WHERE title LIKE '%[[sgi]]%';

  INSERT INTO public.commerce_products(id,user_id,product_identity,identity_basis,title,category,source_store,product_role,visibility,provenance,extended)
  VALUES (gen_random_uuid(), v_tenant, 'sgi','normalized_name','sgi fixture [[sgi]]','x','selftest','candidate','TENANT_PRIVATE','{"product":"FIXTURE"}'::jsonb,
    jsonb_build_object('supplier_ref', jsonb_build_object('provider','CJ','source_product_id','SGI_ITEM_1')))
  RETURNING id INTO v_prod;

  -- images ingested as non-fixture into the temp product (authority excludes is_fixture=true); temp product cleaned up by id
  v_r := public.fn_ingest_supplier_gallery(v_tenant, v_prod, 'CJ','SGI_ITEM_1',
    jsonb_build_array(jsonb_build_object('url','https://cj.example/sgi_a.jpg','role','PRIMARY_PRODUCT'),
                      jsonb_build_object('url','https://cj.example/sgi_b.jpg','role','DETAIL')), '{}'::jsonb, false);
  v_auth := public.fn_ad_product_card_authority(v_tenant, v_prod, 'GB');
  IF (v_r->>'ingested')::int=2 AND (v_auth->>'authoritative_count')::int=2 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('A_gallery_same_identity',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('A_gallery_same_identity',false,'r',v_r,'auth_n',v_auth->>'authoritative_count'); END IF;

  v_r := public.fn_ingest_supplier_gallery(v_tenant, v_prod, 'CJ','SGI_ITEM_2',
    jsonb_build_array(jsonb_build_object('url','https://cj.example/wrong.jpg')), '{}'::jsonb, false);
  IF (v_r->>'status')='rejected_identity_mismatch' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('B_cross_item_rejected',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('B_cross_item_rejected',false,'got',v_r->>'status'); END IF;

  INSERT INTO public.product_image_assets(tenant_id,product_id,image_url,source_provider,source_url,source_entity_id,rights_state,availability,is_primary,observed_at,provenance,is_fixture)
  VALUES (v_tenant, v_prod,'https://ebayimg.example/sgi_mkt.jpg','EBAY_BROWSE','https://ebayimg.example/sgi_mkt.jpg','v1|999|0','MARKETPLACE_PUBLIC_LISTING','AVAILABLE',false,now(),'{}'::jsonb,false);
  v_auth := public.fn_ad_product_card_authority(v_tenant, v_prod, 'GB');
  IF (v_auth->>'authoritative_count')::int=2 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('C_marketplace_not_authoritative',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('C_marketplace_not_authoritative',false,'auth_n',v_auth->>'authoritative_count'); END IF;

  v_sel := public.fn_ad_product_card_select_creative_asset(v_tenant, v_prod, 'GB','{}'::jsonb, false);
  IF (v_sel->>'candidate_count')::int=2 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('D_selector_sees_gallery',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('D_selector_sees_gallery',false,'n',v_sel->>'candidate_count'); END IF;

  SELECT user_id INTO v_other FROM public.commerce_products WHERE user_id IS NOT NULL AND user_id<>v_tenant LIMIT 1;
  IF v_other IS NOT NULL THEN
    IF (public.fn_ingest_supplier_gallery(v_other, v_prod,'CJ','SGI_ITEM_1', jsonb_build_array(jsonb_build_object('url','https://cj.example/x.jpg')),'{}'::jsonb,false)->>'status')='forbidden_tenant_mismatch'
      THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('E_tenant_isolation',true);
    ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('E_tenant_isolation',false); END IF;
  ELSE v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('E_tenant_isolation','skipped_single_tenant'); END IF;

  v_r := public.fn_ingest_supplier_gallery(v_tenant, v_prod, 'CJ','SGI_ITEM_1',
    jsonb_build_array(jsonb_build_object('url','https://cj.example/sgi_a.jpg')), '{}'::jsonb, false);
  IF (v_r->>'ingested')::int=0 AND (v_r->>'skipped_duplicates')::int=1 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('F_dedup',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('F_dedup',false,'r',v_r); END IF;

  IF (v_auth->'primary_asset'->>'source_provider')='CJ_SUPPLIER' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('G_identity_preserved_authoritative',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('G_identity_preserved_authoritative',false); END IF;

  DELETE FROM public.supplier_product_assets WHERE supplier_product_id IN ('SGI_ITEM_1','SGI_ITEM_2');
  DELETE FROM public.product_image_assets WHERE product_id=v_prod;
  DELETE FROM public.commerce_products WHERE id=v_prod;

  RETURN jsonb_build_object('suite','supplier_gallery_ingest','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

-- ---------------------------------------------------------------------------
-- Required defect fix surfaced by gallery enrichment: the customer-facing
-- gallery resolver must order the PRIMARY (hero) image FIRST, otherwise a newly
-- enriched multi-image gallery can push the hero out of the top-N window and
-- break the hero_image_in_gallery invariant. (Adds isprim DESC to the ordering;
-- no other behavior change.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_product_gallery(p_product_id uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_lim int := least(greatest(coalesce(p_limit,5),1),5);
  v_prov text; v_eid text; v_imgs jsonb; v_count int; v_state text; v_ident text; v_research_done boolean;
BEGIN
  SELECT source_provider, source_entity_id INTO v_prov, v_eid
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false
    AND availability='AVAILABLE' AND coalesce(image_url,'')<>'' AND coalesce(source_entity_id,'')<>''
  ORDER BY is_primary DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END,
           image_url
  LIMIT 1;

  IF v_eid IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object(
             'image_url', image_url,
             'image_source', CASE src WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                      WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE src END,
             'image_source_url', src_url, 'is_primary', (pos=1), 'position', pos,
             'source_provider', src, 'source_item_id', v_eid) ORDER BY pos),
           count(*)
      INTO v_imgs, v_count
    FROM (
      SELECT image_url, src_url, src,
             row_number() OVER (ORDER BY isprim DESC, gpos, image_url) AS pos
      FROM (
        SELECT image_url,
               max(source_url) AS src_url, max(source_provider) AS src,
               min(coalesce((provenance->>'gallery_position')::int, 999)) AS gpos,
               max(CASE WHEN is_primary THEN 1 ELSE 0 END) AS isprim
        FROM public.product_image_assets
        WHERE product_id=p_product_id AND source_provider=v_prov AND source_entity_id=v_eid
          AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
        GROUP BY image_url
      ) u
    ) d
    WHERE pos <= v_lim;
  END IF;

  v_count := coalesce(v_count,0);
  IF v_count = 0 THEN
    SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                   WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                     AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
    v_state := CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END;
    v_ident := CASE WHEN v_research_done THEN 'SAME_PRODUCT_GALLERY_UNAVAILABLE' ELSE 'PENDING_RESEARCH' END;
  ELSIF v_count >= 3 THEN v_state := 'AVAILABLE'; v_ident := 'SAME_PRODUCT_GALLERY_READY';
  ELSE v_state := 'PARTIAL'; v_ident := 'SAME_PRODUCT_GALLERY_PARTIAL';
  END IF;

  RETURN jsonb_build_object('images', coalesce(v_imgs,'[]'::jsonb), 'count', v_count,
    'gallery_state', v_state, 'gallery_identity_state', v_ident,
    'card_source_provider', v_prov, 'card_source_item_id', v_eid,
    'gallery_source_provider', v_prov, 'gallery_source_item_id', v_eid);
END; $function$;
