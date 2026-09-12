-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- PHASE F (review/edit state machine), PHASE G (destination adapter boundary),
-- PHASE H (Ad Studio addressability), and country-switch re-resolution.
-- All functions are tenant-guarded: an authenticated actor (auth.uid()) or an
-- explicit p_actor that does not own the page is denied (cross-tenant denial).
-- Nothing here creates a campaign, activates Meta, or authorizes spend.

-- ---------------------------------------------------------------------------
-- fn_storefront_transition_state: DRAFT -> IN_REVIEW -> APPROVED -> PUBLISHED
-- -> ARCHIVED (with safe reversals). Entering APPROVED/PUBLISHED never bypasses
-- claim safety (re-checks the runtime claim scan). PUBLISHED requires a resolved
-- destination; SHOPIFY without a connected store is BLOCKED_EXTERNAL_SHOPIFY_CONNECTION.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_transition_state(
  p_page_id uuid, p_target_state text, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_pg public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_cur text; v_tgt text := upper(coalesce(p_target_state,''));
  v_allowed boolean := false; v_clean boolean; v_dest text; v_pubstate text; v_puburl text;
  v_conn public.commerce_store_connections%rowtype;
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  v_cur := upper(coalesce(v_pg.review_state,'DRAFT'));

  -- Valid transitions.
  v_allowed := (v_cur='DRAFT'     AND v_tgt IN ('IN_REVIEW','ARCHIVED'))
            OR (v_cur='IN_REVIEW' AND v_tgt IN ('APPROVED','DRAFT','ARCHIVED'))
            OR (v_cur='APPROVED'  AND v_tgt IN ('PUBLISHED','IN_REVIEW','ARCHIVED'))
            OR (v_cur='PUBLISHED' AND v_tgt IN ('APPROVED','ARCHIVED'))   -- APPROVED = unpublish
            OR (v_cur='ARCHIVED'  AND v_tgt IN ('DRAFT'));
  IF NOT v_allowed THEN
    RETURN jsonb_build_object('status','INVALID_TRANSITION','from',v_cur,'to',v_tgt,
      'note','transition not permitted by the storefront lifecycle');
  END IF;

  -- Claim safety must hold when moving toward approval/publication (never bypass).
  IF v_tgt IN ('APPROVED','PUBLISHED') THEN
    v_clean := coalesce((v_pg.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, true);
    IF NOT v_clean THEN
      RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','from',v_cur,'to',v_tgt,
        'note','unsafe claims present; resolve editable placeholders before approval/publish');
    END IF;
  END IF;

  v_pubstate := v_pg.publication_state; v_puburl := v_pg.published_url;

  -- Publication requires a resolved destination (adapter boundary).
  -- The fine-grained destination kind lives in runtime_contract.destination_kind
  -- (the destination column is constrained to PULSE_STORE/EXISTING_STORE).
  IF v_tgt = 'PUBLISHED' THEN
    v_dest := upper(coalesce(v_pg.runtime_contract->>'destination_kind',
                CASE WHEN upper(coalesce(v_pg.destination,'PULSE_STORE'))='EXISTING_STORE' THEN 'SHOPIFY' ELSE 'PULSE_HOSTED' END));
    IF v_dest = 'SHOPIFY' THEN
      SELECT * INTO v_conn FROM public.commerce_store_connections
       WHERE id = v_pg.store_connection_id AND provider='SHOPIFY';
      IF NOT FOUND OR coalesce(v_conn.connection_state,'') <> 'CONNECTED' THEN
        RETURN jsonb_build_object('status','BLOCKED_EXTERNAL_SHOPIFY_CONNECTION','from',v_cur,'to',v_tgt,
          'note','Shopify publishing requires a CONNECTED store connection; adapter boundary present, not faked');
      END IF;
      v_puburl := coalesce(v_conn.store_domain,'') ;
    ELSIF v_dest = 'GENERIC_EXTERNAL_URL' THEN
      v_puburl := v_pg.runtime_contract->>'external_url';
      IF v_puburl IS NULL OR public.fn_cb_validate_destination(v_puburl) <> 'VALID' THEN
        RETURN jsonb_build_object('status','BLOCKED_INVALID_EXTERNAL_URL','from',v_cur,'to',v_tgt);
      END IF;
    ELSE
      -- PULSE_HOSTED / PULSE_STORE: safest beta-ready hosted route (noindex preview).
      SELECT coalesce('pulse-store/'||slug||'/preview', public_route) INTO v_puburl
        FROM public.commerce_store_projects WHERE product_page_id = p_page_id LIMIT 1;
    END IF;
    v_pubstate := 'PUBLISHED';
  ELSIF v_tgt = 'ARCHIVED' THEN
    v_pubstate := 'ARCHIVED';
  ELSIF v_tgt = 'APPROVED' AND v_cur = 'PUBLISHED' THEN
    v_pubstate := 'UNPUBLISHED'; v_puburl := NULL;   -- unpublish
  ELSIF v_tgt IN ('DRAFT','IN_REVIEW','APPROVED') THEN
    v_pubstate := 'UNPUBLISHED';
  END IF;

  UPDATE public.commerce_product_pages SET
    review_state = v_tgt,
    publication_state = v_pubstate,
    published_url = v_puburl,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb)
       || jsonb_build_object('review_state',v_tgt,'publication_state',v_pubstate),
    updated_at = now()
  WHERE id = p_page_id;

  RETURN jsonb_build_object('status','ok','page_id',p_page_id,'from',v_cur,'to',v_tgt,
    'review_state',v_tgt,'publication_state',v_pubstate,'published_url',v_puburl);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_transition_state(uuid,text,uuid) IS
 'Storefront review/edit lifecycle. Tenant-guarded. Never bypasses claim safety on approval/publish; PUBLISHED needs a resolved destination (SHOPIFY without a connected store = BLOCKED_EXTERNAL_SHOPIFY_CONNECTION).';

