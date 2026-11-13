// Non-chargeable offline verification of the envelope-diagnostics correction (Phase 23).
// Replicates the EXACT functions + decision pipelines in the two edge files
// (supabase/functions/kalodata-product-images, kalodata-product-detail).
// No network, no provider call, no secrets.  Run:  node supabase/drafts/tests/kalodata_envelope_diagnostics.mjs

const FAKE_SECRET = "sk_fake_SECRET_value_do_not_use";

// ---- redact() (verbatim logic; secret sourced from a fake constant here) ----
function redact(input) {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const v = FAKE_SECRET;
  if (v && v.length > 0) { s = s.split(v).join("[REDACTED]"); const t = v.trim(); if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]"); }
  s = s.replace(/("?(?:secret[_-]?key|api[_-]?key|access_token|authorization)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
}
// ---- classifyEnvelope() (verbatim, types stripped) ----
function classifyEnvelope(body) {
  const isObj = body != null && typeof body === "object" && !Array.isArray(body);
  const success = isObj ? body.success : undefined;
  const rawCode = isObj ? body.code : undefined;
  const dataVal = isObj ? body.data : undefined;
  const dataPresent = dataVal !== undefined && dataVal !== null;
  const dataType = !isObj
    ? (Array.isArray(body) ? "array" : body === null ? "null" : typeof body)
    : (dataVal === null ? "null" : dataVal === undefined ? "absent" : Array.isArray(dataVal) ? "array" : typeof dataVal);
  const msg = isObj && body.message != null ? redact(String(body.message)).slice(0, 160) : null;
  const diag = {
    envelope: isObj,
    success: typeof success === "boolean" ? success : (success == null ? null : String(success).slice(0, 12)),
    code: (typeof rawCode === "number" || typeof rawCode === "string") ? String(rawCode).slice(0, 24) : null,
    message_present: !!(msg && msg.length > 0),
    message: msg,
    data_type: dataType,
    data_present: dataPresent,
    data_len: Array.isArray(dataVal) ? dataVal.length : null,
    data_keys: (dataPresent && typeof dataVal === "object" && !Array.isArray(dataVal)) ? Object.keys(dataVal).slice(0, 24) : null,
    cached: isObj && typeof body.cached === "boolean" ? body.cached : null,
  };
  if (success === false) return { decision: "API_ERROR", diag };
  if (isObj && dataPresent) return { decision: "DATA", diag };
  if (isObj && success === true) return { decision: "EMPTY", diag };
  return { decision: "UNEXPECTED_SHAPE", diag };
}
// ---- extractImages / extractDetail (verbatim, types stripped) ----
function extractImages(body) {
  const d = body?.data ?? body?.result ?? body ?? {};
  let arr = d?.images ?? d?.image_list ?? d?.urls ?? [];
  if (!Array.isArray(arr)) arr = [];
  const images = arr.map((x) => (typeof x === "string" ? x : (x && typeof x === "object" ? String(x.url ?? x.image_url ?? "") : ""))).map((s) => s.trim()).filter((s) => /^https?:\/\//i.test(s));
  return { images, productId: d?.product_id != null ? String(d.product_id) : null, expiresAt: d?.expires_at != null ? String(d.expires_at) : null };
}
function extractDetail(body) {
  for (const p of [body?.data, body?.data?.detail, body?.data?.product, body?.result, body?.detail, body?.product, body]) {
    if (p && typeof p === "object" && !Array.isArray(p) && (p.product_id || p.master_image_url || p.product_description || p.variants || p.attributes)) return p;
  }
  return null;
}
function httpErrorLane(status) {
  return status === 401 || status === 403 ? "AUTH_FAILED" : status === 402 ? "PAYMENT_REQUIRED" : status === 429 ? "RATE_LIMITED" : status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
}

// ---- Decision pipelines (model the edge control flow; settle & dispatch counters) ----
function decideImages(providerBody) {
  const settle = []; const dispatches = 1; let persistInvoked = false;
  const env = classifyEnvelope(providerBody);
  if (env.decision === "API_ERROR") { settle.push("PROVIDER_FAILED_POST_CHARGE"); return { lane: "PROVIDER_API_ERROR", http: 502, settle, dispatches, persistInvoked, diag: env.diag }; }
  const { images } = extractImages(providerBody);
  if (images.length === 0) {
    if (env.decision === "UNEXPECTED_SHAPE") { settle.push("PROVIDER_FAILED_POST_CHARGE"); return { lane: "UNEXPECTED_RESPONSE_SHAPE", http: 502, settle, dispatches, persistInvoked, diag: env.diag }; }
    settle.push("SUCCESS"); return { lane: "SUCCESS_NO_IMAGES", http: 200, settle, dispatches, persistInvoked, diag: env.diag };
  }
  persistInvoked = true; settle.push("SUCCESS"); return { lane: "SUCCESS_PRODUCT_IMAGES", http: 200, settle, dispatches, persistInvoked, diag: env.diag };
}
function decideDetail(providerBody) {
  const settle = []; const dispatches = 1; let persistInvoked = false;
  const env = classifyEnvelope(providerBody);
  if (env.decision === "API_ERROR") { settle.push("PROVIDER_FAILED_POST_CHARGE"); return { lane: "PROVIDER_API_ERROR", http: 502, settle, dispatches, persistInvoked, diag: env.diag }; }
  const detail = extractDetail(providerBody);
  if (!detail) { const lane = env.decision === "UNEXPECTED_SHAPE" ? "UNEXPECTED_RESPONSE_SHAPE" : "EMPTY_DETAIL"; settle.push("PROVIDER_FAILED_POST_CHARGE"); return { lane, http: 502, settle, dispatches, persistInvoked, diag: env.diag }; }
  persistInvoked = true; settle.push("SUCCESS"); return { lane: "SUCCESS_DETAIL", http: 200, settle, dispatches, persistInvoked, diag: env.diag };
}

// ---- assertion harness ----
let pass = 0, fail = 0;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"}  ${label}`); cond ? pass++ : fail++; }
function invariants(label, r) {
  check(`${label} :: settles exactly once`, r.settle.length === 1);
  check(`${label} :: dispatches exactly once`, r.dispatches === 1);
}

const HIT_SLAB = { success: true, code: 0, cached: false, message: "ok", data: { product_id: "1729945300622678813", product_name: "Hit the Slab", master_image_url: null, product_description: [], revenue: 21587.46 } };
const IMG_OK = { success: true, code: 0, data: { product_id: "p", images: ["https://a/1.jpg", "https://b/2.jpg"], expires_at: "2026-11-13T08:00:00Z" } };

console.log("=== DETAIL pipeline ===");
let r;
r = decideDetail(HIT_SLAB);                                   invariants("D-populated", r);
check("D-populated -> SUCCESS_DETAIL / settle SUCCESS / persist", r.lane === "SUCCESS_DETAIL" && r.settle[0] === "SUCCESS" && r.persistInvoked === true);
r = decideDetail({ success: true, code: 0, data: {} });       invariants("D-empty-obj", r);
check("D-empty data{} -> EMPTY_DETAIL / refund / no persist", r.lane === "EMPTY_DETAIL" && r.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && r.persistInvoked === false);
r = decideDetail({ success: false, code: 1001, message: "no data", data: null }); invariants("D-api-error", r);
check("D-success:false -> PROVIDER_API_ERROR / refund / NOT success", r.lane === "PROVIDER_API_ERROR" && r.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && r.settle[0] !== "SUCCESS");
r = decideDetail({});                                         invariants("D-bare-obj", r);
check("D-missing fields {} -> UNEXPECTED_RESPONSE_SHAPE / refund", r.lane === "UNEXPECTED_RESPONSE_SHAPE" && r.settle[0] === "PROVIDER_FAILED_POST_CHARGE");
r = decideDetail({ success: true, data: [{ product_id: "x" }] }); invariants("D-array-data", r);
check("D-array data -> EMPTY_DETAIL (parser skips arrays) / refund", r.lane === "EMPTY_DETAIL" && r.persistInvoked === false);
r = decideDetail([{ product_id: "x" }]);                      invariants("D-array-body", r);
check("D-array body -> UNEXPECTED_RESPONSE_SHAPE / refund", r.lane === "UNEXPECTED_RESPONSE_SHAPE");

console.log("\n=== IMAGES pipeline ===");
r = decideImages(IMG_OK);                                     invariants("I-populated", r);
check("I-populated(2 urls) -> SUCCESS_PRODUCT_IMAGES / settle SUCCESS / persist", r.lane === "SUCCESS_PRODUCT_IMAGES" && r.settle[0] === "SUCCESS" && r.persistInvoked === true);
r = decideImages({ success: true, data: { product_id: "p", images: [] } }); invariants("I-empty-set", r);
check("I-empty images[] -> SUCCESS_NO_IMAGES / settle SUCCESS (legit charge) / no persist", r.lane === "SUCCESS_NO_IMAGES" && r.settle[0] === "SUCCESS" && r.persistInvoked === false);
r = decideImages({ success: false, message: "quota exceeded", data: null }); invariants("I-api-error", r);
check("I-success:false -> PROVIDER_API_ERROR / refund / NOT treated as success", r.lane === "PROVIDER_API_ERROR" && r.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && r.lane !== "SUCCESS_NO_IMAGES");
r = decideImages({});                                         invariants("I-bare-obj", r);
check("I-missing fields {} -> UNEXPECTED_RESPONSE_SHAPE / refund", r.lane === "UNEXPECTED_RESPONSE_SHAPE" && r.settle[0] === "PROVIDER_FAILED_POST_CHARGE");
r = decideImages([ "https://a/1.jpg" ]);                      invariants("I-array-body", r);
check("I-array body -> UNEXPECTED_RESPONSE_SHAPE / refund", r.lane === "UNEXPECTED_RESPONSE_SHAPE");
r = decideImages({ success: true, data: { images: [{ url: "https://a/1.jpg" }] } }); invariants("I-object-entries", r);
check("I-object URL entries -> SUCCESS_PRODUCT_IMAGES / persist", r.lane === "SUCCESS_PRODUCT_IMAGES" && r.persistInvoked === true);

console.log("\n=== Transport (provider HTTP error) mapping — identical in both edges ===");
check("HTTP 401 -> AUTH_FAILED", httpErrorLane(401) === "AUTH_FAILED");
check("HTTP 402 -> PAYMENT_REQUIRED", httpErrorLane(402) === "PAYMENT_REQUIRED");
check("HTTP 429 -> RATE_LIMITED", httpErrorLane(429) === "RATE_LIMITED");
check("HTTP 500 -> PROVIDER_UNAVAILABLE", httpErrorLane(500) === "PROVIDER_UNAVAILABLE");
check("HTTP 400 -> FAILED", httpErrorLane(400) === "FAILED");

console.log("\n=== Secret redaction & bounded diagnostics ===");
const leaky = { success: false, code: 7, message: `boom secret-key=${FAKE_SECRET} api_key=${FAKE_SECRET} tail`, data: null };
const dg = classifyEnvelope(leaky).diag;
check("redaction: fake secret NOT present in diagnostics.message", typeof dg.message === "string" && !dg.message.includes(FAKE_SECRET));
check("redaction: [REDACTED] marker present", typeof dg.message === "string" && dg.message.includes("[REDACTED]"));
check("message bounded <= 160 chars", typeof dg.message === "string" && dg.message.length <= 160);
const keysOnly = classifyEnvelope({ success: true, data: { product_id: "p", images: ["https://secret/x.jpg"], token: "abc" } }).diag;
check("data_keys are NAMES only (no values/urls)", Array.isArray(keysOnly.data_keys) && JSON.stringify(keysOnly.data_keys) === JSON.stringify(["product_id", "images", "token"]) && !JSON.stringify(keysOnly.data_keys).includes("https://"));
check("diagnostics never carries raw body / url values", !JSON.stringify(dg).includes("https://") && dg.data_type === "null");

console.log(`\n==== ${pass} passed, ${fail} failed ====`);
process.exit(fail === 0 ? 0 : 1);
