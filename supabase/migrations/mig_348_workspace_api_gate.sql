-- mig_348_workspace_api_gate.sql
-- Stage 3: comprehensive server-side API gate for the mandatory onboarding journey.
--
-- Rather than editing ~268 customer-facing workspace RPCs individually (high risk),
-- enforcement is centralised in a single PostgREST `db-pre-request` function that runs
-- before EVERY API request. When enforcement is armed, an authenticated member whose
-- onboarding is incomplete may call only an allowlist of onboarding / status / recovery
-- RPCs; every other RPC (Product Discovery, Recommendations, Saved products, My Store,
-- store/product actions, My Campaigns, Refresh Discovery, …) is refused at the API edge.
--
-- SAFE BY DEFAULT: the gate is a no-op while onboarding_policy.enforcement_active = FALSE,
-- and it is NOT wired to PostgREST by this migration. Wiring (ALTER ROLE authenticator …)
-- is part of the founder-approved arming procedure, done together with the frontend.
-- The gate fails OPEN on any unexpected error so it can never cause an API outage; tenant
-- RLS, country isolation and PAL remain independently enforced regardless.

-- Onboarding is "complete" (all member-performed steps done) when the access_state has
-- advanced past every REQUIRED step — i.e. the workspace is preparing or ready.
CREATE OR REPLACE FUNCTION public.fn_onboarding_complete(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT (public.fn_member_onboarding_state(p_auth_user_id) ->> 'access_state')
         IN ('WORKSPACE_PREPARING','READY');
$function$;
REVOKE ALL ON FUNCTION public.fn_onboarding_complete(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_onboarding_complete(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_onboarding_complete(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_onboarding_complete(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_block boolean := false;
  v_enf   boolean;
  v_role  text;
  v_uid   uuid;
  v_path  text;
  v_fname text;
  -- A not-yet-onboarded authenticated member may still reach these: onboarding steps,
  -- own status, notifications/recovery. Everything else is workspace data/actions.
  c_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'
  ];
BEGIN
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
    IF NOT coalesce(v_enf,false) THEN RETURN; END IF;             -- disarmed → no-op

    v_role := coalesce(
      nullif(current_setting('request.jwt.claim.role', true),''),
      (nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role'));
    IF v_role IS DISTINCT FROM 'authenticated' THEN RETURN; END IF;  -- never gate anon/service_role

    v_uid := auth.uid();
    IF v_uid IS NULL THEN RETURN; END IF;

    v_path := coalesce(current_setting('request.path', true), '');
    IF position('/rpc/' in v_path) = 0 THEN RETURN; END IF;       -- gate only RPC calls (tables → RLS)
    v_fname := regexp_replace(v_path, '^.*/rpc/', '');
    v_fname := regexp_replace(v_fname, '[?/].*$', '');

    IF v_fname = ANY (c_allow) THEN RETURN; END IF;               -- onboarding/status/recovery allowed
    IF public.fn_onboarding_complete(v_uid) THEN RETURN; END IF;  -- onboarded → allowed

    v_block := true;                                             -- incomplete onboarding → refuse
  EXCEPTION WHEN OTHERS THEN
    v_block := false;                                            -- fail OPEN (never outage)
  END;

  IF v_block THEN
    RAISE EXCEPTION 'onboarding_incomplete'
      USING ERRCODE = '42501',
            HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
  END IF;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_pre_request_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_pre_request_gate() TO authenticated, anon, service_role;

COMMENT ON FUNCTION public.fn_pre_request_gate() IS
  'PostgREST db-pre-request onboarding gate. No-op unless onboarding_policy.enforcement_active. '
  'Blocks non-allowlisted RPCs for authenticated members with incomplete onboarding. Fails open on '
  'error. Wire at arming time: ALTER ROLE authenticator SET pgrst.db_pre_request = ''public.fn_pre_request_gate''; NOTIFY pgrst, ''reload config'';';
