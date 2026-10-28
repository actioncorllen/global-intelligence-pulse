-- ============================================================================
-- mig_299_product_image_tenant_authorization.sql
-- STRATELOQ-STAGE4D-PRODUCT-IMAGE-TENANT-AUTHORISATION
--
-- SECURITY DEFECT (same family as mig_298): the client/display primary-image RPC
-- fn_resolve_product_image(p_product_id uuid, p_market text) is SECURITY DEFINER +
-- EXECUTE-granted to `authenticated` but not tenant-scoped, so any authenticated user could
-- pass an arbitrary canonical product_id and receive another tenant's private primary image
-- URL. Reproduced: a non-owner retrieved the founder-private "Novelty Old Man Face Ski Mask"
-- image_url (image_state AVAILABLE).
--
-- FIX: reuse the same authoritative access rule as mig_298 — accessible iff
-- visibility='GLOBAL_SAFE' OR user_id = auth.uid(). One guard at the top, applied ONLY to
-- end-user callers (auth.uid() IS NOT NULL). Service-role / internal SECURITY DEFINER callers
-- (auth.uid() NULL — the gallery/image self-tests and the workspace card's internal use) are
-- trusted and unchanged; anon has no EXECUTE grant. Unauthorised/unknown product returns the
-- neutral no-image response (image_url NULL, image_state UNAVAILABLE_NO_SOURCE) — identical to
-- a legitimate image-less product, so protected products cannot be distinguished. Signature,
-- response contract, supplier fallback, Product Asset Lock handling all byte-preserved. Stays
-- STABLE/SECURITY DEFINER, search_path='', schema-qualified.
--
-- OUT OF SCOPE (flagged, not changed): the sibling write-pipeline overloads
-- fn_resolve_product_image(uuid,uuid,uuid,boolean[,boolean]) take an explicit p_tenant and
-- persist to product_asset_intelligence; they are authenticated-executable and do not verify
-- p_tenant = auth.uid(). They are internal asset-resolution functions, not the display RPC;
-- securing them needs a separate review (see report).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  r record; v_prov text; v_eid text; v_fallback text; v_research_done boolean;
BEGIN
  -- STAGE4D authorization: end-user callers may only resolve an image for a product that is
  -- GLOBAL_SAFE (shared) or owned by them. Null auth.uid() = trusted service/definer context.
  IF v_uid IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.commerce_products cp
       WHERE cp.id = p_product_id
         AND (cp.visibility = 'GLOBAL_SAFE' OR cp.user_id = v_uid)
     ) THEN
    RETURN jsonb_build_object('image_url',NULL,'source',NULL,'source_url',NULL,
      'source_provider',NULL,'market',NULL,'image_state','UNAVAILABLE_NO_SOURCE');
  END IF;

  SELECT source_provider, source_entity_id INTO v_prov, v_eid
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false AND availability='AVAILABLE'
    AND coalesce(image_url,'')<>'' AND coalesce(source_entity_id,'')<>''
  ORDER BY is_primary DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END, image_url
  LIMIT 1;

  IF v_eid IS NOT NULL THEN
    SELECT image_url, source_provider, source_url, market INTO r
    FROM public.product_image_assets
    WHERE product_id=p_product_id AND source_provider=v_prov AND source_entity_id=v_eid
      AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
    ORDER BY coalesce((provenance->>'gallery_position')::int, 999) ASC, is_primary DESC, image_url
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('image_url', r.image_url,
        'source', CASE r.source_provider WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                         WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE r.source_provider END,
        'source_url', r.source_url, 'source_provider', r.source_provider, 'market', r.market, 'image_state','AVAILABLE');
    END IF;
  END IF;

  SELECT coalesce(spa.source_url, nullif(sp.image_url,'')) INTO v_fallback
  FROM public.commerce_products cp
  JOIN public.commerce_supplier_products sp
    ON sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                        nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
  LEFT JOIN LATERAL (
    SELECT a.source_url FROM public.supplier_product_assets a
    WHERE a.supplier_product_id=sp.source_product_id AND a.availability='AVAILABLE'
      AND a.rights_state='SUPPLIER_PROVIDED' AND a.asset_type IN ('PRIMARY_IMAGE','IMAGE') AND coalesce(a.source_url,'')<>''
    ORDER BY a.is_primary DESC LIMIT 1) spa ON true
  WHERE cp.id=p_product_id LIMIT 1;
  IF coalesce(v_fallback,'')<>'' THEN
    RETURN jsonb_build_object('image_url',v_fallback,'source','SUPPLIER_PROVIDED','source_url',v_fallback,
      'source_provider','CJ_SUPPLIER','market',NULL,'image_state','AVAILABLE');
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                 WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                   AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
  RETURN jsonb_build_object('image_url',NULL,'source',NULL,'source_url',NULL,'source_provider',NULL,'market',NULL,
    'image_state', CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END);
END; $function$;
