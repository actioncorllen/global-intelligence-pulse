-- ============================================================================
-- mig_306_creative_studio_display_image_and_static_result.sql
-- STRATELOQ — REGRESSION REPAIR (real founder live test):
--   F1  Creative Studio showed "Product image unavailable" for a Product Card that
--       clearly displays a product image (humidifier: 37 marketplace images, 0
--       authoritative). Root cause: the studio resolved its preview ONLY from
--       fn_ad_product_card_authority.primary_asset (authoritative-only), which is
--       empty for a marketplace-sourced card. Founder rule: if the Product Card
--       shows an image, Creative Studio must show THAT SAME image.
--   F2  Static ad generation (GRID_MULTI_CARD) for the same card stalled. Root cause
--       is the SAME authoritative-only source resolution inside
--       fn_media_image_execution_context: v_url := authority.primary_asset.url; when
--       null the job is set BLOCKED_EXTERNAL_PROVIDER / no_authoritative_product_asset.
--       Additionally the UI could never OBSERVE a completed static job because
--       fn_creative_studio_generate returns only job_id (never an asset_id) and the
--       browser polled by asset_id — so a job that reached GENERATED_REVIEW_REQUIRED
--       stayed "Creating creative" forever.
--
-- What this migration changes (and NOT):
--   * DISPLAY + creative SOURCE now use the EXACT Product Card display image via the
--     existing fn_product_card_display_image (authoritative-preferred, else the primary
--     display image of ANY provenance). Provenance is kept HONEST: a marketplace image
--     is NEVER relabelled CUSTOMER_OWNED; the resolved source carries its true
--     source_provider / rights_state / is_authoritative flags.
--   * The Product Asset Lock itself (fn_ad_product_card_authority) and the storefront
--     builder's honest PRODUCT_ASSET_REQUIRED gate are UNCHANGED.
--   * Adds a client-callable static image-job result resolver so the UI can poll a
--     STATIC job by job_id and reach the completed media asset.
-- Idempotent (CREATE OR REPLACE). No table/enum/contract renames.
-- ============================================================================

