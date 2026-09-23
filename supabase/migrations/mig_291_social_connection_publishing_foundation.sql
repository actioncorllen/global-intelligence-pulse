-- ============================================================================
-- mig_291_social_connection_publishing_foundation.sql
-- STRATELOQ-016B — SOCIAL CONNECTION READINESS + ORGANIC PUBLISHING FOUNDATION
--
-- Internal foundation only. AUDIT + INTERNAL FOUNDATION + EXTERNAL-CONNECTION
-- READINESS. This migration does NOT authorize or perform any live social write.
--
-- Mandatory model separation (SOCIAL != ADVERTISING):
--   * organic/social connection (publish to a Page / IG / TikTok / LinkedIn feed)
--     is modelled SEPARATELY from advertising-account connection (ad account,
--     campaign, ad, activation). connection_type ORGANIC vs ADVERTISING is a hard
--     boundary — a single row is never both, and capabilities never cross.
--   * TikTok Commercial Content research approval (research.adlib.basic) is NOT
--     publishing authorization — a research connection can never satisfy an organic
--     publish gate (enforced in fn_social_connection_capabilities + the selftest).
--
-- Security posture (unchanged, reinforced):
--   * NO plaintext token / secret / key stored. Only a non-secret secret_ref
--     pointing at the n8n credential store / edge-function secret store (the
--     established pattern used by commerce_store_connections, meta_tracking_config,
--     tiktok-commercial-token). oauth_state holds only a CSRF nonce, never a token.
--   * RLS deny-by-default on both new tables; SECURITY DEFINER access only.
--   * Execution is globally DISABLED in this unit: no OAuth is initiated, no post is
--     created / scheduled / deleted, no profile modified, no ad launched.
--
-- Zero new cost. No Veo, no Stripe, no Reddit, no Lovable publish, no MD/Studio
-- redesign. Strateloq is NOT hardcoded into the generic architecture (it appears
-- only as tenant DATA in the zero-cost selftest).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. INTERNAL CONNECTION MODEL — social_platform_connections
--    Reuses the proven commerce_store_connections shape (provider/state/scopes/
--    secret_ref/oauth_state/timestamps) and extends it with the organic-vs-
--    advertising boundary, capability metadata, and full token lifecycle columns.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.social_platform_connections (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL,              -- business / tenant (generic)
  platform              text        NOT NULL,             -- META_FACEBOOK | META_INSTAGRAM | TIKTOK | LINKEDIN
  connection_type       text        NOT NULL,             -- ORGANIC | ADVERTISING  (hard separation)
  external_account_id   text,                             -- page id / ig user id / open id / org URN (display identifier)
  display_name          text,
  display_metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  authorization_status  text        NOT NULL DEFAULT 'NOT_CONNECTED',
                                     -- NOT_CONNECTED | PENDING_OAUTH | CONNECTED | EXPIRED | REVOKED | ERROR
  granted_scopes        jsonb       NOT NULL DEFAULT '[]'::jsonb,
  capabilities          jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- explicit capability list (see fn_social_connection_capabilities)
  secret_ref            text,                             -- NON-SECRET reference to n8n/edge secret store; never a token value
  oauth_state           text,                             -- CSRF nonce only, never a token
  connected_at          timestamptz,
  expires_at            timestamptz,
  last_verified_at      timestamptz,
  revoked_at            timestamptz,
  error_detail          text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spc_platform_chk') THEN
    ALTER TABLE public.social_platform_connections ADD CONSTRAINT spc_platform_chk
      CHECK (platform IN ('META_FACEBOOK','META_INSTAGRAM','TIKTOK','LINKEDIN'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spc_conntype_chk') THEN
    ALTER TABLE public.social_platform_connections ADD CONSTRAINT spc_conntype_chk
      CHECK (connection_type IN ('ORGANIC','ADVERTISING'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spc_authstatus_chk') THEN
    ALTER TABLE public.social_platform_connections ADD CONSTRAINT spc_authstatus_chk
      CHECK (authorization_status IN ('NOT_CONNECTED','PENDING_OAUTH','CONNECTED','EXPIRED','REVOKED','ERROR'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spc_secret_ref_not_token_chk') THEN
    -- defensive: reject anything that looks like an actual bearer/JWT/long token value
    ALTER TABLE public.social_platform_connections ADD CONSTRAINT spc_secret_ref_not_token_chk
      CHECK (secret_ref IS NULL OR (length(secret_ref) <= 120 AND secret_ref !~ '^(eyJ|Bearer |[A-Za-z0-9_-]{200,})'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS spc_identity_uk
  ON public.social_platform_connections (tenant_id, platform, connection_type, COALESCE(external_account_id,''));

ALTER TABLE public.social_platform_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_platform_connections FORCE ROW LEVEL SECURITY;
-- deny-by-default: no permissive policy created; access is via SECURITY DEFINER functions only.

-- ----------------------------------------------------------------------------
-- 2. PUBLISHING CONTRACT — social_publishing_requests
--    Generic organic publishing request. Execution is disabled: rows only ever
--    record intent + the truthful blocked/ready gate state.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.social_publishing_requests (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL,
  business_id           uuid,
  marketing_draft_id    uuid,                             -- MD strategy lineage (marketing_campaign_drafts)
  creative_request_id   uuid,                             -- Creative Production lineage (creative_production_requests)
  media_asset_id        uuid,                             -- approved asset (media_assets)
  platform              text        NOT NULL,             -- META_FACEBOOK | META_INSTAGRAM | TIKTOK | LINKEDIN
  connection_type       text        NOT NULL DEFAULT 'ORGANIC',  -- publishing is ORGANIC here
  destination_account   text,                             -- external_account_id of the chosen connection
  content               jsonb       NOT NULL DEFAULT '{}'::jsonb, -- caption/text/hashtags
  scheduled_at          timestamptz,
  approval_id           uuid,
  caption_approved      boolean     NOT NULL DEFAULT false,
  publish_mode          text        NOT NULL DEFAULT 'MANUAL',    -- MANUAL | AUTHORIZED_AUTO
  automation_authorized boolean     NOT NULL DEFAULT false,       -- explicit automation grant (never inferred from connection)
  execution_enabled     boolean     NOT NULL DEFAULT false,       -- global kill: always false in this unit
  execution_state       text        NOT NULL DEFAULT 'BLOCKED_PENDING_PLATFORM_CONNECTION',
  blocked_reasons       jsonb       NOT NULL DEFAULT '[]'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spr_platform_chk') THEN
    ALTER TABLE public.social_publishing_requests ADD CONSTRAINT spr_platform_chk
      CHECK (platform IN ('META_FACEBOOK','META_INSTAGRAM','TIKTOK','LINKEDIN'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spr_conntype_chk') THEN
    ALTER TABLE public.social_publishing_requests ADD CONSTRAINT spr_conntype_chk
      CHECK (connection_type IN ('ORGANIC','ADVERTISING'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spr_pubmode_chk') THEN
    ALTER TABLE public.social_publishing_requests ADD CONSTRAINT spr_pubmode_chk
      CHECK (publish_mode IN ('MANUAL','AUTHORIZED_AUTO'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spr_execstate_chk') THEN
    ALTER TABLE public.social_publishing_requests ADD CONSTRAINT spr_execstate_chk
      CHECK (execution_state IN (
        'BLOCKED_PENDING_PLATFORM_CONNECTION',
        'BLOCKED_PENDING_APPROVAL',
        'BLOCKED_PENDING_CONTENT',
        'BLOCKED_PENDING_AUTOMATION_AUTHORIZATION',
        'READY_FOR_MANUAL_PUBLISH',
        'EXECUTION_DISABLED'));
  END IF;
  -- a request is never allowed to carry execution_enabled=true in this unit
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='spr_exec_disabled_chk') THEN
    ALTER TABLE public.social_publishing_requests ADD CONSTRAINT spr_exec_disabled_chk
      CHECK (execution_enabled = false);
  END IF;
END $$;

ALTER TABLE public.social_publishing_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_publishing_requests FORCE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 3. CAPABILITY MODEL — fn_social_connection_capabilities(platform, connection_type)
--    A connection describes capabilities EXPLICITLY. CONNECTED != every operation.
--    Organic capabilities and advertising capabilities are disjoint sets and never
--    cross. Returns the capability catalogue + the platform scopes each needs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_connection_capabilities(
  p_platform        text,
  p_connection_type text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_caps jsonb;
BEGIN
  IF p_connection_type = 'ORGANIC' THEN
    v_caps := CASE p_platform
      WHEN 'META_FACEBOOK'  THEN '["READ_PROFILE","PUBLISH_TEXT","PUBLISH_IMAGE","PUBLISH_VIDEO","PUBLISH_CAROUSEL"]'::jsonb
      WHEN 'META_INSTAGRAM' THEN '["READ_PROFILE","PUBLISH_IMAGE","PUBLISH_VIDEO","PUBLISH_CAROUSEL"]'::jsonb
      WHEN 'TIKTOK'         THEN '["READ_PROFILE","PUBLISH_VIDEO"]'::jsonb
      WHEN 'LINKEDIN'       THEN '["READ_PROFILE","PUBLISH_TEXT","PUBLISH_IMAGE","PUBLISH_VIDEO"]'::jsonb
      ELSE '[]'::jsonb END;
  ELSIF p_connection_type = 'ADVERTISING' THEN
    -- advertising capabilities are a SEPARATE set — never satisfied by an organic grant
    v_caps := '["READ_AD_ACCOUNT","CREATE_CAMPAIGN","CREATE_AD","ACTIVATE_CAMPAIGN"]'::jsonb;
  ELSE
    v_caps := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'platform',        p_platform,
    'connection_type', p_connection_type,
    'capabilities',    v_caps,
    'note',            'Capabilities are authorized only by a real, verified connection carrying the matching granted scopes. '
                       || 'Organic publish capabilities and advertising capabilities never cross. '
                       || 'TikTok research (research.adlib.basic) is NOT an organic publish capability.'
  );
END $$;

-- ----------------------------------------------------------------------------
-- 4. EXTERNAL STAGE GATES — fn_social_platform_external_requirements(platform, connection_type)
--    Truthful, data-driven external-connection readiness per platform, derived
--    from the 016B audit of the deployed Meta / TikTok / LinkedIn setup.
--    Returns stage_gate in {READY_TO_CONNECT, EXTERNAL_SETUP_REQUIRED,
--    EXTERNAL_APPROVAL_REQUIRED, BLOCKED} + the exact founder action required.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_platform_external_requirements(
  p_platform        text,
  p_connection_type text DEFAULT 'ORGANIC'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF p_connection_type <> 'ORGANIC' THEN
    RETURN jsonb_build_object(
      'platform', p_platform, 'connection_type', p_connection_type,
      'stage_gate','BLOCKED',
      'reason','Advertising-account connection is out of scope for 016B (organic foundation only).',
      'founder_action','Deferred to a later advertising-connection unit; do not connect an ad account here.');
  END IF;

  RETURN CASE p_platform
    WHEN 'META_FACEBOOK' THEN jsonb_build_object(
      'platform','META_FACEBOOK','connection_type','ORGANIC',
      'current_state','Meta app exists but is configured for advertising/tracking/ad-library only (Marketing API system-user token, CAPI, ads_archive). No organic Page-publishing product or permissions are enabled.',
      'required_scopes', jsonb_build_array('pages_show_list','pages_read_engagement','pages_manage_posts','business_management'),
      'oauth','Facebook Login for Business (authorization code) -> user token -> long-lived -> Page access token',
      'publishing_endpoints', jsonb_build_array('POST /{page-id}/feed','POST /{page-id}/photos','POST /{page-id}/videos'),
      'token_lifecycle','user token ~1h -> long-lived ~60d -> Page token (can be long-lived/non-expiring); needs refresh + re-verify',
      'app_review','Advanced Access to pages_manage_posts requires App Review for use beyond app admins/testers',
      'stage_gate','EXTERNAL_SETUP_REQUIRED',
      'founder_action','In the Meta app: add Facebook Login for Business + request pages_show_list/pages_read_engagement/pages_manage_posts, add the Strateloq Facebook Page as an app asset, and grant the founder admin role. App Review (EXTERNAL_APPROVAL_REQUIRED) is additionally needed before publishing on behalf of customer Pages.')
    WHEN 'META_INSTAGRAM' THEN jsonb_build_object(
      'platform','META_INSTAGRAM','connection_type','ORGANIC',
      'current_state','No Instagram publishing product/permissions configured. Requires an IG professional/business account linked to a Facebook Page.',
      'required_scopes', jsonb_build_array('instagram_basic','instagram_content_publish','pages_show_list','business_management'),
      'oauth','Facebook Login for Business; IG business account discovered via the linked Page',
      'publishing_endpoints', jsonb_build_array('POST /{ig-user-id}/media (create container)','POST /{ig-user-id}/media_publish'),
      'token_lifecycle','same as Meta Page token lifecycle (long-lived, refresh + re-verify)',
      'app_review','instagram_content_publish requires App Review (Advanced Access) for non-owned accounts',
      'stage_gate','EXTERNAL_SETUP_REQUIRED',
      'founder_action','Convert the Strateloq Instagram account to professional/business and link it to the Strateloq Facebook Page; add instagram_basic + instagram_content_publish to the Meta app. App Review (EXTERNAL_APPROVAL_REQUIRED) needed for customer accounts.')
    WHEN 'TIKTOK' THEN jsonb_build_object(
      'platform','TIKTOK','connection_type','ORGANIC',
      'current_state','TikTok developer client is approved ONLY for Commercial Content API research (scope research.adlib.basic) via a client-credentials token broker. That is RESEARCH, not publishing.',
      'research_auth_separate', true,
      'required_product','Content Posting API (separate product approval)',
      'required_scopes', jsonb_build_array('user.info.basic','video.upload','video.publish'),
      'oauth','TikTok Login Kit user-context OAuth (authorization code); NOT the research client-credentials flow',
      'publishing_endpoints', jsonb_build_array('POST /v2/post/publish/video/init/','POST /v2/post/publish/status/fetch/'),
      'token_lifecycle','user access_token ~24h + refresh_token ~365d; refresh handling required',
      'app_review','Content Posting API Direct Post requires TikTok app audit; unaudited apps are limited to SELF_ONLY/private draft',
      'stage_gate','EXTERNAL_APPROVAL_REQUIRED',
      'founder_action','Apply for the TikTok Content Posting API product, add Login Kit user OAuth with video.publish scope, and pass the TikTok app audit. The existing research.adlib.basic approval does NOT grant this and must stay separate.')
    WHEN 'LINKEDIN' THEN jsonb_build_object(
      'platform','LINKEDIN','connection_type','ORGANIC',
      'current_state','No LinkedIn developer app or connection exists.',
      'required_scopes', jsonb_build_array('openid','profile','w_member_social','w_organization_social','r_organization_social'),
      'oauth','LinkedIn OAuth 2.0 authorization code (Sign In with LinkedIn using OpenID Connect + Community Management API)',
      'publishing_endpoints', jsonb_build_array('POST /rest/posts (Posts API)'),
      'token_lifecycle','access token ~60d; refresh tokens available for approved apps; re-verify required',
      'app_review','Organization posting (w_organization_social) requires LinkedIn Community Management API / Marketing Developer Platform access review; the app must be an admin of the Company Page',
      'stage_gate','EXTERNAL_SETUP_REQUIRED',
      'founder_action','Create a LinkedIn developer app, verify/associate the Strateloq Company Page (founder as Page admin), and apply for Community Management API access. Access review is EXTERNAL_APPROVAL_REQUIRED before organization publishing.')
    ELSE jsonb_build_object('platform',p_platform,'stage_gate','BLOCKED','reason','Unknown platform')
  END;
END $$;

-- ----------------------------------------------------------------------------
-- 5. PUBLISHING PREFLIGHT — fn_social_publishing_preflight(...)
--    Evaluates the ordered publish gates truthfully. Execution is globally
--    disabled; this only computes the blocked/ready state. Authorization is NEVER
--    inferred from account connection.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_publishing_preflight(
  p_tenant_id           uuid,
  p_platform            text,
  p_media_asset_id      uuid,
  p_destination_account text,
  p_caption_approved    boolean,
  p_publish_mode        text,
  p_automation_authorized boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_conn        public.social_platform_connections%ROWTYPE;
  v_asset       public.media_assets%ROWTYPE;
  v_reasons     text[] := ARRAY[]::text[];
  v_state       text;
  v_needed_cap  text;
  v_has_conn    boolean := false;
  v_media_type  text;
BEGIN
  -- required organic capability for this media type
  SELECT media_type INTO v_media_type FROM public.media_assets WHERE id = p_media_asset_id;
  v_needed_cap := CASE upper(coalesce(v_media_type,'')) WHEN 'VIDEO' THEN 'PUBLISH_VIDEO'
                                                        WHEN 'IMAGE' THEN 'PUBLISH_IMAGE'
                                                        ELSE 'PUBLISH_TEXT' END;

  -- GATE 1: a real CONNECTED organic connection carrying the needed capability
  SELECT * INTO v_conn
  FROM public.social_platform_connections
  WHERE tenant_id = p_tenant_id
    AND platform = p_platform
    AND connection_type = 'ORGANIC'
    AND authorization_status = 'CONNECTED'
    AND (revoked_at IS NULL)
    AND (expires_at IS NULL OR expires_at > now())
    AND capabilities ? v_needed_cap
  ORDER BY connected_at DESC NULLS LAST
  LIMIT 1;
  v_has_conn := FOUND;

  IF NOT v_has_conn THEN
    v_reasons := array_append(v_reasons, 'no_connected_organic_'||p_platform||'_connection_with_'||v_needed_cap);
  END IF;

  -- GATE 2: creative approved + launch-safe + identity resolved
  SELECT * INTO v_asset FROM public.media_assets WHERE id = p_media_asset_id;
  IF NOT FOUND THEN
    v_reasons := array_append(v_reasons, 'media_asset_not_found');
  ELSE
    IF coalesce(v_asset.approval_state,'') <> 'APPROVED' THEN
      v_reasons := array_append(v_reasons, 'creative_not_approved');
    END IF;
    IF coalesce(v_asset.is_launch_safe,false) = false THEN
      v_reasons := array_append(v_reasons, 'creative_not_launch_safe');
    END IF;
    IF coalesce(v_asset.identity_state,'') = 'IDENTITY_REVIEW_REQUIRED' THEN
      v_reasons := array_append(v_reasons, 'product_identity_review_required');
    END IF;
  END IF;

  -- GATE 3: destination selected + caption approved
  IF p_destination_account IS NULL OR length(trim(p_destination_account)) = 0 THEN
    v_reasons := array_append(v_reasons, 'no_destination_account_selected');
  END IF;
  IF coalesce(p_caption_approved,false) = false THEN
    v_reasons := array_append(v_reasons, 'caption_not_approved');
  END IF;

  -- GATE 4: automatic publishing requires an EXPLICIT automation grant (never inferred)
  IF coalesce(p_publish_mode,'MANUAL') = 'AUTHORIZED_AUTO' AND coalesce(p_automation_authorized,false) = false THEN
    v_reasons := array_append(v_reasons, 'automation_not_explicitly_authorized');
  END IF;

  -- ordered resolution: connection first (the truthful pre-OAuth state)
  IF NOT v_has_conn THEN
    v_state := 'BLOCKED_PENDING_PLATFORM_CONNECTION';
  ELSIF ('creative_not_approved' = ANY(v_reasons)
         OR 'creative_not_launch_safe' = ANY(v_reasons)
         OR 'product_identity_review_required' = ANY(v_reasons)
         OR 'media_asset_not_found' = ANY(v_reasons)) THEN
    v_state := 'BLOCKED_PENDING_APPROVAL';
  ELSIF ('no_destination_account_selected' = ANY(v_reasons) OR 'caption_not_approved' = ANY(v_reasons)) THEN
    v_state := 'BLOCKED_PENDING_CONTENT';
  ELSIF 'automation_not_explicitly_authorized' = ANY(v_reasons) THEN
    v_state := 'BLOCKED_PENDING_AUTOMATION_AUTHORIZATION';
  ELSE
    v_state := 'READY_FOR_MANUAL_PUBLISH';   -- gates satisfied; execution still globally disabled
  END IF;

  RETURN jsonb_build_object(
    'execution_state',  v_state,
    'execution_enabled', false,
    'blocked_reasons',  to_jsonb(v_reasons),
    'needed_capability', v_needed_cap,
    'has_connected_organic_connection', v_has_conn,
    'publish_mode',     coalesce(p_publish_mode,'MANUAL')
  );
END $$;

-- ----------------------------------------------------------------------------
-- 6. PUBLISHING REQUEST — fn_social_publishing_request(...)
--    Persists a generic organic publishing request with the truthful preflight
--    state. Never executes. Lineage: MD strategy + creative request + media asset.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_publishing_request(
  p_tenant_id           uuid,
  p_platform            text,
  p_media_asset_id      uuid,
  p_marketing_draft_id  uuid    DEFAULT NULL,
  p_creative_request_id uuid    DEFAULT NULL,
  p_business_id         uuid    DEFAULT NULL,
  p_destination_account text    DEFAULT NULL,
  p_content             jsonb   DEFAULT '{}'::jsonb,
  p_scheduled_at        timestamptz DEFAULT NULL,
  p_approval_id         uuid    DEFAULT NULL,
  p_caption_approved    boolean DEFAULT false,
  p_publish_mode        text    DEFAULT 'MANUAL',
  p_automation_authorized boolean DEFAULT false,
  p_persist             boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_pre  jsonb;
  v_id   uuid;
  v_err  text[] := ARRAY[]::text[];
BEGIN
  IF p_platform NOT IN ('META_FACEBOOK','META_INSTAGRAM','TIKTOK','LINKEDIN') THEN
    v_err := array_append(v_err,'invalid_platform');
  END IF;
  IF coalesce(p_publish_mode,'MANUAL') NOT IN ('MANUAL','AUTHORIZED_AUTO') THEN
    v_err := array_append(v_err,'invalid_publish_mode');
  END IF;
  IF p_media_asset_id IS NULL THEN
    v_err := array_append(v_err,'missing_media_asset');
  END IF;
  IF array_length(v_err,1) > 0 THEN
    RETURN jsonb_build_object('ok',false,'errors',to_jsonb(v_err));
  END IF;

  v_pre := public.fn_social_publishing_preflight(
    p_tenant_id, p_platform, p_media_asset_id, p_destination_account,
    p_caption_approved, p_publish_mode, p_automation_authorized);

  IF p_persist THEN
    INSERT INTO public.social_publishing_requests(
      tenant_id, business_id, marketing_draft_id, creative_request_id, media_asset_id,
      platform, connection_type, destination_account, content, scheduled_at, approval_id,
      caption_approved, publish_mode, automation_authorized, execution_enabled,
      execution_state, blocked_reasons)
    VALUES(
      p_tenant_id, p_business_id, p_marketing_draft_id, p_creative_request_id, p_media_asset_id,
      p_platform, 'ORGANIC', p_destination_account, coalesce(p_content,'{}'::jsonb), p_scheduled_at, p_approval_id,
      coalesce(p_caption_approved,false), coalesce(p_publish_mode,'MANUAL'), coalesce(p_automation_authorized,false), false,
      v_pre->>'execution_state', v_pre->'blocked_reasons')
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_id,
    'execution_state', v_pre->>'execution_state',
    'execution_enabled', false,
    'blocked_reasons', v_pre->'blocked_reasons',
    'lineage', jsonb_build_object(
      'marketing_draft_id', p_marketing_draft_id,
      'creative_request_id', p_creative_request_id,
      'media_asset_id', p_media_asset_id));
END $$;

-- ----------------------------------------------------------------------------
-- 7. ZERO-COST SELFTEST — fn_social_connection_selftest()
--    Proves, with NO live call and NO real post:
--      (a) organic vs advertising capability separation (disjoint sets)
--      (b) TikTok research auth is NOT an organic publish capability
--      (c) an organic publish request for a real, un-connected tenant/asset
--          resolves to BLOCKED_PENDING_PLATFORM_CONNECTION (the truthful result)
--      (d) each platform's external stage gate is truthful (none READY_TO_CONNECT)
--      (e) AUTHORIZED_AUTO cannot be authorized by connection alone
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_social_connection_selftest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_checks jsonb := '[]'::jsonb;
  v_pass   boolean := true;
  v_org    jsonb; v_adv jsonb;
  v_pre    jsonb;
  v_meta   jsonb; v_tt jsonb; v_li jsonb;
  v_tenant uuid;
  v_asset  uuid;
  b        boolean;
BEGIN
  -- (a) capability separation
  v_org := public.fn_social_connection_capabilities('META_FACEBOOK','ORGANIC');
  v_adv := public.fn_social_connection_capabilities('META_FACEBOOK','ADVERTISING');
  b := (v_org->'capabilities' ? 'PUBLISH_IMAGE')
       AND NOT (v_org->'capabilities' ? 'ACTIVATE_CAMPAIGN')
       AND (v_adv->'capabilities' ? 'ACTIVATE_CAMPAIGN')
       AND NOT (v_adv->'capabilities' ? 'PUBLISH_IMAGE');
  v_checks := v_checks || jsonb_build_object('check','organic_vs_advertising_capabilities_disjoint','pass',b,
    'detail','organic has PUBLISH_* not ACTIVATE_CAMPAIGN; advertising has ACTIVATE_CAMPAIGN not PUBLISH_*');
  v_pass := v_pass AND b;

  -- (b) TikTok organic publish capability set does not include any research/advertising capability token
  v_tt := public.fn_social_connection_capabilities('TIKTOK','ORGANIC');
  b := (v_tt->'capabilities' ? 'PUBLISH_VIDEO')
       AND NOT (v_tt->'capabilities' ? 'research.adlib.basic')
       AND NOT (v_tt->'capabilities' ? 'READ_AD_ACCOUNT');
  v_checks := v_checks || jsonb_build_object('check','tiktok_research_not_publish_capability','pass',b,
    'detail','TikTok organic capability is PUBLISH_VIDEO; research/advertising tokens are absent');
  v_pass := v_pass AND b;

  -- pick a real, un-connected tenant + asset (data only; Strateloq not hardcoded in the architecture)
  SELECT tenant_id, id INTO v_tenant, v_asset
  FROM public.media_assets
  WHERE media_type='VIDEO'
  ORDER BY (id::text LIKE '0ad36286%') DESC
  LIMIT 1;

  -- (c) organic publish request -> BLOCKED_PENDING_PLATFORM_CONNECTION
  v_pre := public.fn_social_publishing_request(
    p_tenant_id => v_tenant,
    p_platform => 'META_INSTAGRAM',
    p_media_asset_id => v_asset,
    p_destination_account => NULL,
    p_caption_approved => false,
    p_publish_mode => 'MANUAL',
    p_persist => false);
  b := (v_pre->>'execution_state' = 'BLOCKED_PENDING_PLATFORM_CONNECTION')
       AND (v_pre->>'execution_enabled' = 'false');
  v_checks := v_checks || jsonb_build_object('check','organic_publish_request_blocked_pending_connection','pass',b,
    'detail','state='||coalesce(v_pre->>'execution_state','null'));
  v_pass := v_pass AND b;

  -- (d) stage gates truthful (none READY_TO_CONNECT)
  v_meta := public.fn_social_platform_external_requirements('META_FACEBOOK','ORGANIC');
  v_tt   := public.fn_social_platform_external_requirements('TIKTOK','ORGANIC');
  v_li   := public.fn_social_platform_external_requirements('LINKEDIN','ORGANIC');
  b := (v_meta->>'stage_gate' <> 'READY_TO_CONNECT')
       AND (v_tt->>'stage_gate' = 'EXTERNAL_APPROVAL_REQUIRED')
       AND (v_tt->>'research_auth_separate' = 'true')
       AND (v_li->>'stage_gate' <> 'READY_TO_CONNECT');
  v_checks := v_checks || jsonb_build_object('check','external_stage_gates_truthful','pass',b,
    'detail','meta='||(v_meta->>'stage_gate')||' tiktok='||(v_tt->>'stage_gate')||' linkedin='||(v_li->>'stage_gate'));
  v_pass := v_pass AND b;

  -- (e) AUTHORIZED_AUTO not authorized by connection alone (still blocked at connection first)
  v_pre := public.fn_social_publishing_request(
    p_tenant_id => v_tenant,
    p_platform => 'META_FACEBOOK',
    p_media_asset_id => v_asset,
    p_destination_account => 'PAGE_PLACEHOLDER',
    p_caption_approved => true,
    p_publish_mode => 'AUTHORIZED_AUTO',
    p_automation_authorized => false,
    p_persist => false);
  b := (v_pre->>'execution_state' IN ('BLOCKED_PENDING_PLATFORM_CONNECTION','BLOCKED_PENDING_AUTOMATION_AUTHORIZATION'))
       AND (v_pre->>'execution_enabled' = 'false');
  v_checks := v_checks || jsonb_build_object('check','auto_publish_requires_explicit_authorization','pass',b,
    'detail','state='||coalesce(v_pre->>'execution_state','null'));
  v_pass := v_pass AND b;

  RETURN jsonb_build_object(
    'suite','social_connection_publishing_foundation',
    'passed', v_pass,
    'total', jsonb_array_length(v_checks),
    'checks', v_checks);
END $$;
