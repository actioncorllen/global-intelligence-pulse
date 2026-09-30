-- mig_343: Founding-member registration access control — verify + harden.
--
-- VERIFIED existing enforcement (unchanged, reused):
--   * member/workspace provisioning happens ONLY in accept_invitation (SECURITY DEFINER):
--     requires a valid, ISSUED, unexpired, single-use invitation whose bound_email equals the
--     caller's CONFIRMED auth email; consumes the invitation (no reuse). No RLS INSERT policy on
--     member/invitation/discovery_state → no self-provisioning.
--   * issue_invitation / issue_open_invitation / accept_invitation / validate_invitation are
--     EXECUTE-granted ONLY to postgres + service_role (NOT anon/authenticated) → no direct-RPC
--     bypass. The issuance edge functions additionally gate the caller against a server-held
--     founder allowlist (FOUNDER_ISSUER_AUTH_USER_IDS) with origin allowlisting.
--   * accept-invitation edge derives auth identity + email-verified strictly from a verified
--     auth.getUser(bearer) — never from client-supplied fields.
--
-- FIXES in this migration (backend enforcement + least privilege; no auth method disabled):
--   1. Safe public application intake: fn_submit_founding_application (anon-executable,
--      SECURITY DEFINER) writes ONLY a founding_applications row (status 'new'); it creates NO
--      auth account, NO member, NO workspace, NO invitation. Direct anon INSERT stays RLS-blocked;
--      this is the single controlled intake path (item 1 & 7).
--   2. Least-privilege: revoke over-broad anon/authenticated INSERT/UPDATE/DELETE/TRUNCATE on the
--      auth-critical tables. These were RLS-blocked for API writes already; revoking makes intent
--      explicit and closes TRUNCATE (which is NOT governed by RLS). No legitimate flow uses them
--      (all writes go through SECURITY DEFINER functions / service role).

-- 1) Controlled public application intake (no account, no workspace, no invitation).
CREATE OR REPLACE FUNCTION public.fn_submit_founding_application(
  p_work_email text,
  p_first_name text DEFAULT NULL,
  p_last_name text DEFAULT NULL,
  p_company text DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_industry text DEFAULT NULL,
  p_role text DEFAULT NULL,
  p_company_size text DEFAULT NULL,
  p_primary_goal text DEFAULT NULL,
  p_use_case text DEFAULT NULL,
  p_current_workflow text DEFAULT NULL,
  p_source text DEFAULT 'pulse-website')
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_email text := lower(btrim(coalesce(p_work_email,'')));
  v_existing public.founding_applications%rowtype;
  v_src text := left(coalesce(nullif(btrim(p_source),''),'pulse-website'), 40);
BEGIN
  -- Validate WITHOUT creating any account. Neutral responses (no account enumeration).
  IF v_email = '' OR length(v_email) > 254
     OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_email');
  END IF;
  IF coalesce(btrim(p_first_name),'') = '' OR coalesce(btrim(p_last_name),'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'missing_name');
  END IF;

  -- One application row per email: refresh a still-pending application, never duplicate, and
  -- never overwrite one already accepted/rejected (those are lifecycle-owned by review/issuance).
  SELECT * INTO v_existing FROM public.founding_applications
    WHERE lower(btrim(work_email)) = v_email
    ORDER BY created_at DESC LIMIT 1;

  IF FOUND AND lower(coalesce(v_existing.status,'')) IN ('accepted','rejected') THEN
    -- Already decided; acknowledge without changing state or leaking which.
    RETURN jsonb_build_object('ok', true, 'status', 'received');
  ELSIF FOUND THEN
    UPDATE public.founding_applications SET
      first_name = coalesce(nullif(btrim(p_first_name),''), first_name),
      last_name  = coalesce(nullif(btrim(p_last_name),''), last_name),
      company    = coalesce(nullif(btrim(p_company),''), company),
      country    = coalesce(nullif(btrim(p_country),''), country),
      industry   = coalesce(nullif(btrim(p_industry),''), industry),
      role       = coalesce(nullif(btrim(p_role),''), role),
      company_size = coalesce(nullif(btrim(p_company_size),''), company_size),
      primary_goal = coalesce(nullif(btrim(p_primary_goal),''), primary_goal),
      use_case     = coalesce(nullif(btrim(p_use_case),''), use_case),
      current_workflow = coalesce(nullif(btrim(p_current_workflow),''), current_workflow),
      updated_at = now()
    WHERE id = v_existing.id;
  ELSE
    INSERT INTO public.founding_applications
      (first_name,last_name,work_email,company,country,industry,role,company_size,
       primary_goal,use_case,current_workflow,status,source)
    VALUES (nullif(btrim(p_first_name),''), nullif(btrim(p_last_name),''), v_email,
       nullif(btrim(p_company),''), nullif(btrim(p_country),''), nullif(btrim(p_industry),''),
       nullif(btrim(p_role),''), nullif(btrim(p_company_size),''), nullif(btrim(p_primary_goal),''),
       nullif(btrim(p_use_case),''), nullif(btrim(p_current_workflow),''), 'new', v_src);
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', 'received',
    'note', 'Application received for review. No account or workspace is created by applying.');
