// Integration test of the ACTUAL edge handlers (transpiled from the real committed .ts files),
// driven against realistic provider fixtures with Deno + fetch stubbed. NO network, NO provider spend.
// Verifies the REAL code paths: envelope classification, extraction, PRIVATE-Storage upload paths,
// persister call contracts (non-http storage_ref, signed source_url as provenance, mime), settlement/
// refund, redaction (response + telemetry), single provider dispatch, trusted-gate, and the pre-charge path.
//
// Run (needs esbuild only to transpile the Deno TS to importable ESM; no runtime deps):
//   OUT=/tmp/kalo_real_edge && mkdir -p $OUT
//   npx -y esbuild@0.24.2 supabase/functions/kalodata-product-images/index.ts --format=esm --platform=neutral --outfile=$OUT/images.mjs
//   npx -y esbuild@0.24.2 supabase/functions/kalodata-product-detail/index.ts --format=esm --platform=neutral --outfile=$OUT/detail.mjs
//   IMAGES_JS=$OUT/images.mjs DETAIL_JS=$OUT/detail.mjs node supabase/drafts/tests/kalodata_real_edge_fixtures.mjs
import { pathToFileURL } from "node:url";

const IMAGES_JS = process.env.IMAGES_JS;
const DETAIL_JS = process.env.DETAIL_JS;

const ENV = {
  SUPABASE_URL: "http://mock.local",
  SUPABASE_SERVICE_ROLE_KEY: "svc_role_key_FAKE",
  SUPABASE_ANON_KEY: "anon_key_FAKE",
  KALODATA_SECRET_KEY: "sk_live_FAKE_SECRET_zzz999",
};
globalThis.Deno = { env: { get: (k) => ENV[k] }, serve: (h) => { globalThis.__HANDLER__ = h; } };

let S;
function resetScenario(cfg = {}) {
  S = {
    providerFixture: cfg.providerFixture ?? { status: 200, body: { success: true, data: {} } },
    imageBytesList: cfg.imageBytesList ?? [],
    imageContentType: cfg.imageContentType ?? "image/jpeg",
    reqBuilderOk: cfg.reqBuilderOk ?? true,
    providerCalls: 0, settle: [], persistImage: [], persistDetail: [], uploads: [], lane: [], usage: [], nonce: 0, imageDownloads: 0,
  };
}
const jsonRes = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  // Only RPC calls send a JSON *string* body; the Storage upload sends raw binary bytes — never JSON.parse those.
  let body = {};
  try { if (opts && typeof opts.body === "string") body = JSON.parse(opts.body); } catch { body = {}; }
  if (u.includes("/rest/v1/rpc/fn_kalodata_consume_invoke_nonce")) { S.nonce++; return jsonRes(true); }
  if (u.includes("/rest/v1/rpc/fn_kalodata_images_request")) return jsonRes(S.reqBuilderOk ? { ok: true, operation: "tiktok/product/images", request_body: { product_id: body.p_kalodata_product_id } } : { ok: false, reason: "UNSUPPORTED_MARKET" });
  if (u.includes("/rest/v1/rpc/fn_kalodata_detail_request")) return jsonRes(S.reqBuilderOk ? { ok: true, request_body: { region: "DE", product_id: body.p_kalodata_product_id, date_range: "last7Day", need_image: 1 } } : { ok: false, reason: "UNSUPPORTED_MARKET" });
  if (u.includes("/rest/v1/rpc/fn_kalodata_research_image_exists")) return jsonRes(false);
  if (u.includes("/rest/v1/rpc/fn_persist_kalodata_research_image")) { S.persistImage.push(body); return jsonRes({ status: "registered", asset_id: "asset_" + S.persistImage.length }); }
  if (u.includes("/rest/v1/rpc/fn_persist_kalodata_product_detail")) { S.persistDetail.push(body); return jsonRes({ ok: true, product_id: body.p_product, authority: "REFERENCE_ONLY" }); }
  if (u.includes("/rest/v1/rpc/fn_kalodata_op_complete_from_edge")) { S.settle.push(body.p_outcome); return jsonRes({ status: "ok", outcome: body.p_outcome }); }
  if (u.includes("/rest/v1/rpc/fn_kalodata_record_lane_outcome")) { S.lane.push(body); return jsonRes({ ok: true, run_id: "run_1" }); }
  if (u.includes("/rest/v1/rpc/fn_kalodata_record_usage")) { S.usage.push(body); return jsonRes({ ok: true }); }
  if (u.includes("/storage/v1/object/")) { S.uploads.push(u.split("/storage/v1/object/")[1]); return jsonRes({ Key: "ok" }); }
  if (u.includes("kalodata.com")) { S.providerCalls++; const f = S.providerFixture; return new Response(typeof f.body === "string" ? f.body : JSON.stringify(f.body), { status: f.status ?? 200, headers: { "content-type": "application/json" } }); }
  if (u.includes("cdn.kalodata.example")) { const b = S.imageBytesList[S.imageDownloads] ?? new Uint8Array([9, 9, 9, 9]); S.imageDownloads++; return new Response(b, { status: 200, headers: { "content-type": S.imageContentType } }); }
  throw new Error("unexpected fetch: " + u);
};

