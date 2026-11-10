#!/bin/bash
# A/B edge-function battery against the LOCAL stack. A = deployed original
# (marker-stripped), B = patched (repo). Phase OFF proves preservation (A==B
# except the documented meta-insights-reader auth closure); phase ON proves
# enforcement (B denies incomplete; A shows the old bypass).
set -uo pipefail
cd /tmp/sb-accept
API=http://127.0.0.1:54321
S=$(supabase status -o json 2>/dev/null)
ANON=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ANON_KEY"])')
SRK=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SERVICE_ROLE_KEY"])')
PW='Synth-Accept-2026!'
. /tmp/sb-accept/setup/users.env
OUT=/tmp/sb-accept/edge-ab/out; mkdir -p "$OUT"

tok() { curl -s -X POST "$API/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'; }
TU1=$(tok incomplete@synthetic.test); TU3=$(tok completeb@synthetic.test)
[ -n "$TU1" ] && [ -n "$TU3" ] || { echo TOKEN_FAIL; exit 1; }

PNG1='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

start_fn() { # variant fn -> starts deno on :8000, waits
  local v="$1" fn="$2"
  ( cd /tmp/sb-accept/edge-ab/$v/$fn && \
    SUPABASE_URL="$API" SUPABASE_ANON_KEY="$ANON" SUPABASE_SERVICE_ROLE_KEY="$SRK" \
    ISSUANCE_ALLOWED_ORIGINS="http://test.local" \
    N8N_PREPARE_WEBHOOK="http://127.0.0.1:9797/x" N8N_TRANSLATE_WEBHOOK="http://127.0.0.1:9797/x" \
    N8N_GEMINI_EXECUTOR_WEBHOOK="http://127.0.0.1:9797/x" N8N_GEMINI_VALIDATOR_WEBHOOK="http://127.0.0.1:9797/x" \
    HTTPS_PROXY="${HTTPS_PROXY:-}" DENO_CERT=/root/.ccr/ca-bundle.crt DENO_NO_UPDATE_CHECK=1 \
    deno run --quiet --allow-net --allow-env --allow-read index.ts > /tmp/sb-accept/edge-ab/deno_${v}_${fn}.log 2>&1 & echo $! > /tmp/sb-accept/edge-ab/pid )
  for i in $(seq 1 60); do curl -s -o /dev/null -m 1 http://127.0.0.1:8000/ 2>/dev/null && break; sleep 0.5; done
}
stop_fn() { kill "$(cat /tmp/sb-accept/edge-ab/pid 2>/dev/null)" 2>/dev/null; sleep 0.5; pkill -f "deno run" 2>/dev/null; sleep 0.5; }

req() { # name method token origin data  -> writes "$OUT/$PHASE.$VARIANT.$FN.$name"
  local name="$1" m="$2" t="$3" o="$4" d="$5"
  local args=(-s -m 20 -w '\nHTTP=%{http_code}' -X "$m" http://127.0.0.1:8000/ -H "Content-Type: application/json")
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$o" ] && args+=(-H "Origin: $o")
  [ -n "$d" ] && args+=(-d "$d")
  curl "${args[@]}" > "$OUT/$PHASE.$VARIANT.$FN.$name" 2>&1
}

battery() { # per-function request set
  case "$FN" in
    prepare-product)
      req u1 POST "$TU1" "http://test.local" '{"acquisition_id":"11111111-2222-3333-4444-555555555555"}'
      req u3 POST "$TU3" "http://test.local" '{"acquisition_id":"11111111-2222-3333-4444-555555555555"}'
      req noauth POST "" "http://test.local" '{}'
      req badorigin POST "$TU1" "http://evil.local" '{}'
      ;;
    translate-text)
      req u1 POST "$TU1" "" '{"target_lang":"de","texts":["hello world"]}'
      req u3 POST "$TU3" "" '{"target_lang":"de","texts":["hello world"]}'
      req anonkey POST "$ANON" "" '{"target_lang":"de","texts":["x"]}'
      req noauth POST "" "" '{"target_lang":"de","texts":["x"]}'
      ;;
    product-image-import)
      req u1 POST "$TU1" "" "{\"product_id\":\"11111111-2222-3333-4444-555555555555\",\"mime\":\"image/png\",\"rights_confirmed\":true,\"data_base64\":\"$PNG1\"}"
      req u3 POST "$TU3" "" "{\"product_id\":\"11111111-2222-3333-4444-555555555555\",\"mime\":\"image/png\",\"rights_confirmed\":true,\"data_base64\":\"$PNG1\"}"
      req noauth POST "" "" '{}'
      ;;
    commercial-image-generate)
      req u1_crosstenant POST "$TU1" "" "{\"product_id\":\"$PRODUCT_B\"}"
      req u3_own POST "$TU3" "" "{\"product_id\":\"$PRODUCT_B\"}"
      req badproduct POST "$TU3" "" '{"product_id":"nope"}'
      req noauth POST "" "" '{}'
      ;;
    meta-insights-reader)
      req u1 POST "$TU1" "" '{"object_id":"123"}'
      req u3 POST "$TU3" "" '{"object_id":"123"}'
      req service POST "$SRK" "" '{"object_id":"123"}'
      req anonkey POST "$ANON" "" '{"object_id":"123"}'
      req noauth POST "" "" '{"object_id":"123"}'
      ;;
  esac
}

