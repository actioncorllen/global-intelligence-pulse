// STRATELOQ-KALODATA-SECURE-DISCOVERY-BROKER (Stage 1 COMMERCE lane)
// v26 PATCH (2026-11-20, balance read): extractBalance gains a generic fallback (any numeric
// balance/credit/amount/remain* field inside the data envelope), and balance_probe reports the
// data envelope's key NAMES (data_keys; names only, never values beyond the numeric balance).
// Auth verified live on the FREE credit/balance endpoint with the new key: BALANCE_OK, 501 resolved.
// v24 PATCH (2026-11-20, AUTH FIX per Kalodata official guidance — Andrew Lin, 2026-11-20):
// ROOT CAUSE of provider code 501 "The key is not allowed": the broker authenticated with a
// "secret-key" request header. Kalodata's canonical authentication is the X-API-Key header; a
// non-empty secret-key header overrides X-API-Key at the provider and is rejected for the current
// account key. FIX (auth only — nothing else changed):
//   (1) CANONICAL AUTH: the key is sent in the X-API-Key header ONLY. No secret-key (or any other
//       conflicting) authentication header is ever attached. The KALODATA_SECRET_HEADER env override
//       is retired (ignored) so a stale setting can never reintroduce the conflicting header.
//   (2) KEY SELECTION: KALODATA_API_KEY (preferred, current-generation slot) else KALODATA_SECRET_KEY.
//       Key values are never logged, returned or exported; redaction covers both slots.
//   (3) FREE VERIFICATION: a trusted-only "balance_probe" mode calls the FREE credit/balance endpoint
//       (GET /openapi/v1/credit/balance, 0 credits) with the canonical headers, classifies HTTP-200
//       provider logical errors correctly, and reports the live balance + safe diagnostics
//       (provider code/msg, endpoint, header NAME, key length, masked first/last 4 — never the key).
//   (4) PROBE DIAGNOSTICS: the existing trusted-only probe additionally reports which env slots are
//       present, the selected slot, key length and masked first/last 4. No full key material anywhere.
// v23 PATCH (2026-11-18, diagnosis fix): (1) broaden extractProducts to more provider shapes (data.data/records/
// items/pageData/result.data), so valid products under a different nesting are not silently dropped; (2) detect a
// PROVIDER LOGICAL ERROR returned as HTTP 200 (non-success code / success:false) and return lane_status
// PROVIDER_LOGICAL_ERROR instead of SUCCESS_ZERO_CANDIDATES; (3) record a REDACTED diagnostic (provider code, msg,
// top-level keys, extracted count, http status, page) via the existing lane-outcome telemetry on every zero/error
// response — NO credentials, NO raw product data. Success path (products found) is byte-for-byte unchanged.
// Everything else (trusted-server/nonce gate, secret only from Edge env, budget/caps upstream, refresh callback)
// is unchanged from v22.

