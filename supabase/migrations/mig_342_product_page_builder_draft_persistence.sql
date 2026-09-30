-- mig_342: Server-side, tenant-isolated product-page builder draft persistence.
--
-- Finding: merchant product-page builder drafts are DEVICE-LOCAL ONLY. The builder
-- (src/lib/storefront/builder-spec.ts loadDraft/saveDraft) persists to localStorage; the
-- "Save draft" button reports "Draft saved on this device." A merchant who switches device or
-- clears storage loses their in-progress edits.
--
-- Smallest secure fix reusing the existing contract: store the builder draft on the merchant's
-- own commerce_product_pages row in a SEPARATE `builder_draft` jsonb column (never in
-- runtime_contract / published_spec / review_state / publication_state). Publishing continues to
-- use the canonical published snapshot, so an already-PUBLISHED revision is NOT altered by saving
-- a draft. Tenant isolation is enforced by user_id = auth.uid() in SECURITY DEFINER RPCs (and the
-- table's existing RLS). Nothing is published; no published revision changes.

ALTER TABLE public.commerce_product_pages
  ADD COLUMN IF NOT EXISTS builder_draft jsonb,
  ADD COLUMN IF NOT EXISTS builder_draft_updated_at timestamptz;

-- Save (upsert) the merchant's builder draft for a page they own. Draft-only; never touches
-- publication/review state or the published snapshot.
CREATE OR REPLACE FUNCTION public.fn_save_product_page_draft(p_page_id uuid, p_draft jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_owner uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  IF p_page_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','missing_page_id'); END IF;
  IF p_draft IS NULL OR jsonb_typeof(p_draft) <> 'object' THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_draft');
  END IF;
  -- Guard payload size (a builder draft is small).
  IF length(p_draft::text) > 200000 THEN
    RETURN jsonb_build_object('ok',false,'error','draft_too_large');
  END IF;
  SELECT user_id INTO v_owner FROM public.commerce_product_pages WHERE id = p_page_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','page_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  UPDATE public.commerce_product_pages
     SET builder_draft = p_draft, builder_draft_updated_at = now()
   WHERE id = p_page_id AND user_id = v_uid;

  RETURN jsonb_build_object('ok',true,'page_id',p_page_id,'saved_at', now(),
    'scope','DEVICE_INDEPENDENT_SERVER_DRAFT',
    'note','Draft only; publication/review state and the published snapshot are untouched.');
END; $function$;

-- Load the merchant's builder draft for a page they own.
CREATE OR REPLACE FUNCTION public.fn_load_product_page_draft(p_page_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); r record;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  IF p_page_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','missing_page_id'); END IF;
  SELECT user_id, builder_draft, builder_draft_updated_at INTO r
    FROM public.commerce_product_pages WHERE id = p_page_id;
  IF r.user_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','page_not_found'); END IF;
  IF r.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  RETURN jsonb_build_object('ok',true,'page_id',p_page_id,
    'has_draft', r.builder_draft IS NOT NULL,
    'draft', r.builder_draft,
    'updated_at', r.builder_draft_updated_at);
END; $function$;

COMMENT ON FUNCTION public.fn_save_product_page_draft(uuid,jsonb) IS
  'Tenant-isolated server-side product-page builder draft save. Draft-only column; never alters publication/review state or the published snapshot. mig_342.';
COMMENT ON FUNCTION public.fn_load_product_page_draft(uuid) IS
  'Tenant-isolated server-side product-page builder draft load. mig_342.';

-- Selftest: round-trip + cross-tenant denial + published revision untouched (rolled back).
CREATE OR REPLACE FUNCTION public.fn_product_page_draft_selftest(p_page_id uuid, p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; v_save jsonb; v_load jsonb; v_cross jsonb;
  v_pre_pub text; v_post_pub text; v_pre_spec boolean; v_post_spec boolean;
  v_pre_draft boolean; v_post_draft boolean;
BEGIN
  SELECT publication_state, (runtime_contract ? 'published_spec'), (builder_draft IS NOT NULL)
    INTO v_pre_pub, v_pre_spec, v_pre_draft FROM public.commerce_product_pages WHERE id = p_page_id;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role','authenticated')::text, true);
    v_save := public.fn_save_product_page_draft(p_page_id, jsonb_build_object('headline','Draft H','sellingPrice',39.99,'benefits', jsonb_build_array('a','b')));
    v_load := public.fn_load_product_page_draft(p_page_id);
    -- cross-tenant: a different uid must be denied
    PERFORM set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-000000000000','role','authenticated')::text, true);
    v_cross := public.fn_save_product_page_draft(p_page_id, jsonb_build_object('x',1));
    SELECT publication_state, (runtime_contract ? 'published_spec')
      INTO v_post_pub, v_post_spec FROM public.commerce_product_pages WHERE id = p_page_id;
    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN
      v_save := coalesce(v_save, jsonb_build_object('status','ERR','err',SQLERRM));
    END IF;
  END;

  v := v || jsonb_build_object('case','save_ok','pass', coalesce((v_save->>'ok')::boolean,false));
  v := v || jsonb_build_object('case','load_roundtrip','pass',
    coalesce((v_load->>'ok')::boolean,false) AND (v_load->'draft'->>'headline') = 'Draft H');
  v := v || jsonb_build_object('case','cross_tenant_denied','pass', coalesce(v_cross->>'error','')='cross_tenant_rejected');
  v := v || jsonb_build_object('case','publication_state_untouched','pass', coalesce(v_post_pub,'') IS NOT DISTINCT FROM coalesce(v_pre_pub,''));
  v := v || jsonb_build_object('case','published_snapshot_untouched','pass', v_post_spec IS NOT DISTINCT FROM v_pre_spec);
  SELECT (builder_draft IS NOT NULL) INTO v_post_draft FROM public.commerce_product_pages WHERE id = p_page_id;
  v := v || jsonb_build_object('case','draft_not_persisted_by_test','pass', v_post_draft IS NOT DISTINCT FROM v_pre_draft,
    'observed', jsonb_build_object('pre', v_pre_draft, 'post', v_post_draft));

  RETURN jsonb_build_object('suite','product_page_draft_persistence',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
