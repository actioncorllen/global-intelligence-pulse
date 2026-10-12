// STRATELOQ-KALODATA-SECURE-DISCOVERY-BROKER (Stage 1 COMMERCE lane)
//
// Server-side Kalodata product-native discovery broker. Same trusted-server pattern as
// tiktok-commercial-token: gateway verify_jwt=true, provider secret read ONLY from Edge
// Function env, never logged/returned/persisted. Trusted-server gate: caller must present
// the project's service_role key (matched against the built-in SUPABASE_SERVICE_ROLE_KEY)
// OR a service_role JWT claim -- a normal anon/browser JWT cannot invoke it. Fail closed.
//
// Flow (market only -> candidates; NO keyword/category/product/shop/creator/video seed):
//   1. RPC fn_kalodata_discovery_request(market) -> seed-free request body + region/currency
//      (secret-free; UNSUPPORTED_MARKET short-circuits before any provider call).
//   2. POST request body to Kalodata product/rank with the secret-key header (env only).
//      HTTP status -> explicit lane status (AUTH_FAILED/PAYMENT_REQUIRED/RATE_LIMITED/
//      PROVIDER_UNAVAILABLE). Never converts a provider failure into zero market demand.
//   3. RPC fn_kalodata_ingest_candidates(user, market, run, limit, products) -> candidates
//      enter the existing eligibility + auto_fresh_discovery research bridge.
//   4. Best-effort persist observed provider usage/credit onto the discovery run (no secret).
//
// The RAW SECRET never reaches the database, the response, logs, the frontend or analytics:
// this broker only returns the ingest summary (counts/statuses/run id), which carries no key.
//
// Secret (name only; value lives solely as an Edge Function secret):
//   KALODATA_SECRET_KEY           -- the Kalodata OpenAPI secret key (REQUIRED)
// Optional env overrides:
//   KALODATA_SECRET_HEADER        -- HTTP header name for the secret (default "secret-key")
//   KALODATA_BASE_URL             -- override endpoint (default product/rank openapi URL)