END; $function$;

COMMENT ON FUNCTION public.fn_submit_founding_application(text,text,text,text,text,text,text,text,text,text,text,text) IS
  'Public founding-member application intake. Writes only a founding_applications row (status new). Creates NO account, member, workspace or invitation. mig_343.';

-- anon/authenticated may submit an application; nothing else.
REVOKE ALL ON FUNCTION public.fn_submit_founding_application(text,text,text,text,text,text,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_submit_founding_application(text,text,text,text,text,text,text,text,text,text,text,text) TO anon, authenticated;

-- 2) Least-privilege: remove over-broad direct-write/TRUNCATE grants on auth-critical tables.
--    (All were RLS-blocked for API writes; TRUNCATE is NOT RLS-governed. Legitimate access is via
--     SECURITY DEFINER functions / service role, which are unaffected.)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.founding_applications FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.users               FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.business_profiles   FROM anon, authenticated;
REVOKE SELECT ON public.founding_applications FROM anon, authenticated;  -- lookup is founder/service-role only

-- 3) Access-control selftest (read-only outcome; all writes run in rolled-back subtransactions).
CREATE OR REPLACE FUNCTION public.fn_founding_access_control_selftest(p_no_member_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_email text;
  v_tok text;
  r1 jsonb; r2 jsonb; rexp jsonb; rrev jsonb; rcons jsonb; rwrong jsonb; rbad jsonb; rapp jsonb;
  v_app_email text := 'access_ctrl_probe_'||substr(md5(random()::text),1,8)||'@example.com';
  v_app_exists boolean; v_member_for_app boolean;
BEGIN
  SELECT lower(btrim(email)) INTO v_email FROM auth.users WHERE id = p_no_member_uid;

  -- A: approved + valid issued invite activates; second call is idempotent (already_provisioned)
  BEGIN
    v_tok := md5(random()::text)||md5(random()::text);
    INSERT INTO public.invitation (token_hash, bound_email, application_ref, issued_at, expires_at, status)
      VALUES (v_tok, v_email, NULL, now(), now() + interval '7 days', 'issued');
    r1 := public.accept_invitation(v_tok, p_no_member_uid, true);
    r2 := public.accept_invitation(v_tok, p_no_member_uid, true);
    RAISE EXCEPTION 'RB_A';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_A' THEN r1 := jsonb_build_object('status','ERR','e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','approved_valid_activates','pass', (r1->>'status')='accepted', 'observed', r1->>'status');
  v := v || jsonb_build_object('case','returning_member_idempotent','pass', (r2->>'status')='accepted' AND (r2->>'provisioning')='already_provisioned', 'observed', r2->>'provisioning');

  -- B: expired invite rejected
  BEGIN
    v_tok := md5(random()::text)||md5(random()::text);
    INSERT INTO public.invitation (token_hash, bound_email, issued_at, expires_at, status)
      VALUES (v_tok, v_email, now() - interval '10 days', now() - interval '1 hour', 'issued');
    rexp := public.accept_invitation(v_tok, p_no_member_uid, true);
    RAISE EXCEPTION 'RB_B';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_B' THEN rexp := jsonb_build_object('status','ERR','e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','expired_invite_rejected','pass', (rexp->>'status')='invalid_invitation' AND (rexp->>'reason')='expired', 'observed', rexp);

  -- C: revoked invite rejected
  BEGIN
    v_tok := md5(random()::text)||md5(random()::text);
    INSERT INTO public.invitation (token_hash, bound_email, issued_at, expires_at, status)
      VALUES (v_tok, v_email, now(), now() + interval '7 days', 'revoked');
    rrev := public.accept_invitation(v_tok, p_no_member_uid, true);
    RAISE EXCEPTION 'RB_C';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_C' THEN rrev := jsonb_build_object('status','ERR','e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','revoked_invite_rejected','pass', (rrev->>'status')='invalid_invitation' AND (rrev->>'reason')='revoked', 'observed', rrev);

  -- D: reused/consumed invite for a user with no member -> integrity conflict (no provisioning)
  BEGIN
    v_tok := md5(random()::text)||md5(random()::text);
    INSERT INTO public.invitation (token_hash, bound_email, issued_at, expires_at, status, consumed_at)
      VALUES (v_tok, v_email, now(), now() + interval '7 days', 'consumed', now());
    rcons := public.accept_invitation(v_tok, p_no_member_uid, true);
    RAISE EXCEPTION 'RB_D';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_D' THEN rcons := jsonb_build_object('status','ERR','e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','consumed_reuse_no_provision','pass', (rcons->>'status')='integrity_conflict', 'observed', rcons);

  -- E: invite bound to a different email -> authentication_failed (cannot use someone else's invite)
  BEGIN
    v_tok := md5(random()::text)||md5(random()::text);
    INSERT INTO public.invitation (token_hash, bound_email, issued_at, expires_at, status)
      VALUES (v_tok, 'not-'||v_email, now(), now() + interval '7 days', 'issued');
    rwrong := public.accept_invitation(v_tok, p_no_member_uid, true);
    RAISE EXCEPTION 'RB_E';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_E' THEN rwrong := jsonb_build_object('status','ERR','e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','wrong_email_rejected','pass', (rwrong->>'status')='authentication_failed', 'observed', rwrong);

  -- F: malformed token -> not_found
  rbad := public.accept_invitation('zzz', p_no_member_uid, true);
  v := v || jsonb_build_object('case','bad_token_rejected','pass', (rbad->>'status')='invalid_invitation' AND (rbad->>'reason')='not_found', 'observed', rbad);

  -- G: application intake creates an application but NO account/member
  BEGIN
    rapp := public.fn_submit_founding_application(v_app_email, 'Probe', 'Applicant');
    SELECT EXISTS(SELECT 1 FROM public.founding_applications WHERE lower(btrim(work_email))=v_app_email AND status='new') INTO v_app_exists;
    SELECT EXISTS(SELECT 1 FROM public.member WHERE lower(btrim(email))=v_app_email)
        OR EXISTS(SELECT 1 FROM auth.users WHERE lower(btrim(email))=v_app_email) INTO v_member_for_app;
    RAISE EXCEPTION 'RB_G';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB_G' THEN rapp := jsonb_build_object('ok',false,'e',SQLERRM); END IF; END;
  v := v || jsonb_build_object('case','application_intake_no_account','pass',
    coalesce((rapp->>'ok')::boolean,false) AND v_app_exists AND NOT v_member_for_app, 'observed', rapp);

  -- H: no permissive INSERT/ALL policy for anon/authenticated on the gated tables (RLS default-deny)
  DECLARE v_bad_pol int; BEGIN
    SELECT count(*) INTO v_bad_pol FROM pg_policies
     WHERE schemaname='public' AND tablename IN ('member','invitation','discovery_state','founding_applications')
       AND cmd IN ('INSERT','ALL')
       AND (roles::text ILIKE '%anon%' OR roles::text ILIKE '%authenticated%');
    v := v || jsonb_build_object('case','no_self_provision_write_policy','pass', v_bad_pol = 0, 'observed', v_bad_pol);
  END;

  -- I/J: direct RPC to issuance/acceptance denied to anon + authenticated
  v := v || jsonb_build_object('case','issue_invitation_not_anon','pass',
    NOT has_function_privilege('anon','public.issue_invitation(uuid,text,text)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.issue_invitation(uuid,text,text)','EXECUTE'));
  v := v || jsonb_build_object('case','accept_invitation_not_anon','pass',
    NOT has_function_privilege('anon','public.accept_invitation(text,uuid,boolean)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.accept_invitation(text,uuid,boolean)','EXECUTE'));

  -- K: least-privilege revokes applied (no anon/authenticated INSERT/UPDATE/DELETE/TRUNCATE)
  DECLARE v_leftover int; BEGIN
    SELECT count(*) INTO v_leftover FROM information_schema.role_table_grants
     WHERE table_schema='public' AND table_name IN ('founding_applications','users','business_profiles')
       AND grantee IN ('anon','authenticated')
       AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
    v := v || jsonb_build_object('case','overbroad_grants_revoked','pass', v_leftover = 0, 'observed', v_leftover);
  END;

  RETURN jsonb_build_object('suite','founding_registration_access_control',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
