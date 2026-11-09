// STRATELOQ-KALODATA-SECURE-DISCOVERY-BROKER (Stage 1 COMMERCE lane)
//
// PREPARED CHANGE — NOT deployed without founder approval (Refresh Discovery Stage B).
// Delta vs the live v12 function: OPTIONAL `refresh_request_id` in the payload. When present (a customer
// Refresh Discovery run that already RESERVED credits + AUTHORIZED one provider budget call in the DB), the
// edge threads it through and, after the single paid call + ingest, invokes the SERVICE-ROLE completion
// callback fn_discovery_refresh_complete_from_edge(request_id, new_product_ids, duplicates, outcome) so the
// request settles (SUCCESS, incl. zero-new) or refunds (any failure; beta policy). The completion reads the
// owning tenant FROM THE REQUEST ROW (never from this payload) and recomputes image-pending with the Explorer
// gate predicate, so a wrong payload can neither charge the wrong tenant nor inflate the visible count.
// When `refresh_request_id` is absent the behaviour is byte-for-byte the original v12 (normal discovery wave).
//
// IDEMPOTENCY / NO DUPLICATE PAID CALLS: one paid call per request is guaranteed upstream — authorize consumes
// exactly one provider budget unit (atomic; an approved N can never become N+1) and dispatch sets dispatched_at
// once. If this completion callback is lost, the request stays EXECUTING and the reconcile sweep refunds it as
// UNRESOLVED_POST_DISPATCH WITHOUT re-dispatching. The edge never retries the provider on its own.
// Everything else is unchanged: trusted-server/nonce gate, secret read only from Edge env, budget/caps upstream.

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
  for (const path of [body?.data, body?.data?.list, body?.data?.rows, body?.data?.products, body?.result, body?.result?.list, body?.list, body?.products, body?.rows]) {
    if (Array.isArray(path)) return path;
  }
  return [];
}
function extractUsage(body: any): Record<string, unknown> | null {
  const u: Record<string, unknown> = {};
  for (const k of ["credit", "credits", "cost", "balance", "remaining_credit", "credit_cost", "used_credit"]) {
    if (body && body[k] !== undefined) u[k] = body[k];
    if (body?.data && body.data[k] !== undefined) u[k] = body.data[k];
  }
  return Object.keys(u).length ? u : null;
}
async function recordOutcome(userId: string, market: string, laneStatus: string, detail: Record<string, unknown>): Promise<void> {
  if (!userId) return;
  try { await rpc("fn_kalodata_record_lane_outcome", { p_user_id: userId, p_market: market, p_lane_status: laneStatus, p_detail: detail }); } catch (_e) { /* telemetry best-effort */ }
}