PRODUCT_B=$(docker exec supabase_db_sb-accept psql -U postgres -d postgres -At -c "SELECT id FROM public.commerce_products WHERE product_name='SYNTH PRIVATE PRODUCT B' LIMIT 1;")
FNS="prepare-product translate-text product-image-import commercial-image-generate meta-insights-reader"

set_enf() { docker exec supabase_db_sb-accept psql -U postgres -d postgres -q -c "UPDATE public.onboarding_policy SET enforcement_active=$1 WHERE id;"; }

echo "=== PHASE OFF: A and B (preservation) ==="
set_enf false
for FN in $FNS; do for VARIANT in A B; do PHASE=OFF; start_fn $VARIANT $FN; battery; stop_fn; done; done

echo "=== PHASE ON: B (enforcement) + A (documents old bypass) ==="
set_enf true
for FN in $FNS; do for VARIANT in B A; do PHASE=ON; start_fn $VARIANT $FN; battery; stop_fn; done; done
set_enf false

echo "=== OFF preservation diff (A vs B) ==="
PRESERVE_FAIL=0
for FN in $FNS; do
  for f in "$OUT"/OFF.A.$FN.*; do
    n=$(basename "$f"); bn="$OUT/OFF.B.$FN.${n##*.}"
    if diff -q "$f" "$bn" >/dev/null 2>&1; then echo "SAME  $FN ${n##*.}"; else echo "DIFF  $FN ${n##*.}"; PRESERVE_FAIL=$((PRESERVE_FAIL+1)); fi
  done
done
echo "diffs=$PRESERVE_FAIL (expected: exactly 2 — meta-insights-reader anonkey+noauth, the intended auth closure)"
echo "=== ON enforcement summary (B) ==="
for FN in $FNS; do for f in "$OUT"/ON.B.$FN.*; do n=$(basename "$f"); echo "$n :: $(tail -c 220 "$f" | tr '\n' ' ')"; done; done
echo "=== ON old-code bypass evidence (A) ==="
for FN in $FNS; do f="$OUT/ON.A.$FN.u1"; [ -f "$f" ] && echo "ON.A.$FN.u1 :: $(tail -c 160 "$f" | tr '\n' ' ')"; done
f="$OUT/ON.A.commercial-image-generate.u1_crosstenant"; [ -f "$f" ] && echo "ON.A.cig.u1 :: $(tail -c 160 "$f" | tr '\n' ' ')"
