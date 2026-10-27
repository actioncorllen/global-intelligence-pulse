// STRATELOQ-FASTMOSS-SECURE-DISCOVERY-BROKER (Stage 1 COMMERCE lane, 2nd provider)
//
// v5 — MULTI-LANE + budget gate + discovery->workspace projection (mig_310).
//   NEW_LISTED     (/product/v1/rank/newListed)    — early emergence
//   TOP_SELLING    (/product/v1/rank/topSelling)   — established demand
//   MOST_PROMOTED  (/product/v1/rank/mostPromoted) — affiliate/creator promotion momentum
// Each lane: fn_provider_budget_try_consume (hard cap) -> fn_fastmoss_discovery_request ->
// provider fetch -> fn_fastmoss_ingest_candidates_ml. After all lanes:
// fn_project_discovered_candidates makes newly discovered candidates visible WATCH decisions
// (no paid research). Lanes converge on fastmoss_product_id; country-isolated; UNKNOWN != 0.
//
// gateway verify_jwt=true; secret read only from Edge env and redacted; trusted by service role OR
// single-use nonce. Fail closed.
//
// Secret: FASTMOSS_CLIENT_SECRET (Edge Function secret only).

const SECRET_ENV = "FASTMOSS_CLIENT_SECRET";
const DEFAULT_STRATEGIES = ["NEW_LISTED", "TOP_SELLING", "MOST_PROMOTED"];
const VALID_STRATEGIES = new Set(DEFAULT_STRATEGIES);

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
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Run ONE strategy end-to-end (budget -> request -> provider -> ingest). Returns a per-lane result.
async function runStrategy(secret: string, userId: string, market: string, strategy: string, candidateLimit: number): Promise<Record<string, unknown>> {
  const reqBuild = await rpc("fn_fastmoss_discovery_request", { p_market: market, p_strategy: strategy });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    const laneStatus = reason === "UNSUPPORTED_MARKET" ? "UNSUPPORTED_MARKET"
      : reason === "UNKNOWN_OR_DISABLED_STRATEGY" ? "LANE_DISABLED" : "PROVIDER_UNAVAILABLE";
    await recordOutcome(userId, market, laneStatus, { strategy, reason });
    return { lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, lane_status: laneStatus, ok: reason === "UNSUPPORTED_MARKET" || reason === "UNKNOWN_OR_DISABLED_STRATEGY" };
  }
  const endpoint = String(rb.endpoint || "").replace(/^POST\s+/i, "").trim();

  // HARD BUDGET GATE (mig_310): if an approved call budget is active for this provider+tenant, never
  // exceed it — a refused lane makes no provider fetch, so an approved N can never become N+1 (retries
  // included). With no active budget the call proceeds and is recorded for monitoring.
  const budget = await rpc("fn_provider_budget_try_consume", { p_provider: "FASTMOSS", p_user_id: userId, p_market: market });
  const bb: any = budget.body;
  if (bb && bb.allowed === false) {
    await recordOutcome(userId, market, "BUDGET_EXCEEDED", { strategy, reason: bb.reason });
    return { lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, lane_status: "BUDGET_EXCEEDED", ok: false, budget: bb };
  }

  let provider: Response; let providerBody: any = {};
  try {
    provider = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + secret },
      body: JSON.stringify(rb.request_body ?? {}),
    });
    providerBody = await provider.json().catch(() => ({}));
  } catch (e) {
    await recordOutcome(userId, market, "PROVIDER_UNAVAILABLE", { strategy, reason: "network_error" });
    return { lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, lane_status: "PROVIDER_UNAVAILABLE", ok: false, error: redact((e as Error).message) };
  }
  // Provider body code (0 = success) is the source of truth; HTTP may be 200 with a provider error code.
  const bodyCode = providerBody?.code;
  if (!provider.ok || (bodyCode !== undefined && bodyCode !== 0 && String(bodyCode) !== "0")) {
    const laneStatus = provider.status === 401 || provider.status === 403 || bodyCode === 403 ? "AUTH_FAILED"
      : provider.status === 402 ? "PAYMENT_REQUIRED"
      : provider.status === 429 ? "RATE_LIMITED"
      : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await recordOutcome(userId, market, laneStatus, { strategy, http_status: provider.status, body_code: bodyCode });
    return { lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, lane_status: laneStatus, ok: false, http_status: provider.status, body_code: bodyCode };
  }

  const products = extractProducts(providerBody);
  const usage = extractUsage(providerBody);
  const ingest = await rpc("fn_fastmoss_ingest_candidates_ml", {
    p_user_id: userId, p_market: market, p_run_id: null, p_candidate_limit: candidateLimit,
    p_products: products, p_dry_run: false, p_strategy: strategy,
  });
  const ib: any = ingest.body;
  if (!ingest.ok || !ib) {
    await recordOutcome(userId, market, "FAILED", { strategy, reason: "ingest_failed" });
    return { lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, lane_status: "FAILED", ok: false, error: redact(ib ?? "ingest_failed") };
  }
  if (!ib.run_id && ib.status) await recordOutcome(userId, market, String(ib.status), { strategy, scanned: ib.scanned ?? 0, raw_candidate_count: products.length });
  if (usage && ib.run_id) { try { await rpc("fn_kalodata_record_usage", { p_run_id: ib.run_id, p_usage: usage, p_endpoint: endpoint }); } catch (_e) { /* best-effort */ } }

  return {
    lane: "COMMERCE", discovery_lane: strategy, provider: "FASTMOSS", market, ok: true,
    lane_status: ib.status ?? "FAILED", raw_candidate_count: products.length,
    scanned: ib.scanned ?? null, qualified: ib.qualified ?? null, promoted_count: ib.promoted_count ?? 0,
    new_dispatched: ib.new_dispatched ?? 0, branded_review: ib.branded_review ?? 0,
    correlated: ib.correlated ?? 0, idempotent: ib.idempotent ?? 0,
    run_id: ib.run_id ?? null, promoted: ib.promoted ?? [], skipped: ib.skipped ?? [], provider_usage: usage,
  };
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
  const userId = String(payload.user_id ?? payload.userId ?? "").trim();
  const candidateLimit = Math.max(1, Math.min(Number(payload.candidate_limit ?? 10) || 10, 10));
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });
  if (!secret) {
    await recordOutcome(userId, market, "AUTH_FAILED", { reason: "server_secret_unavailable" });
    return jsonResponse(424, { ok: false, lane: "COMMERCE", provider: "FASTMOSS", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the FASTMOSS_CLIENT_SECRET Edge Function secret." });
  }

  // Which lanes to run: caller override (budget control) or all three distinct ranking lanes.
  let strategies: string[] = Array.isArray(payload.strategies) && payload.strategies.length > 0
    ? payload.strategies.map((x: unknown) => String(x).trim().toUpperCase()).filter((x: string) => VALID_STRATEGIES.has(x))
    : DEFAULT_STRATEGIES.slice();
  if (strategies.length === 0) strategies = DEFAULT_STRATEGIES.slice();

  const lanes: Record<string, unknown>[] = [];
  for (let i = 0; i < strategies.length; i++) {
    if (i > 0) await sleep(400); // pace provider calls (rate-limit courtesy); lanes are independent
    lanes.push(await runStrategy(secret, userId, market, strategies[i], candidateLimit));
  }

  const anyOk = lanes.some((l) => l.ok === true);
  const totals = lanes.reduce((a: any, l: any) => ({
    promoted_count: a.promoted_count + (Number(l.promoted_count) || 0),
    new_dispatched: a.new_dispatched + (Number(l.new_dispatched) || 0),
    idempotent: a.idempotent + (Number(l.idempotent) || 0),
    correlated: a.correlated + (Number(l.correlated) || 0),
  }), { promoted_count: 0, new_dispatched: 0, idempotent: 0, correlated: 0 });

  // DISCOVERY -> WORKSPACE (mig_310): turn newly discovered, registered candidates into visible WATCH
  // decisions right away (no paid research; suppress_dispatch enforced server-side). Country-isolated;
  // existing decisions are left untouched. Closes the gap where ingested products were invisible until
  // the weekly Monday refresh.
  let projection: unknown = null;
  if (anyOk) {
    try {
      const pr = await rpc("fn_project_discovered_candidates", { p_tenant: userId, p_market: market, p_freshness_hours: 168 });
      projection = pr.body;
    } catch (_e) { projection = { status: "projection_error" }; }
  }

  return jsonResponse(200, {
    ok: anyOk, lane: "COMMERCE", provider: "FASTMOSS", market, mode: "multi_lane",
    lanes_run: strategies, lane_results: lanes, totals, projection,
    note: "Three distinct source-attributed FastMoss ranking lanes; one zero/unavailable lane never stops the others; candidates only, never opportunity; country-isolated; UNKNOWN != 0. Newly discovered candidates are projected to WATCH decisions (no paid research).",
    contract: "pulse_fastmoss_multi_lane_discovery_v2",
  });
});
