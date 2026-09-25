-- STRATELOQ — Creative Image Executor: server-side context resolver + idempotent claim + fail
-- ============================================================================
-- Supports the generic automated static-image executor. Given a media_image_job in
-- GENERATING, resolves everything the executor needs (authoritative Product Card
-- image URL, format-aware prompt, size, deterministic storage path) and ATOMICALLY
-- CLAIMS the job so a duplicate webhook/refresh/retry cannot trigger a second paid
-- OpenAI call. No hardcoded product/image/prompt/path. No provider call here.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_media_image_execution_context(p_job_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_auth jsonb; v_url text; v_fmt jsonb; v_prompt text; v_size text; v_path text;
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

  -- Authoritative Product Card image (Product Asset Lock). Never a marketplace/reference image.
  v_auth := public.fn_ad_product_card_authority(j.tenant_id, v_product, b.market);
  v_url := v_auth->'primary_asset'->>'url';
  IF v_url IS NULL OR v_url='' THEN
    UPDATE public.media_image_jobs
       SET status='BLOCKED_EXTERNAL_PROVIDER', error_state='no_authoritative_product_asset', updated_at=now()
     WHERE id=p_job_id;
    RETURN jsonb_build_object('execute',false,'reason','no_authoritative_product_asset');
  END IF;

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
    'source_asset_id', v_auth->'primary_asset'->>'id',
    'creative_format', v_fmt->>'format');
END; $function$;

-- Genuine failure state for the executor (never leave a job stuck at GENERATING).
CREATE OR REPLACE FUNCTION public.fn_media_fail_image_job(p_job_id uuid, p_tenant uuid, p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_ok boolean;
BEGIN
  UPDATE public.media_image_jobs
     SET status='FAILED', error_state=left(coalesce(p_reason,'executor_failed'),200), updated_at=now(),
         provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('failed_at', now(), 'fail_reason', left(coalesce(p_reason,''),300))
   WHERE id=p_job_id AND tenant_id=p_tenant AND status IN ('GENERATING','READY_TO_DISPATCH')
  RETURNING true INTO v_ok;
  RETURN jsonb_build_object('ok', coalesce(v_ok,false), 'job_id', p_job_id, 'status', CASE WHEN coalesce(v_ok,false) THEN 'FAILED' ELSE 'no_transition' END);
END; $function$;

-- Server-side only (executor edge function uses the service role; not client-callable).
REVOKE EXECUTE ON FUNCTION public.fn_media_image_execution_context(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_image_execution_context(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.fn_media_fail_image_job(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_media_fail_image_job(uuid,uuid,text) TO service_role;