-- ── F1: client-callable Creative Studio product preview (DISPLAY image + name) ──
-- Tenant is derived from auth.uid() (never trusted from the client). Returns the
-- Product Card's display image so the studio preview matches the card exactly.
CREATE OR REPLACE FUNCTION public.fn_creative_studio_product_preview(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_name text; v_img jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;
  SELECT user_id, title INTO v_owner, v_name FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  v_img := public.fn_product_card_display_image(v_tenant, p_product_id, p_market);
  RETURN jsonb_build_object(
    'status','ok',
    'product_id', p_product_id::text,
    'product_name', v_name,
    'has_image', coalesce((v_img->>'has_image')::boolean,false),
    'image_url', v_img->>'url',
    'is_authoritative', coalesce((v_img->>'is_authoritative')::boolean,false),
    'source_provider', v_img->>'source_provider',
    'rights_state', v_img->>'rights_state');
END; $fn$;
REVOKE EXECUTE ON FUNCTION public.fn_creative_studio_product_preview(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_creative_studio_product_preview(uuid,text) TO authenticated, service_role;

-- ── F2 (source): executor context resolves the Product Card DISPLAY image ──────
-- Identical to mig_300 EXCEPT the source-image resolution: it now uses
-- fn_product_card_display_image (authoritative-preferred, else primary display image)
-- instead of authority-only, so a card that visibly shows a product image can be used
-- as the creative base. Provenance stays honest (true source_provider/rights_state/
-- is_authoritative are recorded); the PRODUCT IDENTITY LOCK prompt is preserved.
CREATE OR REPLACE FUNCTION public.fn_media_image_execution_context(p_job_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_disp jsonb; v_url text; v_fmt jsonb; v_prompt text; v_size text; v_path text;
  v_product uuid; v_name text; v_claimed boolean;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('execute',false,'reason','job_not_found'); END IF;
  IF j.status <> 'GENERATING' THEN
    RETURN jsonb_build_object('execute',false,'reason','not_generating','status',j.status);
  END IF;

  -- Idempotent claim: only the first caller for a GENERATING, unclaimed job proceeds.
  UPDATE public.media_image_jobs
     SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('executor_claimed_at', now())
   WHERE id=p_job_id AND status='GENERATING' AND (provenance->>'executor_claimed_at') IS NULL
  RETURNING true INTO v_claimed;
  IF NOT coalesce(v_claimed,false) THEN
    RETURN jsonb_build_object('execute',false,'reason','already_claimed');
  END IF;

  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  v_product := b.product_id;
  v_name := coalesce(nullif(btrim(b.product_name),''), 'the product');

  -- Product Card DISPLAY image (authoritative preferred; else the exact primary display
  -- image of any provenance). Founder rule: the creative uses the exact Product Card
  -- visual. Provenance is kept honest — a marketplace image is NOT relabelled.
  v_disp := public.fn_product_card_display_image(j.tenant_id, v_product, b.market);
  v_url := v_disp->>'url';
  IF coalesce((v_disp->>'has_image')::boolean,false) = false OR v_url IS NULL OR v_url='' THEN
    UPDATE public.media_image_jobs
       SET status='BLOCKED_EXTERNAL_PROVIDER', error_state='no_product_image', updated_at=now()
     WHERE id=p_job_id;
    RETURN jsonb_build_object('execute',false,'reason','no_product_image');
  END IF;

  -- Record the true source provenance on the job (honest; never relabelled).
  UPDATE public.media_image_jobs
     SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
           'creative_source', jsonb_build_object(
             'product_card_asset_id', v_disp->>'asset_id',
             'source_provider', v_disp->>'source_provider',
             'rights_state', v_disp->>'rights_state',
             'is_authoritative', coalesce((v_disp->>'is_authoritative')::boolean,false),
             'basis','exact Product Card display image (fn_product_card_display_image)'))
   WHERE id=p_job_id;

  -- Format-aware prompt (creative_format template + angle brief) with a strict product-preservation
  -- clause. Critical AD TEXT is intentionally NOT drawn by the model (founder standard §13: text is
  -- deterministic/compositor); the model produces the product-preserving base composition.
  v_fmt := j.provenance->'creative_format';
  v_prompt := left(concat_ws(' ',
    coalesce(v_fmt->>'prompt_template', a.static_creative_brief, a.visual_concept, 'Premium commercial advertising product photo.'),
    'PRODUCT IDENTITY LOCK: the exact product (' || v_name || ') shown in the provided image must be preserved with identical shape, geometry, proportions, colours, materials, buttons, controls, visible components, branding and logo. Do NOT substitute, redraw, restyle, recolour or invent any product feature, and do NOT replace it with a similar item.',
    'The model may build background, layout zones, surfaces, lighting and supporting graphic shapes around the product.',
    'Do NOT render any text, words, letters, numbers, logos, price tags, badges, stickers, watermarks, UI overlays, captions, people or hands (advertising text is added deterministically afterward).'
  ), 3200);

  -- gpt-image-1 supported sizes.
  v_size := CASE coalesce(j.aspect_ratio,'1:1')
              WHEN '9:16' THEN '1024x1536'
              WHEN '4:5'  THEN '1024x1536'
              WHEN '16:9' THEN '1536x1024'
              ELSE '1024x1024' END;

  v_path := j.tenant_id::text || '/' || coalesce(v_product::text,'noproduct') || '/' || p_job_id::text
            || '/' || gen_random_uuid()::text || '.png';

  RETURN jsonb_build_object(
    'execute', true, 'job_id', p_job_id, 'tenant_id', j.tenant_id, 'product_id', v_product,
    'market', b.market, 'source_image_url', v_url, 'prompt', v_prompt, 'size', v_size,
    'storage_path', v_path, 'model', 'gpt-image-1', 'aspect_ratio', coalesce(j.aspect_ratio,'1:1'),
    'source_asset_id', v_disp->>'asset_id',
    'source_is_authoritative', coalesce((v_disp->>'is_authoritative')::boolean,false),
    'source_rights_state', v_disp->>'rights_state',
    'source_provider', v_disp->>'source_provider',
    'creative_format', v_fmt->>'format');
END; $function$;
REVOKE EXECUTE ON FUNCTION public.fn_media_image_execution_context(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_image_execution_context(uuid) TO service_role;

-- ── F2 (observe): client-callable STATIC image-job result resolver ─────────────
-- The browser has only the job_id for a STATIC creative. This lets it poll the job by
-- id (tenant-scoped) and, once complete, reach the generated media asset id so it can
-- fetch the preview via the existing fn_media_generation_result / fn_media_asset_signed_ref.
CREATE OR REPLACE FUNCTION public.fn_creative_image_job_result(p_job_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); j public.media_image_jobs%rowtype; v_asset uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF p_job_id IS NULL THEN RETURN jsonb_build_object('status','no_job'); END IF;
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  v_asset := nullif(j.output_asset_refs->>0,'')::uuid;
  RETURN jsonb_build_object(
    'status','ok',
    'job_id', j.id::text,
    'job_status', j.status,
    'error_state', j.error_state,
    'asset_id', v_asset,
    'is_ready', (j.status IN ('GENERATED_REVIEW_REQUIRED','GENERATED_REAL')),
    'is_failed', (j.status IN ('FAILED','BLOCKED_EXTERNAL_PROVIDER','BLOCKED_CLAIM_REVIEW','BLOCKED_RIGHTS','BLOCKED_ASPECT')));
END; $fn$;
REVOKE EXECUTE ON FUNCTION public.fn_creative_image_job_result(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_creative_image_job_result(uuid) TO authenticated, service_role;
