-- ============================================================================
-- mig_263_ebay_image_enrichment.sql
-- STRATELOQ-ECOM-HISTORICAL-PRODUCT-IMAGE-ENRICHMENT-013X
--
-- The two researched-but-imageless founder products (digital picture frame,
-- red light therapy led mask) were scored via the Monday orchestrator (no on-demand
-- research run exists) and their eBay marketplace evidence was ingested on 2026-09-05,
-- BEFORE fn_ingest_ebay_listings began persisting image.imageUrl. So no run exists to
-- post fresh evidence to via fn_research_ingest_source.
--
-- This adds a thin, bounded, service-role enrichment RPC that:
--   1) ingests a fresh eBay Browse response for the canonical product via the EXISTING
--      fn_ingest_ebay_listings (which applies the established MATCHED/LIKELY_MATCH
--      relevance gate and now stores image_url) -> writes commerce_signals bound to the
--      canonical product_id;
--   2) captures the image through the EXISTING 013W pipeline
--      (fn_backfill_product_images_from_evidence);
--   3) returns the resolved image state.
--
-- It deliberately does NOT call fn_finalize_research_run / fn_assemble_real_product_market
-- / fn_pod_evaluate, so it changes NO score, decision, band, coverage, or research run.
-- No keyword-only assignment (relevance gate enforced inside fn_ingest_ebay_listings);
-- no image fabricated; no image copied between products.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_enrich_product_image_from_ebay(
  p_product_id uuid, p_market text, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_ing jsonb; v_bf jsonb; v_img jsonb; v_mkt text := upper(btrim(coalesce(p_market,'')));
BEGIN
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.commerce_products WHERE id=p_product_id) THEN
    RETURN jsonb_build_object('status','product_not_found'); END IF;

  -- 1) ingest fresh eBay listings (relevance-gated; stores image_url) bound to product_id
  v_ing := public.fn_ingest_ebay_listings(p_product_id, 'EBAY_'||v_mkt, p_items, false);
  -- 2) capture image via the existing 013W pipeline (MATCHED marketplace evidence only)
  v_bf  := public.fn_backfill_product_images_from_evidence(p_product_id);
  -- 3) resolved canonical image state (product-global)
  v_img := public.fn_resolve_product_image(p_product_id, v_mkt);

  RETURN jsonb_build_object('status','ok','market',v_mkt,
    'ingest_status', v_ing->>'status', 'marketplace_activity_state', v_ing->>'marketplace_activity_state',
    'items_returned', v_ing->>'items_returned', 'ingested_signals', v_ing->>'ingested_signals',
    'image_backfill', v_bf, 'resolved_image_state', v_img->>'image_state', 'resolved_source', v_img->>'source',
    'contract','pulse_image_enrich_ebay_v1_013x');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_enrich_product_image_from_ebay(uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_enrich_product_image_from_ebay(uuid,text,jsonb) TO service_role;