// Refresh Discovery completion callback (only when refresh_request_id is present). Best-effort: if it fails,
// the request stays EXECUTING and the reconcile sweep refunds it later (UNRESOLVED_POST_DISPATCH), never a
// duplicate provider call. The DB function derives tenant from the request row and recomputes image-pending.
function newProductIds(ib: any): string[] {
  const promoted: any[] = Array.isArray(ib?.promoted) ? ib.promoted : [];
  return promoted.filter((p) => p && p.dedup_status === "new" && p.product_id).map((p) => String(p.product_id));
}
function duplicateCount(ib: any): number {
  const promoted: any[] = Array.isArray(ib?.promoted) ? ib.promoted : [];
  return promoted.filter((p) => p && p.dedup_status === "deduplicated").length;
}
async function completeRefresh(refreshRequestId: string | null, newIds: string[], duplicates: number, outcome: string): Promise<void> {
  if (!refreshRequestId) return;
  try {
    await rpc("fn_discovery_refresh_complete_from_edge", {
      p_request_id: refreshRequestId, p_new_product_ids: newIds, p_duplicates: duplicates, p_outcome: outcome,
    });
  } catch (_e) { /* reconcile sweep is the safety net; never fail the response on the callback */ }
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
  const candidateLimit = Math.max(1, Math.min(Number(payload.candidate_limit ?? 10) || 10, 25));
  // mig_336: explicit page number (default 1, clamp >= 1) so runs can advance pages, not re-buy page 1.
  const pageNumber = Math.max(1, Number(payload.page_number ?? 1) || 1);
  // Refresh Discovery Stage B: optional request id this run settles against. Absent => normal discovery wave.
  const refreshRequestId: string | null = (typeof payload.refresh_request_id === "string" && payload.refresh_request_id.trim().length > 0)
    ? payload.refresh_request_id.trim() : null;
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });

  if (!secret) {
    await recordOutcome(userId, market, "AUTH_FAILED", { reason: "server_secret_unavailable" });
    // no chargeable call was made -> refund (pre-charge)
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(424, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the KALODATA_SECRET_KEY Edge Function secret for project nxaunmyihhjixxxljcqt." });
  }

  // 1) seed-free request body (secret-free), for the requested page. UNSUPPORTED markets short-circuit here.
  const reqBuild = await rpc("fn_kalodata_discovery_request", { p_market: market, p_page_number: pageNumber });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    const laneStatus = reason === "UNSUPPORTED_MARKET" ? "UNSUPPORTED_MARKET" : "PROVIDER_UNAVAILABLE";
    await recordOutcome(userId, market, laneStatus, { reason });
    // failed before any chargeable call -> refund (pre-charge)
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: reason === "UNSUPPORTED_MARKET", lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus });
  }
  const endpoint = (Deno.env.get(BASE_URL_ENV) || DEFAULT_ENDPOINT).trim();
  const secretHeader = (Deno.env.get(SECRET_HEADER_ENV) || "secret-key").trim();

  // 2) provider call with the secret-key header (env only). This is the single chargeable call.
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
    // the paid call was initiated and its outcome is unknown -> post-charge (beta refund), audited
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) });
  }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED"
      : provider.status === 402 ? "PAYMENT_REQUIRED"
      : provider.status === 429 ? "RATE_LIMITED"
      : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await recordOutcome(userId, market, laneStatus, { http_status: provider.status });
    // the provider responded with an error: a call occurred -> post-charge (beta refund), audited
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const products = extractProducts(providerBody);
  const usage = extractUsage(providerBody);

  // 3) ingest. Candidate ingestion / identity resolution / de-duplication / storage / registry run normally.
  //    p_suppress_auto_research=true for a CUSTOMER Refresh Discovery run (refresh_request_id present): the
  //    per-candidate deep-research bridge (fn_auto_dispatch_candidate_research) is NOT crossed, so one refresh
  //    click cannot auto-initiate a paid FastMoss/DataForSEO/CJ research cascade. Deep research stays available
  //    only through its existing separately-authorized, budget-gated workflow. A normal discovery wave (no
  //    refresh_request_id) passes false and keeps the pre-existing auto-dispatch behaviour unchanged.
  const ingest = await rpc("fn_kalodata_ingest_candidates", {
    p_user_id: userId, p_market: market, p_run_id: null, p_candidate_limit: candidateLimit, p_products: products, p_dry_run: false,
    p_suppress_auto_research: refreshRequestId !== null,
  });
  const ib: any = ingest.body;
  if (!ingest.ok || !ib) {
    await recordOutcome(userId, market, "FAILED", { reason: "ingest_failed" });
    // the paid call succeeded but ingestion failed -> post-charge (beta refund), audited
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "FAILED", error: redact(ib ?? "ingest_failed") });
  }

  if (!ib.run_id && ib.status) {
    await recordOutcome(userId, market, String(ib.status), { scanned: ib.scanned ?? 0, raw_candidate_count: products.length });
  }

  // Provider-usage instrumentation (P2): record a usage/telemetry row for EVERY paid Kalodata call, not only
  // when the provider volunteers a cost field. The rank endpoint returns no per-call cost, so the old
  // `if (usage && ib.run_id)` guard never fired historically (0/68 runs recorded provider_usage). We now record
  // verifiable evidence only — provider, tenant, country, endpoint/operation, HTTP + lane status, call_count=1,
  // timestamp, relationship to the customer refresh — plus the provider's OWN credit fields when present, and
  // NEVER a fabricated monetary amount. `provider_credit` is the PROVIDER's metering (distinct from Strateloq
  // customer credits); the secret is never included.
  if (ib.run_id) {
    try {
      await rpc("fn_kalodata_record_usage", {
        p_run_id: ib.run_id,
        p_usage: {
          provider: "KALODATA",
          operation: "tiktok/product/rank",
          tenant_id: userId,
          country: market,
          page_number: pageNumber,
          call_count: 1,
          http_status: provider.status,
          response_status: ib.status ?? null,
          cost_field_present: usage !== null,
          provider_credit: usage,            // provider-side metering if the response carried it, else null
          monetary_amount: null,             // unknown: never inferred from an API-call count
          relationship: refreshRequestId ? "customer_refresh" : "discovery_wave",
          refresh_request_id: refreshRequestId,
          recorded_by: "kalodata-discovery-edge",
          recorded_at: new Date().toISOString(),
        },
        p_endpoint: endpoint,
      });
    } catch (_e) { /* usage telemetry is best-effort; never fail discovery on it */ }
  }

  // Refresh Discovery: a valid provider answer (including zero new) is a chargeable SUCCESS -> settle. The
  // customer-visible vs image-pending split is recomputed server-side from the NEW product ids (gate predicate).
  await completeRefresh(refreshRequestId, newProductIds(ib), duplicateCount(ib), "SUCCESS");

  return jsonResponse(200, {
    ok: true, lane: "COMMERCE", provider: "KALODATA", market, page_number: pageNumber,
    lane_status: ib.status ?? "FAILED",
    raw_candidate_count: products.length,
    scanned: ib.scanned ?? null, qualified: ib.qualified ?? null, promoted_count: ib.promoted_count ?? 0,
    run_id: ib.run_id ?? null, promoted: ib.promoted ?? [], skipped: ib.skipped ?? [],
    provider_usage: usage,
    refresh_request_id: refreshRequestId,
  });
});
