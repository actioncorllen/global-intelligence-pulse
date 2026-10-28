-- ============================================================================
-- mig_298_gallery_tenant_authorization.sql
-- STRATELOQ-STAGE4D-GALLERY-TENANT-AUTHORISATION
--
-- SECURITY DEFECT: fn_resolve_product_gallery is SECURITY DEFINER and EXECUTE-granted to
-- `authenticated`, but was NOT tenant-scoped — an authenticated user could pass an arbitrary
-- canonical product_id and receive image URLs/provenance for a product in another workspace.
--
-- AUTHORITATIVE ACCESS RULE (reused, not invented): a commerce_products row is accessible to
-- the caller when visibility='GLOBAL_SAFE' (the deliberately shared catalogue) OR user_id =
-- auth.uid() (the owning tenant). This mirrors the ownership model the workspace contract uses
-- (tenant = commerce_products.user_id = auth.uid()) and preserves GLOBAL_SAFE sharing.
--
-- SMALLEST SAFE FIX: add one authorization guard at the top of the RPC. It applies ONLY to
-- end-user callers (auth.uid() IS NOT NULL). Service-role / internal SECURITY DEFINER callers
-- (auth.uid() IS NULL — the gallery self-test and backend consumers) are trusted and unchanged;
-- `anon` has no EXECUTE grant (unchanged). An unauthorised or unknown product returns the
-- neutral empty gallery (count 0, no images, no source identity) — identical to a legitimate
-- image-less product — so existence/metadata of protected products cannot be distinguished.
-- Everything else (5-image cap, source-item identity lock, states, rights handling) is byte-for
-- -byte preserved. Function stays STABLE/SECURITY DEFINER, search_path='', schema-qualified refs.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_product_gallery(p_product_id uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_lim int := least(greatest(coalesce(p_limit,5),1),5);
  v_prov text; v_eid text; v_imgs jsonb; v_count int; v_state text; v_ident text; v_research_done boolean;
BEGIN
  -- STAGE4D authorization: end-user callers may only resolve a gallery for a product that is
  -- GLOBAL_SAFE (shared) or owned by them. Null auth.uid() = trusted service/definer context.
  IF v_uid IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.commerce_products cp
       WHERE cp.id = p_product_id
         AND (cp.visibility = 'GLOBAL_SAFE' OR cp.user_id = v_uid)
     ) THEN
    RETURN jsonb_build_object('images','[]'::jsonb,'count',0,
      'gallery_state','UNAVAILABLE_NO_SOURCE','gallery_identity_state','SAME_PRODUCT_GALLERY_UNAVAILABLE',
      'card_source_provider',NULL,'card_source_item_id',NULL,
      'gallery_source_provider',NULL,'gallery_source_item_id',NULL);
  END IF;

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
