// STRATELOQ-PROVIDER-MEDIA/DETAIL-BROKER
// Trusted-server pattern: gateway verify_jwt=true; provider secrets read ONLY from Edge env,
// never logged/returned/persisted. Trusted by service role OR single-use nonce. Fail closed.
// Modes:
//  - mode:"rank_raw" (provider FASTMOSS|KALODATA): call the ENTITLED discovery rank endpoint and
//    return raw rows (no ingest) to confirm product-native image fields + recover cover URLs.
//  - mode:"kalodata_detail": call Kalodata's documented Product Detail endpoint
//    (POST /openapi/v1/tiktok/product/detail, secret-key header) by product_id to test whether the
//    existing credential is entitled and whether descriptive product fields are returned. One call,
//    no ingest, response redacted. Entitlement/contract is unknown until tested.
//  - default: FastMoss product-by-id detail (/product/v1/search + /product/v1/videoList). Live test
//    2026-10-19 (product 1729937925462923841, DE): HTTP 200 on both; provider BODY codes ->
//    /product/v1/search = 403 'can not access current endpoint' (STILL NOT ENTITLED);
//    /product/v1/videoList = code 1 'param error' (NOT a 403 -> reachable/entitlement open, but the old
//    flat {product_id} body was rejected). Fix: both bodies now use the entitled filter/paging shape and
//    accept per-call search_body/video_body overrides. videoList shape UNVERIFIED pending one more
//    founder-authorised call (test cap = 1/endpoint). No fields were returned (both data:[]).

