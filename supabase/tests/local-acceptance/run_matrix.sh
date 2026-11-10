#!/bin/bash
# Real-HTTP enforcement acceptance matrix against the LOCAL stack (127.0.0.1:54321).
# Synthetic users only. Production untouched.
set -uo pipefail
cd /tmp/sb-accept
API=http://127.0.0.1:54321
S=$(supabase status -o json 2>/dev/null)
ANON=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ANON_KEY"])')
SRK=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SERVICE_ROLE_KEY"])')
JWTSECRET=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["JWT_SECRET"])')
PW='Synth-Accept-2026!'
. /tmp/sb-accept/setup/users.env

tok() { # email -> access_token
  curl -s -X POST "$API/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}

PASS=0; FAIL=0; declare -a RESULTS
check() { # id desc expected actual [body-fragment-required] [body]
  local id="$1" desc="$2" exp="$3" act="$4" frag="${5:-}" body="${6:-}"
  local ok="PASS"
  [ "$act" = "$exp" ] || ok="FAIL"
  if [ -n "$frag" ] && ! grep -q "$frag" <<<"$body"; then ok="FAIL"; fi
  [ "$ok" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  RESULTS+=("$ok | $id | $desc | expected=$exp got=$act")
  echo "$ok | $id | $desc | expected=$exp got=$act"
}

req() { # method url token data -> sets RC and BODY
  local m="$1" u="$2" t="$3" d="${4:-}"
  local args=(-s -w '\n%{http_code}' -X "$m" "$u" -H "apikey: $ANON" -H "Content-Type: application/json")
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$d" ] && args+=(-d "$d")
  local out; out=$(curl "${args[@]}")
  RC=$(tail -1 <<<"$out"); BODY=$(sed '$d' <<<"$out")
}

T1=$(tok incomplete@synthetic.test); T2=$(tok journey@synthetic.test); T3=$(tok completeb@synthetic.test)
[ -n "$T1" ] && [ -n "$T2" ] && [ -n "$T3" ] || { echo "TOKEN FAILURE"; exit 1; }

echo "=== phase 0: wired but enforcement OFF (production-parity no-op) ==="
req POST "$API/rest/v1/rpc/fn_product_explorer" "$T1" '{"p_page":1}'
check P0.1 "OFF: incomplete member reaches protected RPC (no-op gate)" 200 "$RC" standin "$BODY"
req GET "$API/rest/v1/commerce_products?select=product_name,visibility" "$T1"
check P0.2 "OFF: incomplete member direct table read allowed (RLS only)" 200 "$RC" GLOBAL_SAFE "$BODY"

echo "=== arming enforcement LOCALLY ==="
docker exec supabase_db_sb-accept psql -U postgres -d postgres -q -c "UPDATE public.onboarding_policy SET enforcement_active=true, updated_by='local-acceptance' WHERE id;"

echo "=== phase 1: incomplete member denied (RPC + direct tables) ==="
req POST "$API/rest/v1/rpc/fn_product_explorer" "$T1" '{"p_page":1}'
check A1 "incomplete: protected workspace RPC denied" 403 "$RC" onboarding_incomplete "$BODY"
req GET "$API/rest/v1/commerce_products?select=product_name" "$T1"
check A2 "incomplete: direct workspace table denied (mig_351)" 403 "$RC" onboarding_incomplete "$BODY"
req POST "$API/rest/v1/commerce_products" "$T1" '{"user_id":"'$U1'","product_name":"x"}'
check A3 "incomplete: direct table INSERT denied" 403 "$RC" onboarding_incomplete "$BODY"
req GET "$API/rest/v1/rpc/fn_product_explorer" "$T1"
check A4 "incomplete: protected RPC via GET denied" 403 "$RC" onboarding_incomplete "$BODY"
req GET "$API/rest/v1/nonexistent_workspace_table?select=*" "$T1"
check A5 "incomplete: nonexistent relation -> 404 pre-transaction (no data; existing tables are gated per A2)" 404 "$RC" "" "$BODY"

echo "=== phase 2: onboarding/status/recovery resources reachable while incomplete ==="
req POST "$API/rest/v1/rpc/fn_workspace_access" "$T1" '{}'
check B1 "incomplete: fn_workspace_access reachable" 200 "$RC" BUSINESS_PROFILE_REQUIRED "$BODY"
req POST "$API/rest/v1/rpc/fn_entitlement_status" "$T1" '{}'
check B2 "incomplete: fn_entitlement_status reachable" 200 "$RC" COMP "$BODY"
req POST "$API/rest/v1/rpc/get_own_billing_profile" "$T1" '{}'
check B3 "incomplete: get_own_billing_profile reachable" 200 "$RC" '"completed"' "$BODY"
req POST "$API/rest/v1/rpc/get_own_notifications" "$T1" '{}'
check B4 "incomplete: get_own_notifications reachable" 200 "$RC" 'synthetic hello' "$BODY"
req GET "$API/rest/v1/member?select=email" "$T1"
check B5 "incomplete: own-identity table (member) readable via allowlist+RLS" 200 "$RC" 'incomplete@synthetic.test' "$BODY"

echo "=== phase 3: full onboarding journey over HTTP (journey user) ==="
req POST "$API/rest/v1/rpc/fn_ensure_member_business_profile" "$T2" '{}'
check C1 "journey: business profile backfill RPC ok" 200 "$RC" backfilled "$BODY"
req POST "$API/rest/v1/rpc/save_business_profile" "$T2" '{"p_content":{"business_name":"Synth J Ltd","industry":"ecommerce","target_audience":"synthetic buyers","primary_goal":"testing","business_summary":"synthetic acceptance","businessDiscovery":{"schemaVersion":1,"productsOrServices":["widgets"],"customerPainPoints":["time"],"desiredOutcomes":["sales"]}},"p_complete":true}'
check C2 "journey: save_business_profile complete=true" 200 "$RC" '"saved"' "$BODY"
req POST "$API/rest/v1/rpc/fn_product_explorer" "$T2" '{"p_page":1}'
check C3 "journey: still denied after business profile only" 403 "$RC" onboarding_incomplete "$BODY"
req POST "$API/rest/v1/rpc/save_billing_profile" "$T2" '{"p_content":{"legal_name":"Synth J Ltd","billing_email":"journey@synthetic.test","country":"DE"},"p_complete":true}'
check C4 "journey: save_billing_profile complete=true (COMP, amount 0)" 200 "$RC" '"amount_minor" : 0\|"amount_minor": 0\|"amount_minor":0' "$BODY"
req POST "$API/rest/v1/rpc/save_billing_profile" "$T2" '{"p_content":{"card_number":"4111111111111111"},"p_complete":false}'
check C5 "journey: card data REJECTED by billing RPC" 200 "$RC" payment_credentials_not_accepted "$BODY"
req POST "$API/rest/v1/rpc/confirm_membership" "$T2" '{}'
check C6 "journey: confirm_membership ok" 200 "$RC" confirmed "$BODY"
req POST "$API/rest/v1/rpc/fn_product_explorer" "$T2" '{"p_page":1}'
check C7 "journey: workspace RPC allowed after completing onboarding" 200 "$RC" standin "$BODY"
req GET "$API/rest/v1/commerce_products?select=product_name,visibility" "$T2"
check C8 "journey: direct table read allowed after onboarding (RLS applies)" 200 "$RC" GLOBAL_SAFE "$BODY"

echo "=== phase 4: completed member, cross-tenant, service role ==="
req POST "$API/rest/v1/rpc/fn_product_explorer" "$T3" '{"p_page":1}'
check D1 "pre-completed member: workspace RPC allowed" 200 "$RC" standin "$BODY"
req GET "$API/rest/v1/commerce_products?user_id=eq.$U3&select=product_name" "$T2"
check D2 "cross-tenant: completed member CANNOT read other tenant's private row" 200 "$RC" '^\[\]$' "$BODY"
req GET "$API/rest/v1/commerce_products?user_id=eq.$U3&select=product_name" "$T3"
check D3 "owner: tenant B reads own private row" 200 "$RC" 'SYNTH PRIVATE PRODUCT B' "$BODY"
RC=$(curl -s -o /tmp/d4.json -w '%{http_code}' "$API/rest/v1/commerce_products?select=product_name" -H "apikey: $ANON" -H "Authorization: Bearer $SRK"); BODY=$(cat /tmp/d4.json)
check D4 "service_role: full table read (operational jobs unaffected)" 200 "$RC" 'SYNTH PRIVATE PRODUCT B' "$BODY"
RC=$(curl -s -o /tmp/d5.json -w '%{http_code}' -X POST "$API/rest/v1/rpc/fn_member_onboarding_state" -H "apikey: $ANON" -H "Authorization: Bearer $SRK" -H "Content-Type: application/json" -d "{\"p_auth_user_id\":\"$U1\"}"); BODY=$(cat /tmp/d5.json)
check D5 "service_role: service-only RPC callable" 200 "$RC" BUSINESS_PROFILE_REQUIRED "$BODY"

echo "=== phase 5: anonymous + malformed auth fail closed ==="
req GET "$API/rest/v1/commerce_products?select=product_name" ""
check E1 "anon key only: table read returns NO rows (RLS) " 200 "$RC" '^\[\]$' "$BODY"
req POST "$API/rest/v1/rpc/fn_product_explorer" "" '{}'
check E2 "anon key only: protected RPC denied (no EXECUTE grant; PostgREST 401 for anon)" 401 "$RC" '' "$BODY"
req POST "$API/rest/v1/rpc/fn_member_onboarding_state" "$T1" "{\"p_auth_user_id\":\"$U3\"}"
check E3 "authenticated user CANNOT call service-only state RPC (no EXECUTE grant)" 403 "$RC" '' "$BODY"
RC=$(curl -s -o /tmp/e4.json -w '%{http_code}' "$API/rest/v1/commerce_products" -H "apikey: $ANON" -H "Authorization: Bearer garbage.token.here"); BODY=$(cat /tmp/e4.json)
check E4 "malformed JWT: rejected" 401 "$RC" '' "$BODY"
# JWT signed with the local secret but with NO role claim -> unknown role must fail closed
NOROLE=$(python3 - "$JWTSECRET" <<'EOF'
import hmac, hashlib, base64, json, sys, time
sec=sys.argv[1].encode()
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b'=')
h=b64(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
p=b64(json.dumps({"sub":"387360ad-4124-4bc8-ba2f-90dbbf799fd1","aud":"authenticated","exp":int(time.time())+3600}).encode())
sig=b64(hmac.new(sec, h+b'.'+p, hashlib.sha256).digest())
print((h+b'.'+p+b'.'+sig).decode())
EOF
)
RC=$(curl -s -o /tmp/e5.json -w '%{http_code}' -X POST "$API/rest/v1/rpc/fn_product_explorer" -H "apikey: $ANON" -H "Authorization: Bearer $NOROLE" -H "Content-Type: application/json" -d '{}'); BODY=$(cat /tmp/e5.json)
check E5 "valid-signature JWT with NO role claim: denied upstream (fail closed)" 401 "$RC" '' "$BODY"

echo "=== phase 6: alternate-endpoint / evasion attempts (incomplete member) ==="
req GET "$API/rest/v1/COMMERCE_PRODUCTS?select=*" "$T1"
check F1 "case-variant path = distinct nonexistent relation -> 404 (no data path)" 404 "$RC" "" "$BODY"
req GET "$API/rest/v1/commerce_products?select=product_name&limit=1" "$T1"
check F2 "query-string variation: denied" 403 "$RC" onboarding_incomplete "$BODY"
RC=$(curl -s -o /tmp/f3.json -w '%{http_code}' -I -X HEAD "$API/rest/v1/commerce_products" -H "apikey: $ANON" -H "Authorization: Bearer $T1"); BODY=""
check F3 "HEAD request: denied" 403 "$RC" '' ""
req GET "$API/graphql/v1" "$T1"
GQL_NOTE="$RC"
echo "note: graphql endpoint status for incomplete member = $GQL_NOTE (404 = not exposed locally)"
req POST "$API/rest/v1/rpc/save_business_profile/../fn_product_explorer" "$T1" '{}'
check F4 "path traversal attempt on rpc: not allowed" 403 "$RC" '' "$BODY"

echo ""
echo "=== SUMMARY: PASS=$PASS FAIL=$FAIL ==="
printf '%s\n' "${RESULTS[@]}" > /tmp/sb-accept/setup/matrix_results.txt