const DEFAULT_ENDPOINT = "https://www.kalodata.com/openapi/v1/tiktok/product/rank";
const DEFAULT_BALANCE_ENDPOINT = "https://www.kalodata.com/openapi/v1/credit/balance";
const SECRET_ENV = "KALODATA_SECRET_KEY";
const API_KEY_ENV = "KALODATA_API_KEY";
const AUTH_HEADER = "X-API-Key";
const BASE_URL_ENV = "KALODATA_BASE_URL";
const BALANCE_URL_ENV = "KALODATA_BALANCE_URL";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  for (const envName of [API_KEY_ENV, SECRET_ENV]) {
    const v = Deno.env.get(envName);
    if (v && v.length > 0) {
      s = s.split(v).join("[REDACTED]");
      const t = v.trim();
      if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]");
    }
  }
  s = s.replace(/("?(?:secret[_-]?key|api[_-]?key|access_token|authorization)"?\s*[:=]\s*)("?(?:Bearer\s+)?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
}
// v24 CANONICAL KALODATA AUTH (official guidance, 2026-11-20):
// X-API-Key ONLY — never attach a secret-key or any other auth header beside it (a non-empty
// secret-key header overrides X-API-Key at the provider → 501 "The key is not allowed").
function kalodataKey(): { key: string; source: string } {
  const preferred = (Deno.env.get(API_KEY_ENV) ?? "").trim();
  if (preferred.length > 0) return { key: preferred, source: API_KEY_ENV };
  return { key: (Deno.env.get(SECRET_ENV) ?? "").trim(), source: SECRET_ENV };
}
function kalodataAuthHeaders(key: string): Record<string, string> {
  return { [AUTH_HEADER]: key };
}
function keyMask(key: string): string | null {
  return key.length >= 12 ? key.slice(0, 4) + "..." + key.slice(-4) : null;
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
  for (const path of [body?.data, body?.data?.list, body?.data?.rows, body?.data?.products, body?.data?.data,
    body?.data?.items, body?.data?.records, body?.data?.pageData, body?.result, body?.result?.list,
    body?.result?.data, body?.list, body?.products, body?.rows, body?.items, body?.records, body?.pageData]) {
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
function extractBalance(body: any): number | null {
  for (const c of [body?.data?.balance, body?.data?.credit, body?.data?.credits, body?.data?.remaining_credit,
    body?.balance, body?.credit, body?.credits, (typeof body?.data === "number" ? body.data : undefined)]) {
    if (c !== undefined && c !== null) { const n = Number(c); if (Number.isFinite(n)) return n; }
  }
  // v26 fallback: any numeric balance-like field inside the data envelope (names vary across providers).
  const d = body?.data;
  if (d && typeof d === "object" && !Array.isArray(d)) {
    for (const k of Object.keys(d)) {
      if (/balance|credit|amount|remain/i.test(k)) {
        const n = Number((d as Record<string, unknown>)[k]);
        if ((d as Record<string, unknown>)[k] !== null && Number.isFinite(n)) return n;
      }
    }
  }
  return null;
}
const PROVIDER_SUCCESS_CODES: any[] = [0, "0", 200, "200", "success", "SUCCESS", "ok", "OK", true, "0000", "00000"];
function providerCode(body: any): any { return body?.code ?? body?.status ?? body?.statusCode ?? body?.ret ?? null; }
function providerMsg(body: any): any { return body?.msg ?? body?.message ?? body?.error ?? body?.errmsg ?? null; }
function looksLikeProviderError(body: any): boolean {
  const code = providerCode(body);
  return (code !== null && !PROVIDER_SUCCESS_CODES.includes(code)) || body?.success === false;
}
function topLevelKeys(body: any): string[] {
  return (body && typeof body === "object" && !Array.isArray(body)) ? Object.keys(body).slice(0, 15) : [];
}
async function recordOutcome(userId: string, market: string, laneStatus: string, detail: Record<string, unknown>): Promise<void> {
  if (!userId) return;
  try { await rpc("fn_kalodata_record_lane_outcome", { p_user_id: userId, p_market: market, p_lane_status: laneStatus, p_detail: detail }); } catch (_e) { /* telemetry best-effort */ }
}

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

  const { key: secret, source: secretSource } = kalodataKey();
  if (payload.probe === true) {
    // Trusted-only (service_role / single-use nonce gate above). Safe diagnostics only — never key material.
    return jsonResponse(200, {
      ok: true, mode: "probe", secret_present: Boolean(secret),
      auth_header: AUTH_HEADER, key_env: secretSource, key_length: secret.length, key_mask: keyMask(secret),
      env_present: {
        KALODATA_API_KEY: (Deno.env.get(API_KEY_ENV) ?? "").trim().length > 0,
        KALODATA_SECRET_KEY: (Deno.env.get(SECRET_ENV) ?? "").trim().length > 0,
        KALODATA_SECRET_HEADER: (Deno.env.get("KALODATA_SECRET_HEADER") ?? "").trim().length > 0,
      },
      // NAMES only (never values): rules out a current key sitting in a differently-named slot.
      kalodata_env_names: Object.keys(Deno.env.toObject()).filter((n) => n.toUpperCase().startsWith("KALODATA")).sort(),
      note: "KALODATA_SECRET_HEADER is retired and ignored: canonical auth is the X-API-Key header only.",
    });
  }

  // v24 FREE VERIFICATION MODE (trusted-only): GET credit/balance — 0 credits, no Product Rank call.
  if (payload.balance_probe === true) {
    // Optional trusted-only diagnostic: test a NAMED KALODATA* env slot on the FREE endpoint
    // (selects which configured secret to try; the value is never logged or returned).
    let probeSecret = secret, probeSource = secretSource;
    if (typeof payload.key_env === "string" && /^KALODATA[A-Z0-9_]*$/.test(payload.key_env)) {
      const v = (Deno.env.get(payload.key_env) ?? "").trim();
      if (v.length > 0) { probeSecret = v; probeSource = payload.key_env; }
      else return jsonResponse(424, { ok: false, mode: "balance_probe", lane_status: "AUTH_FAILED", error: "requested_key_env_empty", key_env: payload.key_env });
    }
    if (!secret) {
      return jsonResponse(424, { ok: false, mode: "balance_probe", lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the KALODATA_API_KEY (preferred) or KALODATA_SECRET_KEY Edge Function secret for project nxaunmyihhjixxxljcqt." });
    }
    const balEndpoint = (Deno.env.get(BALANCE_URL_ENV) || DEFAULT_BALANCE_ENDPOINT).trim();
    const requestedAt = new Date().toISOString();
    let r: Response; let b: any = {};
    try {
      r = await fetch(balEndpoint, { method: "GET", headers: kalodataAuthHeaders(probeSecret) });
      b = await r.json().catch(() => ({}));
    } catch (e) {
      return jsonResponse(502, { ok: false, mode: "balance_probe", lane_status: "PROVIDER_UNAVAILABLE", endpoint: balEndpoint, auth_header: AUTH_HEADER, requested_at: requestedAt, error: redact((e as Error).message) });
    }
    const code = providerCode(b);
    const msgRaw = providerMsg(b);
    const logicalError = looksLikeProviderError(b);
    const ok = r.ok && !logicalError;
    return jsonResponse(ok ? 200 : 502, {
      ok, mode: "balance_probe",
      lane_status: ok ? "BALANCE_OK" : (r.ok ? "PROVIDER_LOGICAL_ERROR" : "FAILED"),
      endpoint: balEndpoint, auth_header: AUTH_HEADER, key_env: probeSource, key_length: probeSecret.length, key_mask: keyMask(probeSecret),
      http_status: r.status, provider_code: code == null ? null : String(code).slice(0, 24),
      provider_msg: msgRaw == null ? null : redact(String(msgRaw)).slice(0, 160),
      balance: extractBalance(b), top_level_keys: topLevelKeys(b),
      data_keys: (b?.data && typeof b.data === "object" && !Array.isArray(b.data)) ? Object.keys(b.data).slice(0, 15) : null,
      requested_at: requestedAt,
      request_id: r.headers.get("x-request-id") ?? r.headers.get("request-id") ?? r.headers.get("x-trace-id") ?? null,
      cost_note: "credit/balance is a FREE endpoint; no Product Rank call was made.",
    });
  }

  const market = String(payload.market ?? "").trim().toUpperCase();
  const userId = String(payload.user_id ?? payload.userId ?? "").trim();
  const candidateLimit = Math.max(1, Math.min(Number(payload.candidate_limit ?? 10) || 10, 25));
  const pageNumber = Math.max(1, Number(payload.page_number ?? 1) || 1);
  const refreshRequestId: string | null = (typeof payload.refresh_request_id === "string" && payload.refresh_request_id.trim().length > 0)
    ? payload.refresh_request_id.trim() : null;
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });

  if (!secret) {
    await recordOutcome(userId, market, "AUTH_FAILED", { reason: "server_secret_unavailable" });
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(424, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable", note: "Set the KALODATA_API_KEY (preferred) or KALODATA_SECRET_KEY Edge Function secret for project nxaunmyihhjixxxljcqt." });
  }

  const reqBuild = await rpc("fn_kalodata_discovery_request", { p_market: market, p_page_number: pageNumber });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    const laneStatus = reason === "UNSUPPORTED_MARKET" ? "UNSUPPORTED_MARKET" : "PROVIDER_UNAVAILABLE";
    await recordOutcome(userId, market, laneStatus, { reason });
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: reason === "UNSUPPORTED_MARKET", lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus });
  }
  const endpoint = (Deno.env.get(BASE_URL_ENV) || DEFAULT_ENDPOINT).trim();

  let provider: Response;
  let providerBody: any = {};
  try {
    provider = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", ...kalodataAuthHeaders(secret) },
      body: JSON.stringify(rb.request_body ?? {}),
    });
    providerBody = await provider.json().catch(() => ({}));
  } catch (e) {
    await recordOutcome(userId, market, "PROVIDER_UNAVAILABLE", { reason: "network_error" });
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) });
  }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED"
      : provider.status === 402 ? "PAYMENT_REQUIRED"
      : provider.status === 429 ? "RATE_LIMITED"
      : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await recordOutcome(userId, market, laneStatus, { http_status: provider.status });
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const products = extractProducts(providerBody);
  const usage = extractUsage(providerBody);

  const provCode = providerCode(providerBody);
  const provMsgRaw = providerMsg(providerBody);
  const provMsg = provMsgRaw == null ? null : redact(provMsgRaw);
  const provKeys = topLevelKeys(providerBody);
  const dataKeys = (providerBody?.data && typeof providerBody.data === "object" && !Array.isArray(providerBody.data)) ? Object.keys(providerBody.data).slice(0, 15) : [];
  if (products.length === 0) {
    await recordOutcome(userId, market, "ZERO_OR_ERROR_DIAG", {
      http_status: provider.status, provider_code: provCode, provider_msg: provMsg,
      top_level_keys: provKeys, data_keys: dataKeys, extracted_count: 0, page_number: pageNumber,
      note: "redacted diagnostic: provider HTTP 200 but 0 products extracted (provider logical error or genuine empty or shape mismatch)",
    });
  }
  if (products.length === 0 && looksLikeProviderError(providerBody)) {
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(502, {
      ok: false, lane: "COMMERCE", provider: "KALODATA", market, page_number: pageNumber,
      lane_status: "PROVIDER_LOGICAL_ERROR", http_status: provider.status,
      provider_code: provCode, provider_msg: provMsg, top_level_keys: provKeys, data_keys: dataKeys,
      note: "Kalodata returned HTTP 200 with a non-success provider code / success:false; treated as an error, not zero candidates.",
    });
  }

  const ingest = await rpc("fn_kalodata_ingest_candidates", {
    p_user_id: userId, p_market: market, p_run_id: null, p_candidate_limit: candidateLimit, p_products: products, p_dry_run: false,
    p_suppress_auto_research: refreshRequestId !== null,
  });
  const ib: any = ingest.body;
  if (!ingest.ok || !ib) {
    await recordOutcome(userId, market, "FAILED", { reason: "ingest_failed" });
    await completeRefresh(refreshRequestId, [], 0, "PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(502, { ok: false, lane: "COMMERCE", provider: "KALODATA", market, lane_status: "FAILED", error: redact(ib ?? "ingest_failed") });
  }

  if (!ib.run_id && ib.status) {
    await recordOutcome(userId, market, String(ib.status), { scanned: ib.scanned ?? 0, raw_candidate_count: products.length });
  }

  if (ib.run_id) {
    try {
      await rpc("fn_kalodata_record_usage", {
        p_run_id: ib.run_id,
        p_usage: {
          provider: "KALODATA", operation: "tiktok/product/rank", tenant_id: userId, country: market,
          page_number: pageNumber, call_count: 1, http_status: provider.status, response_status: ib.status ?? null,
          cost_field_present: usage !== null, provider_credit: usage, monetary_amount: null,
          relationship: refreshRequestId ? "customer_refresh" : "discovery_wave", refresh_request_id: refreshRequestId,
          recorded_by: "kalodata-discovery-edge", recorded_at: new Date().toISOString(),
        },
        p_endpoint: endpoint,
      });
    } catch (_e) { /* usage telemetry is best-effort; never fail discovery on it */ }
  }

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
