// STRATELOQ-FASTMOSS-PRODUCT-DETAIL-BROKER (Stage-2 product-native enrichment)
//
// Bounded, product-specific FastMoss detail broker. Same trusted-server pattern as the FastMoss
// discovery broker: gateway verify_jwt=true; the FastMoss client secret is read ONLY from the Edge
// Function env, never logged/returned/persisted. Trusted by the service role OR by a single-use
// capability nonce (fn_kalodata_consume_invoke_nonce). Fail closed.
//
// Unlike discovery (market-wide rank), this calls the documented product-by-id endpoints:
//   POST /product/v1/search     body { filter: { product_id, region } }   -> product detail
//   POST /product/v1/videoList  body { product_id }                        -> associated videos
// It performs NO broad discovery and NO ingest. v1 returns the raw (secret-redacted) provider
// payloads + HTTP statuses so the exact response schema and entitlement can be verified before
// any persistence mapping is built. One product per invocation.
//
// STATUS (2026-10-13): deployed + verified reachable. The provisioned FASTMOSS_CLIENT_SECRET is
// authenticated (it works for /product/v1/rank/newListed) but the account's plan does NOT entitle
// the product-detail module: both /product/v1/search and /product/v1/videoList return an
// application-level { code: 403, message: "can not access current endpoint" }. This broker is the
// ready activation point; it stays dormant (nothing auto-invokes it) until FastMoss grants the
// product-detail / product-video endpoints. Persistence/identity/media wiring is intentionally
// deferred until a real entitled response schema can be observed (never mapped from a guess).
//
// Secret (name only; value lives solely as an Edge Function secret, shared project-wide):
//   FASTMOSS_CLIENT_SECRET
// Optional env overrides:
//   FASTMOSS_SEARCH_URL     (default https://openapi.fastmoss.com/product/v1/search)
//   FASTMOSS_VIDEOLIST_URL  (default https://openapi.fastmoss.com/product/v1/videoList)

const SEARCH_DEFAULT = "https://openapi.fastmoss.com/product/v1/search";
const VIDEOLIST_DEFAULT = "https://openapi.fastmoss.com/product/v1/videoList";
const SECRET_ENV = "FASTMOSS_CLIENT_SECRET";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const v = Deno.env.get(SECRET_ENV);
  if (v && v.length > 0) { s = s.split(v).join("[REDACTED]"); const t = v.trim(); if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]"); }
  s = s.replace(/("?(?:client_secret|secret[_-]?key|api[_-]?key|access_token|authorization|bearer)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s;
}
function redactJson(body: unknown): unknown {
  try { return JSON.parse(redact(JSON.stringify(body ?? null))); } catch { return null; }
}
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

  const secret = (Deno.env.get(SECRET_ENV) ?? "").trim();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", secret_present: Boolean(secret) });

  const market = String(payload.market ?? "").trim().toUpperCase();
  const productId = String(payload.product_id ?? "").trim();
  const withVideos = payload.with_videos === true;
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!productId) return jsonResponse(400, { ok: false, error: "missing_product_id" });
  if (!secret) return jsonResponse(424, { ok: false, provider: "FASTMOSS", lane_status: "AUTH_FAILED", error: "server_secret_unavailable" });

  // region (secret-free) from the existing market config; reuse the discovery request builder.
  const rb = await rpc("fn_fastmoss_discovery_request", { p_market: market });
  const region = (rb.body as any)?.region ?? market;

  const searchUrl = (Deno.env.get("FASTMOSS_SEARCH_URL") || SEARCH_DEFAULT).trim();
  const videoUrl = (Deno.env.get("FASTMOSS_VIDEOLIST_URL") || VIDEOLIST_DEFAULT).trim();
  const authHeaders = { "content-type": "application/json", authorization: "Bearer " + secret };

  const out: any = { ok: true, provider: "FASTMOSS", market, region, product_id: productId };

  // 1) product/v1/search by product_id
  try {
    const r = await fetch(searchUrl, { method: "POST", headers: authHeaders, body: JSON.stringify({ filter: { product_id: productId, region } }) });
    out.search_http_status = r.status;
    out.search_raw = redactJson(await r.json().catch(() => ({})));
    if (r.status === 401 || r.status === 403) out.search_lane_status = "AUTH_FAILED";
    else if (r.status === 402) out.search_lane_status = "PAYMENT_REQUIRED";
    else if (r.status === 429) out.search_lane_status = "RATE_LIMITED";
    else if (r.status >= 500) out.search_lane_status = "PROVIDER_UNAVAILABLE";
    else if (r.ok) out.search_lane_status = "OK";
    else out.search_lane_status = "FAILED";
  } catch (e) { out.search_lane_status = "PROVIDER_UNAVAILABLE"; out.search_error = redact((e as Error).message); }

  // 2) product/v1/videoList by product_id (optional)
  if (withVideos) {
    try {
      const r = await fetch(videoUrl, { method: "POST", headers: authHeaders, body: JSON.stringify({ product_id: productId }) });
      out.video_http_status = r.status;
      out.video_raw = redactJson(await r.json().catch(() => ({})));
      out.video_lane_status = r.ok ? "OK" : (r.status === 401 || r.status === 403 ? "AUTH_FAILED" : r.status === 402 ? "PAYMENT_REQUIRED" : r.status === 429 ? "RATE_LIMITED" : "FAILED");
    } catch (e) { out.video_lane_status = "PROVIDER_UNAVAILABLE"; out.video_error = redact((e as Error).message); }
  }

  return jsonResponse(200, out);
});