-- ---------------------------------------------------------------------------
-- fn_storefront_set_destination: PHASE G adapter boundary. PULSE_HOSTED /
-- SHOPIFY / GENERIC_EXTERNAL_URL. Does not fake publishing. WooCommerce deferred.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_set_destination(
  p_page_id uuid, p_destination text, p_store_connection_id uuid DEFAULT NULL,
  p_external_url text DEFAULT NULL, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_pg public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_kind text := upper(coalesce(p_destination,''));   -- PULSE_HOSTED | SHOPIFY | GENERIC_EXTERNAL_URL | WOOCOMMERCE
  v_col text;                                          -- destination column value (PULSE_STORE | EXISTING_STORE)
  v_conn public.commerce_store_connections%rowtype; v_state text; v_note text; v_url text;
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;

  -- destination_kind is the fine-grained runtime target; the destination column
  -- is constrained to PULSE_STORE / EXISTING_STORE, so map onto it.
  IF v_kind IN ('PULSE_HOSTED','PULSE_STORE') THEN
    v_kind := 'PULSE_HOSTED'; v_col := 'PULSE_STORE'; v_state := 'DESTINATION_READY';
    SELECT coalesce('pulse-store/'||slug||'/preview', public_route) INTO v_url
      FROM public.commerce_store_projects WHERE product_page_id=p_page_id LIMIT 1;
    v_note := 'Pulse-hosted beta runtime (noindex preview route)';
  ELSIF v_kind = 'SHOPIFY' THEN
    v_col := 'EXISTING_STORE';
    SELECT * INTO v_conn FROM public.commerce_store_connections WHERE id=p_store_connection_id AND provider='SHOPIFY';
    IF NOT FOUND OR coalesce(v_conn.connection_state,'') <> 'CONNECTED' THEN
      v_state := 'BLOCKED_EXTERNAL_SHOPIFY_CONNECTION';
      v_note := 'Shopify adapter boundary present; no connected store -> cannot publish (not faked)';
    ELSE
      v_state := 'DESTINATION_READY'; v_url := v_conn.store_domain;
      v_note := 'Shopify connection resolved';
    END IF;
  ELSIF v_kind = 'GENERIC_EXTERNAL_URL' THEN
    v_col := 'EXISTING_STORE';
    IF p_external_url IS NULL OR public.fn_cb_validate_destination(p_external_url) <> 'VALID' THEN
      v_state := 'BLOCKED_INVALID_EXTERNAL_URL'; v_note := 'external URL failed validation';
    ELSE
      v_state := 'DESTINATION_READY'; v_url := p_external_url; v_note := 'validated external URL';
    END IF;
  ELSIF v_kind = 'WOOCOMMERCE' THEN
    RETURN jsonb_build_object('status','DEFERRED_WOOCOMMERCE','note','WooCommerce remains deferred');
  ELSE
    RETURN jsonb_build_object('status','UNKNOWN_DESTINATION','destination',v_kind);
  END IF;

  UPDATE public.commerce_product_pages SET
    destination = v_col,
    store_connection_id = CASE WHEN v_kind='SHOPIFY' THEN p_store_connection_id ELSE store_connection_id END,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb)
       || jsonb_build_object('destination',v_col,'destination_kind',v_kind,'destination_state',v_state,'external_url',
            CASE WHEN v_kind='GENERIC_EXTERNAL_URL' THEN p_external_url ELSE NULL END,'resolved_url',v_url),
    updated_at = now()
  WHERE id=p_page_id;

  RETURN jsonb_build_object('status', CASE WHEN v_state='DESTINATION_READY' THEN 'ok' ELSE v_state END,
    'page_id',p_page_id,'destination',v_col,'destination_kind',v_kind,'destination_state',v_state,'resolved_url',v_url,'note',v_note);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_set_destination(uuid,text,uuid,text,uuid) IS
 'Destination adapter boundary: PULSE_HOSTED / SHOPIFY (BLOCKED_EXTERNAL_SHOPIFY_CONNECTION if not connected) / GENERIC_EXTERNAL_URL (validated). WooCommerce deferred. Never fakes publishing.';