function edgeRequest(payload, { nonce = "n".repeat(64) } = {}) {
  const headers = { "content-type": "application/json", authorization: "Bearer anon_key_FAKE", apikey: "anon_key_FAKE" };
  if (nonce) headers["x-pulse-nonce"] = nonce;
  return new Request("http://mock.local/functions/v1/edge", { method: "POST", headers, body: JSON.stringify(payload) });
}
const PAYLOAD = { market: "DE", user_id: "t1", product_id: "p1", kalodata_product_id: "kpid1", refresh_request_id: "req1" };

let imagesHandler, detailHandler;
globalThis.__HANDLER__ = null; await import(pathToFileURL(IMAGES_JS).href); imagesHandler = globalThis.__HANDLER__;
globalThis.__HANDLER__ = null; await import(pathToFileURL(DETAIL_JS).href); detailHandler = globalThis.__HANDLER__;

let pass = 0, fail = 0;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"}  ${label}`); cond ? pass++ : fail++; }
async function readJson(res) { return JSON.parse(await res.text()); }
const future = new Date(Date.now() + 5 * 60 * 1000).toISOString();

console.log("=== IMAGES edge (real handler) ===");
resetScenario({ providerFixture: { status: 200, body: { success: true, code: 0, data: { product_id: "kpid1", images: ["https://cdn.kalodata.example/a.jpg", "https://cdn.kalodata.example/b.jpg"], expires_at: future } } }, imageBytesList: [new Uint8Array([1, 2, 3]), new Uint8Array([4, 5, 6])] });
let res = await imagesHandler(edgeRequest(PAYLOAD)); let j = await readJson(res);
check("IMG populated: HTTP 200 & lane SUCCESS_PRODUCT_IMAGES", res.status === 200 && j.lane_status === "SUCCESS_PRODUCT_IMAGES");
check("IMG populated: exactly ONE provider dispatch", S.providerCalls === 1);
check("IMG populated: 2 byte downloads + 2 private-Storage uploads", S.imageDownloads === 2 && S.uploads.length === 2);
check("IMG populated: upload path = pulse-research-reference/kalodata/t1/p1/<hash>.jpg", S.uploads.every((p) => /^pulse-research-reference\/kalodata\/t1\/p1\/[0-9a-f]{64}\.jpg$/.test(p)));
check("IMG populated: 2 persister calls; storage_ref NON-http object ref; source_url signed http url; mime image/jpeg", S.persistImage.length === 2 && S.persistImage.every((a) => !/^https?:\/\//i.test(a.p_storage_ref) && a.p_storage_ref.startsWith("pulse-research-reference/") && /^https:\/\/cdn\.kalodata\.example\//.test(a.p_source_url) && a.p_mime === "image/jpeg"));
check("IMG populated: settle SUCCESS exactly once", S.settle.length === 1 && S.settle[0] === "SUCCESS");
check("IMG populated: diagnostics present (envelope, data_keys names only)", j.diagnostics && j.diagnostics.envelope === true && Array.isArray(j.diagnostics.data_keys) && j.diagnostics.data_keys.includes("images"));
check("IMG populated: response carries NO secret", !JSON.stringify(j).includes(ENV.KALODATA_SECRET_KEY));

resetScenario({ providerFixture: { status: 200, body: { success: true, data: { product_id: "kpid1", images: ["https://cdn.kalodata.example/a.jpg", "https://cdn.kalodata.example/b.jpg"], expires_at: future } } }, imageBytesList: [new Uint8Array([7, 7, 7]), new Uint8Array([7, 7, 7])] });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG dedup: identical bytes -> 1 upload, 1 persist, cached 1 deduped 1, settle SUCCESS", S.uploads.length === 1 && S.persistImage.length === 1 && j.cached === 1 && j.deduped === 1 && S.settle[0] === "SUCCESS");

resetScenario({ providerFixture: { status: 200, body: { success: false, code: 4003, message: "quota exceeded", data: null } } });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG api-error: lane PROVIDER_API_ERROR, HTTP 502", res.status === 502 && j.lane_status === "PROVIDER_API_ERROR");
check("IMG api-error: internal refund (settle POST_CHARGE) once; provider dispatched once", S.settle.length === 1 && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.providerCalls === 1);
check("IMG api-error: NO storage upload, NO persist (not treated as success)", S.uploads.length === 0 && S.persistImage.length === 0 && j.lane_status !== "SUCCESS_NO_IMAGES");
check("IMG api-error: response does NOT claim the provider refunded its charge", !/provider_refunded|refund/i.test(JSON.stringify(j)));
check("IMG api-error: diagnostics.success=false, code captured", j.diagnostics && j.diagnostics.success === false && j.diagnostics.code === "4003");

resetScenario({ providerFixture: { status: 200, body: { success: true, code: 0, data: { product_id: "kpid1", images: [] } } } });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG empty-set: SUCCESS_NO_IMAGES, settle SUCCESS, no upload/persist", res.status === 200 && j.lane_status === "SUCCESS_NO_IMAGES" && S.settle[0] === "SUCCESS" && S.uploads.length === 0 && S.persistImage.length === 0);

resetScenario({ providerFixture: { status: 200, body: [{ foo: 1 }] } });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG unexpected: lane UNEXPECTED_RESPONSE_SHAPE, refund, no upload", j.lane_status === "UNEXPECTED_RESPONSE_SHAPE" && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.uploads.length === 0);

resetScenario({ providerFixture: { status: 402, body: { message: "payment required" } } });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG http-402: status 402, lane PAYMENT_REQUIRED, settle POST_CHARGE, no upload", res.status === 402 && j.lane_status === "PAYMENT_REQUIRED" && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.uploads.length === 0);

resetScenario({ providerFixture: { status: 200, body: { success: true, data: { images: [] } } } });
res = await imagesHandler(edgeRequest(PAYLOAD, { nonce: null })); j = await readJson(res);
check("IMG untrusted: 403 forbidden, zero provider dispatch, zero settle", res.status === 403 && S.providerCalls === 0 && S.settle.length === 0);

resetScenario({ providerFixture: { status: 200, body: { success: true, data: { images: [] } } } });
ENV.KALODATA_SECRET_KEY = "";
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG no-secret: 424 AUTH_FAILED, settle PRE_CHARGE, zero provider dispatch", res.status === 424 && j.lane_status === "AUTH_FAILED" && S.settle[0] === "PROVIDER_FAILED_PRE_CHARGE" && S.providerCalls === 0);
ENV.KALODATA_SECRET_KEY = "sk_live_FAKE_SECRET_zzz999";

resetScenario({ providerFixture: { status: 200, body: { success: false, code: 9, message: `boom secret-key=${ENV.KALODATA_SECRET_KEY} tail`, data: null } } });
res = await imagesHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("IMG redaction: secret absent from response; [REDACTED] present in diagnostics.message", !JSON.stringify(j).includes(ENV.KALODATA_SECRET_KEY) && typeof j.diagnostics.message === "string" && j.diagnostics.message.includes("[REDACTED]"));
check("IMG redaction: lane-outcome telemetry also carries no secret", !JSON.stringify(S.lane).includes(ENV.KALODATA_SECRET_KEY));

console.log("\n=== DETAIL edge (real handler) ===");
resetScenario({ providerFixture: { status: 200, body: { success: true, code: 0, data: { product_id: "kpid1", product_name: "Hit the Slab", master_image_url: null, product_description: [], revenue: 21587.46 } } } });
res = await detailHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("DET populated: 200 SUCCESS_DETAIL, 1 provider dispatch, 1 persist, settle SUCCESS", res.status === 200 && j.lane_status === "SUCCESS_DETAIL" && S.providerCalls === 1 && S.persistDetail.length === 1 && S.settle[0] === "SUCCESS");
check("DET populated: persister got tenant-isolated args + detail.product_id", S.persistDetail[0].p_tenant === "t1" && S.persistDetail[0].p_product === "p1" && S.persistDetail[0].p_market === "DE" && S.persistDetail[0].p_detail.product_id === "kpid1");
check("DET populated: diagnostics present, no secret", j.diagnostics && j.diagnostics.envelope === true && !JSON.stringify(j).includes(ENV.KALODATA_SECRET_KEY));

resetScenario({ providerFixture: { status: 200, body: { success: false, code: 1001, message: "no data", data: null } } });
res = await detailHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("DET api-error: PROVIDER_API_ERROR, refund POST_CHARGE once, no persist, not success", j.lane_status === "PROVIDER_API_ERROR" && S.settle.length === 1 && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.persistDetail.length === 0);
check("DET api-error: response does NOT claim provider refunded", !/provider_refunded/i.test(JSON.stringify(j)));

resetScenario({ providerFixture: { status: 200, body: { success: true, data: {} } } });
res = await detailHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("DET empty: EMPTY_DETAIL, refund, no persist", j.lane_status === "EMPTY_DETAIL" && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.persistDetail.length === 0);

resetScenario({ providerFixture: { status: 200, body: { success: true, data: [{ product_id: "x" }] } } });
res = await detailHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("DET array-data: EMPTY_DETAIL (extractDetail skips arrays), refund, no persist", j.lane_status === "EMPTY_DETAIL" && S.persistDetail.length === 0);

resetScenario({ providerFixture: { status: 429, body: { message: "slow down" } } });
res = await detailHandler(edgeRequest(PAYLOAD)); j = await readJson(res);
check("DET http-429: 502 RATE_LIMITED, settle POST_CHARGE, no persist", res.status === 502 && j.lane_status === "RATE_LIMITED" && S.settle[0] === "PROVIDER_FAILED_POST_CHARGE" && S.persistDetail.length === 0);

console.log(`\n==== ${pass} passed, ${fail} failed ====`);
process.exit(fail === 0 ? 0 : 1);
