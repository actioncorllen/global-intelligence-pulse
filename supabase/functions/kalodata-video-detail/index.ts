// STRATELOQ-KALODATA-VIDEO-DETAIL-BROKER (PROPOSED — NOT DEPLOYED)
//
// Phase 8 draft. Fetches video/detail (documented contract) and persists RESEARCH-ONLY video metrics via
// fn_persist_kalodata_video_detail (product_number kept as a COUNT; sales_volumn spelling preserved).
// Mirrors kalodata-discovery; reuses secret-key auth + KALODATA_SECRET_KEY, service_role/nonce gate, market
// gate, usage accounting. No video media / playback URL is fetched or stored. Not deployed; no call here.

const SECRET_ENV = "KALODATA_SECRET_KEY";
const SECRET_HEADER_ENV = "KALODATA_SECRET_HEADER";
const DETAIL_BASE_ENV = "KALODATA_VIDEO_DETAIL_BASE_URL";
const DEFAULT_ENDPOINT = "https://www.kalodata.com/openapi/v1/tiktok/video/detail";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const v = Deno.env.get(SECRET_ENV);
  if (v && v.length > 0) { s = s.split(v).join("[REDACTED]"); const t = v.trim(); if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]"); }
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
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", apikey: svc, authorization: "Bearer " + svc }, body: JSON.stringify(args) });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}
function extractDetail(body: any): any | null {
  for (const p of [body?.data, body?.data?.detail, body?.result, body?.detail, body]) {
    if (p && typeof p === "object" && !Array.isArray(p) && p.video_id) return p;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  let trusted = isTrustedServer(req);
  if (!trusted) {
    const nonce = req.headers.get("x-pulse-nonce");
    if (nonce && nonce.length >= 32) { try { const nr = await rpc("fn_kalodata_consume_invoke_nonce", { p_token: nonce }); trusted = nr.ok && (nr.body === true || nr.body === "true"); } catch { trusted = false; } }
  }
  if (!trusted) return jsonResponse(403, { ok: false, error: "forbidden_requires_service_role_or_valid_nonce" });

  let payload: any = {};
  const raw = await req.text();
  if (raw && raw.trim().length > 0) { try { payload = JSON.parse(raw); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); } }
  const secret = (Deno.env.get(SECRET_ENV) ?? "").trim();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", secret_present: Boolean(secret) });

  const market = String(payload.market ?? "").trim().toUpperCase();
  const userId = String(payload.user_id ?? payload.userId ?? "").trim();
  const videoId = String(payload.video_id ?? "").trim();
  const refreshRequestId: string | null = String(payload.refresh_request_id ?? "").trim() || null;
  const settle = async (outcome: string): Promise<void> => {
    if (!refreshRequestId) return;
    try { await rpc("fn_kalodata_op_complete_from_edge", { p_request_id: refreshRequestId, p_outcome: outcome }); } catch (_e) { /* reconcile sweep is the backstop */ }
  };
  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!userId) return jsonResponse(400, { ok: false, error: "missing_user_id" });
  if (!videoId) return jsonResponse(400, { ok: false, error: "missing_video_id" });
  if (!secret) { await settle("PROVIDER_FAILED_PRE_CHARGE"); return jsonResponse(424, { ok: false, provider: "KALODATA", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable" }); }

  const reqBuild = await rpc("fn_kalodata_video_detail_request", { p_market: market, p_video_id: videoId });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    await settle("PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: false, provider: "KALODATA", market, lane_status: reason });
  }
  const endpoint = (Deno.env.get(DETAIL_BASE_ENV) || DEFAULT_ENDPOINT).trim();
  const secretHeader = (Deno.env.get(SECRET_HEADER_ENV) || "secret-key").trim();

  let provider: Response; let providerBody: any = {};
  try { provider = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json", [secretHeader]: secret }, body: JSON.stringify(rb.request_body ?? {}) }); providerBody = await provider.json().catch(() => ({})); }
  catch (e) { await settle("PROVIDER_FAILED_POST_CHARGE"); return jsonResponse(502, { ok: false, provider: "KALODATA", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) }); }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED" : provider.status === 402 ? "PAYMENT_REQUIRED" : provider.status === 429 ? "RATE_LIMITED" : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await settle("PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, provider: "KALODATA", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const detail = extractDetail(providerBody);
  if (!detail) { await settle("PROVIDER_FAILED_POST_CHARGE"); return jsonResponse(502, { ok: false, provider: "KALODATA", market, lane_status: "EMPTY_DETAIL" }); }

  const persist = await rpc("fn_persist_kalodata_video_detail", { p_tenant: userId, p_market: market, p_detail: detail });
  const pb: any = persist.body;
  if (!persist.ok || !pb || pb.ok !== true) { await settle("PROVIDER_FAILED_POST_CHARGE"); return jsonResponse(502, { ok: false, provider: "KALODATA", market, lane_status: "PERSIST_FAILED", error: redact(pb ?? "persist_failed") }); }

  try {
    const lane = await rpc("fn_kalodata_record_lane_outcome", { p_user_id: userId, p_market: market, p_lane_status: "SUCCESS_VIDEO_DETAIL", p_detail: { operation: "tiktok/video/detail", video_id: videoId } });
    const runId = (lane.body as any)?.run_id ?? null;
    if (runId) await rpc("fn_kalodata_record_usage", { p_run_id: runId, p_usage: { provider: "KALODATA", operation: "tiktok/video/detail", tenant_id: userId, country: market, call_count: 1, http_status: provider.status, recorded_by: "kalodata-video-detail-edge", recorded_at: new Date().toISOString() }, p_endpoint: endpoint });
  } catch (_e) { /* best-effort */ }

  await settle("SUCCESS");
  return jsonResponse(200, { ok: true, provider: "KALODATA", market, lane_status: "SUCCESS_VIDEO_DETAIL", video_id: videoId, rights_state: "RESEARCH_ONLY", persist: pb });
});