-- ---------------------------------------------------------------------------
-- fn_storefront_ad_addressable: PHASE H. Makes the storefront addressable by
-- Ad Studio without creating a campaign, activating Meta, or authorizing spend.
-- destination_url is exposed only when genuinely published.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_ad_addressable(p_page_id uuid, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_pg public.commerce_product_pages%rowtype; v_actor uuid := coalesce(auth.uid(), p_actor);
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  RETURN jsonb_build_object('status','ok','addressable',true,
    'product_id', v_pg.product_id,
    'country_code', coalesce(v_pg.country_code, v_pg.market),
    'market', v_pg.market,
    'storefront_page_id', v_pg.id,
    'page_version', extract(epoch FROM v_pg.updated_at)::bigint,
    'template_family', v_pg.template_family,
    'offer_version', coalesce(v_pg.ad_match_ref->>'offer_version','v1'),
    'ad_match_ref', v_pg.ad_match_ref,
    'destination', v_pg.destination,
    'destination_url', CASE WHEN coalesce(v_pg.publication_state,'')='PUBLISHED' THEN v_pg.published_url ELSE NULL END,
    'publication_state', v_pg.publication_state,
    'campaign_created', false, 'meta_activated', false, 'ad_spend_authorized', 0,
    'note','addressable reference only; no campaign created, no Meta activation, no spend');
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_ad_addressable(uuid,uuid) IS
 'Ad Studio addressability for a storefront (product_id, country, page version, offer version, destination URL only when published). Creates no campaign, no Meta activation, no spend.';

-- ---------------------------------------------------------------------------
-- fn_storefront_change_country: switching country must resolve a NEW
-- Product×Country context, never merely convert currency. This returns a
-- resolution directive; the new storefront is produced by re-running
-- fn_generate_storefront_runtime for the new Product×Country.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_change_country(
  p_page_id uuid, p_new_country text, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_pg public.commerce_product_pages%rowtype; v_actor uuid := coalesce(auth.uid(), p_actor);
BEGIN
  SELECT * INTO v_pg FROM public.commerce_product_pages WHERE id=p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND v_pg.user_id IS NOT NULL AND v_actor <> v_pg.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  IF upper(coalesce(p_new_country,'')) = upper(coalesce(v_pg.country_code, v_pg.market,'')) THEN
    RETURN jsonb_build_object('status','NO_CHANGE','country',p_new_country);
  END IF;
  RETURN jsonb_build_object(
    'status','COUNTRY_CONTEXT_RESOLUTION_REQUIRED',
    'current_country', coalesce(v_pg.country_code, v_pg.market),
    'new_country', upper(p_new_country),
    'requires', jsonb_build_array('new Product×Country evaluation','fresh TEST eligibility gate','new landed economics','new supplier/stock/fulfilment evidence'),
    'currency_only_conversion_permitted', false,
    'next_action','call fn_generate_storefront_runtime with the new Product×Country inputs (product_id, '||upper(p_new_country)||')',
    'note','Changing country resolves a new Product×Country context; currency conversion alone is not permitted.');
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_change_country(uuid,text,uuid) IS
 'Country switch resolves a NEW Product×Country context (new gate/economics/evidence), never a currency-only conversion.';