const SEARCH_DEFAULT = "https://openapi.fastmoss.com/product/v1/search";
const VIDEOLIST_DEFAULT = "https://openapi.fastmoss.com/product/v1/videoList";
const FM_SECRET_ENV = "FASTMOSS_CLIENT_SECRET";
const KL_SECRET_ENV = "KALODATA_SECRET_KEY";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  for (const envk of [FM_SECRET_ENV, KL_SECRET_ENV]) {
    const v = Deno.env.get(envk);
    if (v && v.length > 0) { s = s.split(v).join("[REDACTED]"); const t = v.trim(); if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]"); }
  }
  s = s.replace(/("?(?:client_secret|secret[_-]?key|api[_-]?key|access_token|authorization|bearer)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s;
}
function redactJson(body: unknown): unknown { try { return JSON.parse(redact(JSON.stringify(body ?? null))); } catch { return null; } }
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let out = 0; for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i); return out === 0;
}
function callerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!m) return null; const parts = m[1].split("."); if (parts.length < 2) return null;
  try { const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/"); const pad = b64 + "=".repeat((4 - (b64.length % 4)) % 4); return JSON.parse(atob(pad)).role ?? null; } catch { return null; }
}
function isTrustedServer(req: Request): boolean {
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const apikey = req.headers.get("apikey") || "";
  const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  return callerRole(req) === "service_role" || timingSafeEqual(apikey, svc) || timingSafeEqual(bearer, svc);
}
async function rpc(fn: string, args: Record<string, unknown>): Promise<{ ok: boolean; status: number; body: unknown }> {
  const url = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "") + "/rest/v1/rpc/" + fn;
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", apikey: svc, authorization: "Bearer " + svc }, body: JSON.stringify(args) });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  let trusted = isTrustedServer(req);
  if (!trusted) {
    const nonce = req.headers.get("x-pulse-nonce");
    if (nonce && nonce.length >= 32) {
      try { const nr = await rpc("fn_kalodata_consume_invoke_nonce", { p_token: nonce }); trusted = nr.ok && (nr.body === true || nr.body === "true"); } catch { trusted = false; }
    }
  }
  if (!trusted) return jsonResponse(403, { ok: false, error: "forbidden_requires_service_role_or_valid_nonce" });

  let payload: any = {};
  const raw = await req.text();
  if (raw && raw.trim().length > 0) { try { payload = JSON.parse(raw); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); } }

  const fmSecret = (Deno.env.get(FM_SECRET_ENV) ?? "").trim();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", fastmoss_secret_present: Boolean(fmSecret), kalodata_secret_present: Boolean((Deno.env.get(KL_SECRET_ENV) ?? "").trim()) });

  if (payload.mode === "rank_raw") {
    const market0 = String(payload.market ?? "").trim().toUpperCase();
    const provider0 = String(payload.provider ?? "FASTMOSS").trim().toUpperCase();
    if (!market0) return jsonResponse(400, { ok: false, error: "missing_market" });
    if (provider0 === "KALODATA") {
      const ks = (Deno.env.get(KL_SECRET_ENV) ?? "").trim();
      if (!ks) return jsonResponse(424, { ok: false, provider: "KALODATA", lane_status: "AUTH_FAILED", error: "server_secret_unavailable" });
      const rb0 = await rpc("fn_kalodata_discovery_request", { p_market: market0 });
      const body0 = (rb0.body as any);
      if (!body0 || body0.ok !== true) return jsonResponse(502, { ok: false, error: "request_builder_failed", reason: body0?.reason ?? null });
      const url = String(body0.endpoint || "").replace(/^POST\s+/i, "").trim() || "https://www.kalodata.com/openapi/v1/tiktok/product/rank";
      try {
        const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", "secret-key": ks }, body: JSON.stringify(body0.request_body ?? {}) });
        return jsonResponse(200, { ok: r.ok, mode: "rank_raw", provider: "KALODATA", market: market0, http_status: r.status, raw: redactJson(await r.json().catch(() => ({}))) });
      } catch (e) { return jsonResponse(502, { ok: false, mode: "rank_raw", provider: "KALODATA", error: redact((e as Error).message) }); }
    }
    if (!fmSecret) return jsonResponse(424, { ok: false, provider: "FASTMOSS", lane_status: "AUTH_FAILED", error: "server_secret_unavailable" });
    const rb0 = await rpc("fn_fastmoss_discovery_request", { p_market: market0 });
    const body0 = (rb0.body as any);
    if (!body0 || body0.ok !== true) return jsonResponse(502, { ok: false, error: "request_builder_failed", reason: body0?.reason ?? null });
    const rankUrl = (Deno.env.get("FASTMOSS_BASE_URL") || "https://openapi.fastmoss.com/product/v1/rank/newListed").trim();
    try {
      const r = await fetch(rankUrl, { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer " + fmSecret }, body: JSON.stringify(body0.request_body ?? {}) });
      return jsonResponse(200, { ok: r.ok, mode: "rank_raw", provider: "FASTMOSS", market: market0, http_status: r.status, raw: redactJson(await r.json().catch(() => ({}))) });
    } catch (e) { return jsonResponse(502, { ok: false, mode: "rank_raw", provider: "FASTMOSS", error: redact((e as Error).message) }); }
  }

  if (payload.mode === "kalodata_detail") {
    const market0 = String(payload.market ?? "").trim().toUpperCase();
    const productId0 = String(payload.product_id ?? "").trim();
    if (!market0) return jsonResponse(400, { ok: false, error: "missing_market" });
    if (!productId0) return jsonResponse(400, { ok: false, error: "missing_product_id" });
    const ks = (Deno.env.get(KL_SECRET_ENV) ?? "").trim();
    if (!ks) return jsonResponse(424, { ok: false, provider: "KALODATA", lane_status: "AUTH_FAILED", error: "server_secret_unavailable" });
    // Reuse the confirmed Kalodata request conventions (region/currency/language) from the rank builder.
    const rb0 = await rpc("fn_kalodata_discovery_request", { p_market: market0 });
    const body0 = (rb0.body as any);
    if (!body0 || body0.ok !== true) return jsonResponse(502, { ok: false, error: "request_builder_failed", reason: body0?.reason ?? null });
    const detailUrl = (Deno.env.get("KALODATA_DETAIL_URL") || "https://www.kalodata.com/openapi/v1/tiktok/product/detail").trim();
    // Documented product-detail path; body mirrors the entitled rank conventions + the product id.
    const detailBody = (payload.detail_body && typeof payload.detail_body === "object")
      ? payload.detail_body
      : { product_id: productId0, region: body0.region, currency: body0.currency, language: body0.language ?? "en-US", date_range: "last7Day" };
    const lane = (s: number) => s === 401 || s === 403 ? "AUTH_OR_ENTITLEMENT_FAILED" : s === 402 ? "PAYMENT_REQUIRED" : s === 429 ? "RATE_LIMITED" : s >= 500 ? "PROVIDER_UNAVAILABLE" : s >= 200 && s < 300 ? "OK" : "FAILED";
    try {
      const r = await fetch(detailUrl, { method: "POST", headers: { "content-type": "application/json", "secret-key": ks }, body: JSON.stringify(detailBody) });
      const txt = await r.text();
      let raw: unknown; try { raw = JSON.parse(txt); } catch { raw = txt.slice(0, 2000); }
      return jsonResponse(200, { ok: r.ok, mode: "kalodata_detail", provider: "KALODATA", market: market0,
        product_id: productId0, endpoint: detailUrl, request_keys: Object.keys(detailBody),
        http_status: r.status, http_lane_status: lane(r.status), raw: redactJson(raw) });
    } catch (e) { return jsonResponse(502, { ok: false, mode: "kalodata_detail", provider: "KALODATA", error: redact((e as Error).message) }); }
  }

  const market = String(payload.market ?? "").trim().toUpperCase();
  const productId = String(payload.product_id ?? "").trim();
  const withVideos = payload.with_videos === true;
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!productId) return jsonResponse(400, { ok: false, error: "missing_product_id" });
  if (!fmSecret) return jsonResponse(424, { ok: false, provider: "FASTMOSS", lane_status: "AUTH_FAILED", error: "server_secret_unavailable" });

  const rb = await rpc("fn_fastmoss_discovery_request", { p_market: market });
  const region = (rb.body as any)?.region ?? market;
  const searchUrl = (Deno.env.get("FASTMOSS_SEARCH_URL") || SEARCH_DEFAULT).trim();
  const videoUrl = (Deno.env.get("FASTMOSS_VIDEOLIST_URL") || VIDEOLIST_DEFAULT).trim();
  const authHeaders = { "content-type": "application/json", authorization: "Bearer " + fmSecret };
  // Request bodies: default to the ENTITLED search contract shape (filter.product_id + region), which
  // /product/v1/search accepts; /product/v1/videoList previously got a flat {product_id} and FastMoss
  // replied code 1 "param error" (reachable, NOT a 403 entitlement block) — so it now mirrors the same
  // filter/paging shape. Either body can be overridden per-call (search_body/video_body) so the exact
  // documented schema can be supplied on the next authorised test without redeploying. No fabrication:
  // the response still carries the provider's real code/message/data verbatim (redacted for secrets).
  const searchBody = (payload.search_body && typeof payload.search_body === "object")
    ? payload.search_body : { filter: { product_id: productId, region } };
  const videoBody = (payload.video_body && typeof payload.video_body === "object")
    ? payload.video_body : { filter: { product_id: productId, region }, page: 1, pagesize: 10 };
  const out: any = { ok: true, provider: "FASTMOSS", market, region, product_id: productId,
    search_request_keys: Object.keys(searchBody), video_request_keys: withVideos ? Object.keys(videoBody) : null };
  try {
    const r = await fetch(searchUrl, { method: "POST", headers: authHeaders, body: JSON.stringify(searchBody) });
    out.search_http_status = r.status; out.search_raw = redactJson(await r.json().catch(() => ({})));
    out.search_lane_status = r.status === 401 || r.status === 403 ? "AUTH_FAILED" : r.status === 402 ? "PAYMENT_REQUIRED" : r.status === 429 ? "RATE_LIMITED" : r.status >= 500 ? "PROVIDER_UNAVAILABLE" : r.ok ? "OK" : "FAILED";
  } catch (e) { out.search_lane_status = "PROVIDER_UNAVAILABLE"; out.search_error = redact((e as Error).message); }
  if (withVideos) {
    try {
      const r = await fetch(videoUrl, { method: "POST", headers: authHeaders, body: JSON.stringify(videoBody) });
      out.video_http_status = r.status; out.video_raw = redactJson(await r.json().catch(() => ({})));
      out.video_lane_status = r.ok ? "OK" : (r.status === 401 || r.status === 403 ? "AUTH_FAILED" : r.status === 402 ? "PAYMENT_REQUIRED" : r.status === 429 ? "RATE_LIMITED" : "FAILED");
    } catch (e) { out.video_lane_status = "PROVIDER_UNAVAILABLE"; out.video_error = redact((e as Error).message); }
  }
  return jsonResponse(200, out);
});
