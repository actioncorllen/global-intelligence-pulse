// STRATELOQ-FASTMOSS-SECURE-DISCOVERY-BROKER (Stage 1 COMMERCE lane, 2nd provider)
//
// Server-side FastMoss New Listed product-native discovery broker. Same trusted-server pattern
// as the Kalodata broker: gateway verify_jwt=true; the FastMoss client secret is read ONLY from
// the Edge Function env, never logged/returned/persisted. Trusted either by the service role OR
// by a single-use capability nonce (fn_kalodata_consume_invoke_nonce) the DB orchestrator
// (fn_fastmoss_run_discovery) creates and this broker validates with its own service-role DB
// access. Fail closed.
//
// Flow (market only -> candidates; NO keyword/category/product/shop/creator/video seed):
//   1. RPC fn_fastmoss_discovery_request(market) -> seed-free request body (region + derived
//      date_info) + currency. UNSUPPORTED_MARKET short-circuits before any provider call.
//   2. POST request body to FastMoss newListed with Authorization: Bearer <client_secret> (env).
//      HTTP status -> explicit lane status (AUTH_FAILED/PAYMENT_REQUIRED/RATE_LIMITED/
//      PROVIDER_UNAVAILABLE). Never converts a provider failure into zero market demand.
//   3. RPC fn_fastmoss_ingest_candidates(...) -> candidates enter the existing eligibility +
//      auto_fresh_discovery research bridge (branded/IP review + identity/dedup applied there).
//   4. Best-effort persist observed provider usage onto the discovery run (no secret).
//
// Secret (name only; value lives solely as an Edge Function secret):
//   FASTMOSS_CLIENT_SECRET        -- the FastMoss OpenAPI client secret (REQUIRED)
// Optional env override:
//   FASTMOSS_BASE_URL             -- override endpoint (default newListed openapi URL)

const DEFAULT_ENDPOINT = "https://openapi.fastmoss.com/product/v1/rank/newListed";
const SECRET_ENV = "FASTMOSS_CLIENT_SECRET";
const BASE_URL_ENV = "FASTMOSS_BASE_URL";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const v = Deno.env.get(SECRET_ENV);
  if (v && v.length > 0) {
    s = s.split(v).join("[REDACTED]");
    const t = v.trim();
    if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]");
  }
  s = s.replace(/("?(?:client_secret|secret[_-]?key|api[_-]?key|access_token|authorization|bearer)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
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
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: svc, authorization: "Bearer " + svc },
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}
// Extract product rows from whatever wrapper FastMoss returns.
function extractProducts(body: any): any[] {
  if (Array.isArray(body)) return body;
  for (const path of [body?.data?.list, body?.data?.rows, body?.data?.products, body?.data?.items,
                      body?.data, body?.result?.list, body?.result, body?.list, body?.products, body?.rows]) {
    if (Array.isArray(path)) return path;
  }
  return [];
}
function extractUsage(body: any): Record<string, unknown> | null {
  const u: Record<string, unknown> = {};
  for (const k of ["credit", "credits", "cost", "quota", "balance", "remaining_credit", "used_credit", "points"]) {
    if (body && body[k] !== undefined) u[k] = body[k];
    if (body?.data && body.data[k] !== undefined) u[k] = body.data[k];
  }
  return Object.keys(u).length ? u : null;
}
async function recordOutcome(userId: string, market: string, laneStatus: string, detail: Record<string, unknown>): Promise<void> {
  if (!userId) return;
  try { await rpc("fn_fastmoss_record_lane_outcome", { p_user_id: userId, p_market: market, p_lane_status: laneStatus, p_detail: detail }); } catch (_e) { /* telemetry best-effort */ }
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
  if (raw && raw.trim().length > 0) {
    try { payload = JSON.parse(raw); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }
  }

  const secret = (Deno.env.get(SECRET_ENV) ?? "").trim();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", secret_present: Boolean(secret) });

  const market = String(payload.market ?? "").trim().toUpperCase();
  const userId = String(payload.user_id ?? payload.userId ?? "").trim();
  const candidateLimit = Math.max(1, Math.min(Number(payload.candidate_limit ?? 10) || 10, 10));
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });

  if (!secret) {
    await recordOutcome(userId, market, "AUTH_FAILED", { reason: "server_secret_unavailable" });
    return jsonResponse(424, { ok: false, lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the FASTMOSS_CLIENT_SECRET Edge Function secret for project nxaunmyihhjixxxljcqt." });
  }

  const reqBuild = await rpc("fn_fastmoss_discovery_request", { p_market: market });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    const laneStatus = reason === "UNSUPPORTED_MARKET" ? "UNSUPPORTED_MARKET" : "PROVIDER_UNAVAILABLE";
    await recordOutcome(userId, market, laneStatus, { reason });
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: reason === "UNSUPPORTED_MARKET", lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: laneStatus });
  }
  const endpoint = (Deno.env.get(BASE_URL_ENV) || DEFAULT_ENDPOINT).trim();

  let provider: Response;
  let providerBody: any = {};
  try {
    provider = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + secret },
      body: JSON.stringify(rb.request_body ?? {}),
    });
    providerBody = await provider.json().catch(() => ({}));
  } catch (e) {
    await recordOutcome(userId, market, "PROVIDER_UNAVAILABLE", { reason: "network_error" });
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) });
  }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED"
      : provider.status === 402 ? "PAYMENT_REQUIRED"
      : provider.status === 429 ? "RATE_LIMITED"
      : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await recordOutcome(userId, market, laneStatus, { http_status: provider.status });
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.msg ?? providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const products = extractProducts(providerBody);
  const usage = extractUsage(providerBody);

  const ingest = await rpc("fn_fastmoss_ingest_candidates", {
    p_user_id: userId, p_market: market, p_run_id: null, p_candidate_limit: candidateLimit, p_products: products, p_dry_run: false,
  });
  const ib: any = ingest.body;
  if (!ingest.ok || !ib) {
    await recordOutcome(userId, market, "FAILED", { reason: "ingest_failed" });
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: "FAILED", error: redact(ib ?? "ingest_failed") });
  }
  if (!ib.run_id && ib.status) {
    await recordOutcome(userId, market, String(ib.status), { scanned: ib.scanned ?? 0, raw_candidate_count: products.length });
  }
  if (usage && ib.run_id) {
    try { await rpc("fn_kalodata_record_usage", { p_run_id: ib.run_id, p_usage: usage, p_endpoint: endpoint }); } catch (_e) { /* best-effort */ }
  }

  return jsonResponse(200, {
    ok: true, lane: "COMMERCE", provider: "FASTMOSS", market,
    lane_status: ib.status ?? "FAILED",
    raw_candidate_count: products.length,
    scanned: ib.scanned ?? null, qualified: ib.qualified ?? null, promoted_count: ib.promoted_count ?? 0,
    new_dispatched: ib.new_dispatched ?? 0, branded_review: ib.branded_review ?? 0,
    correlated: ib.correlated ?? 0, idempotent: ib.idempotent ?? 0,
    run_id: ib.run_id ?? null, promoted: ib.promoted ?? [], skipped: ib.skipped ?? [],
    provider_usage: usage,
  });
});