const DEFAULT_ENDPOINT = "https://www.kalodata.com/openapi/v1/tiktok/product/rank";
const SECRET_ENV = "KALODATA_SECRET_KEY";
const SECRET_HEADER_ENV = "KALODATA_SECRET_HEADER";
const BASE_URL_ENV = "KALODATA_BASE_URL";

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
  s = s.replace(/("?(?:secret[_-]?key|api[_-]?key|access_token|authorization)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
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

// Call a SECURITY DEFINER RPC via the project's PostgREST endpoint using the service role.
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

// Extract an array of product rows from whatever wrapper Kalodata returns.
function extractProducts(body: any): any[] {
  if (Array.isArray(body)) return body;
  for (const path of [body?.data, body?.data?.list, body?.data?.rows, body?.data?.products, body?.result, body?.result?.list, body?.list, body?.products, body?.rows]) {
    if (Array.isArray(path)) return path;
  }
  return [];
}
// Best-effort observed usage/credit (shape unknown; never assume constant cost).
function extractUsage(body: any): Record<string, unknown> | null {
  const u: Record<string, unknown> = {};
  for (const k of ["credit", "credits", "cost", "balance", "remaining_credit", "credit_cost", "used_credit"]) {
    if (body && body[k] !== undefined) u[k] = body[k];
    if (body?.data && body.data[k] !== undefined) u[k] = body.data[k];
  }
  return Object.keys(u).length ? u : null;
}
// Persist an explicit COMMERCE lane outcome (never carries the secret). Best-effort.
async function recordOutcome(userId: string, market: string, laneStatus: string, detail: Record<string, unknown>): Promise<void> {
  if (!userId) return;
  try { await rpc("fn_kalodata_record_lane_outcome", { p_user_id: userId, p_market: market, p_lane_status: laneStatus, p_detail: detail }); } catch (_e) { /* telemetry best-effort */ }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  // Trusted either by the service role, OR by a single-use capability nonce created by the
  // DB orchestrator (fn_kalodata_run_discovery) and validated via our own service-role DB
  // access. No shared secret is exposed; the nonce is 244-bit, single-use and 5-min TTL.
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
  const candidateLimit = Math.max(1, Math.min(Number(payload.candidate_limit ?? 10) || 10, 25));
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });

  // Fail closed if the secret is not configured. Lane status is explicit; no key is leaked.
  if (!secret) {
    await recordOutcome(userId, market, "AUTH_FAILED", { reason: "server_secret_unavailable" });
    return jsonResponse(424, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the KALODATA_SECRET_KEY Edge Function secret for project nxaunmyihhjixxxljcqt." });
  }

  // 1) seed-free request body (secret-free). UNSUPPORTED markets short-circuit here.
  const reqBuild = await rpc("fn_kalodata_discovery_request", { p_market: market });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    const laneStatus = reason === "UNSUPPORTED_MARKET" ? "UNSUPPORTED_MARKET" : "PROVIDER_UNAVAILABLE";
    await recordOutcome(userId, market, laneStatus, { reason });
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: reason === "UNSUPPORTED_MARKET", lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus });
  }
  const endpoint = (Deno.env.get(BASE_URL_ENV) || DEFAULT_ENDPOINT).trim();
  const secretHeader = (Deno.env.get(SECRET_HEADER_ENV) || "secret-key").trim();

  // 2) provider call with the secret-key header (env only).
  let provider: Response;
  let providerBody: any = {};
  try {
    provider = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", [secretHeader]: secret },
      body: JSON.stringify(rb.request_body ?? {}),
    });
    providerBody = await provider.json().catch(() => ({}));
  } catch (e) {
    await recordOutcome(userId, market, "PROVIDER_UNAVAILABLE", { reason: "network_error" });
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) });
  }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED"
      : provider.status === 402 ? "PAYMENT_REQUIRED"
      : provider.status === 429 ? "RATE_LIMITED"
      : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await recordOutcome(userId, market, laneStatus, { http_status: provider.status });
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const products = extractProducts(providerBody);
  const usage = extractUsage(providerBody);

  // 3) ingest -> existing eligibility + auto_fresh_discovery research bridge.
  const ingest = await rpc("fn_kalodata_ingest_candidates", {
    p_user_id: userId, p_market: market, p_run_id: null, p_candidate_limit: candidateLimit, p_products: products, p_dry_run: false,
  });
  const ib: any = ingest.body;
  if (!ingest.ok || !ib) {
    await recordOutcome(userId, market, "FAILED", { reason: "ingest_failed" });
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "FAILED", error: redact(ib ?? "ingest_failed") });
  }

  // Persist terminal outcomes the ingest adapter did not itself record as a run
  // (zero-candidate / unsupported / failed). SUCCESS_WITH_CANDIDATES already created a run.
  if (!ib.run_id && ib.status) {
    await recordOutcome(userId, market, String(ib.status), { scanned: ib.scanned ?? 0, raw_candidate_count: products.length });
  }

  // 4) best-effort usage/credit metadata onto the discovery run (no secret, bounded).
  if (usage && ib.run_id) {
    try {
      await rpc("fn_kalodata_record_usage", { p_run_id: ib.run_id, p_usage: usage, p_endpoint: endpoint });
    } catch (_e) { /* usage telemetry is best-effort; never fail discovery on it */ }
  }

  return jsonResponse(200, {
    ok: true, lane: "COMMERCE", provider: "KALODATA", market,
    lane_status: ib.status ?? "FAILED",
    raw_candidate_count: products.length,
    scanned: ib.scanned ?? null, qualified: ib.qualified ?? null, promoted_count: ib.promoted_count ?? 0,
    run_id: ib.run_id ?? null, promoted: ib.promoted ?? [], skipped: ib.skipped ?? [],
    provider_usage: usage,
  });
});
