#!/bin/bash
# Seed SYNTHETIC users into the LOCAL stack only. No production data, no real emails.
set -euo pipefail
cd /tmp/sb-accept
API=http://127.0.0.1:54321
SRK=$(supabase status -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SERVICE_ROLE_KEY"])')
PW='Synth-Accept-2026!'

mkuser() { # email -> prints uuid
  curl -s -X POST "$API/auth/v1/admin/users" \
    -H "apikey: $SRK" -H "Authorization: Bearer $SRK" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\",\"email_confirm\":true}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d)'
}

U1=$(mkuser incomplete@synthetic.test)   # stays incomplete
U2=$(mkuser journey@synthetic.test)      # completes onboarding over HTTP during tests
U3=$(mkuser completeb@synthetic.test)    # pre-seeded complete; other tenant
echo "U1=$U1" ; echo "U2=$U2" ; echo "U3=$U3"
printf '%s\n' "U1=$U1" "U2=$U2" "U3=$U3" > /tmp/sb-accept/setup/users.env

docker exec -i supabase_db_sb-accept psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL
-- members (email_verified true; entitlement COMP active for all three)
INSERT INTO public.member (auth_user_id, email, display_name, email_verified)
VALUES ('$U1','incomplete@synthetic.test','Synth Incomplete',true),
       ('$U2','journey@synthetic.test','Synth Journey',true),
       ('$U3','completeb@synthetic.test','Synth CompleteB',true)
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.discovery_state (member_id, status, analysis_status)
SELECT m.id, 'not_started', 'not_started' FROM public.member m
WHERE m.auth_user_id IN ('$U1','$U2') AND NOT EXISTS (SELECT 1 FROM public.discovery_state d WHERE d.member_id=m.id);
INSERT INTO public.discovery_state (member_id, status, analysis_status)
SELECT m.id, 'complete', 'ready' FROM public.member m
WHERE m.auth_user_id = '$U3' AND NOT EXISTS (SELECT 1 FROM public.discovery_state d WHERE d.member_id=m.id);

INSERT INTO public.account_entitlement (auth_user_id, member_id, plan_code, status, source, granted_by, notes)
SELECT m.auth_user_id, m.id, 'ecommerce_monthly', 'COMP', 'COMP', 'local-acceptance', 'synthetic'
FROM public.member m WHERE m.auth_user_id IN ('$U1','$U2','$U3')
ON CONFLICT (auth_user_id) DO NOTHING;

-- U3 pre-completed: app+business profile, billing completed, membership confirmed
WITH app AS (
  INSERT INTO public.founding_applications (first_name,last_name,work_email,status,source)
  VALUES ('Synth','CompleteB','completeb@synthetic.test','accepted','direct_invite_backfill') RETURNING id
), bp AS (
  INSERT INTO public.business_profiles (application_id, user_id, business_name, industry, target_audience, primary_goal, business_summary)
  SELECT id, '$U3', 'Synth B GmbH', 'ecommerce', 'tests', 'testing', 'synthetic' FROM app RETURNING application_id
)
UPDATE public.member SET application_ref=(SELECT application_id FROM bp), membership_confirmed_at=now()
WHERE auth_user_id='$U3';

INSERT INTO public.billing_profile (auth_user_id, member_id, legal_name, billing_email, country, completed_at)
SELECT '$U3', m.id, 'Synth B GmbH', 'completeb@synthetic.test', 'DE', now()
FROM public.member m WHERE m.auth_user_id='$U3'
ON CONFLICT (auth_user_id) DO NOTHING;

-- U3-owned PRIVATE workspace row (cross-tenant target)
INSERT INTO public.commerce_products (user_id, product_name, visibility)
VALUES ('$U3', 'SYNTH PRIVATE PRODUCT B', 'PRIVATE');

-- a notification for U1 (allowed-RPC check)
INSERT INTO public.pulse_notifications (user_id, kind, title) VALUES ('$U1','info','synthetic hello');
SQL
echo SEED_OK
