// STRATELOQ-KALODATA-CREDIT-BALANCE-BROKER (read-only)
//
// Purpose (BE313): a SECURE, SERVER-SIDE, READ-ONLY path to the Kalodata credit endpoints so the
// provider-side balance and charge logs can be reconciled WITHOUT any chargeable call. This function
// can ONLY reach two hard-coded credit endpoints:
//   * GET  /openapi/v1/credit/balance
//   * POST /openapi/v1/credit/logs
// There is NO code path to product/detail, product/rank or any other (chargeable) endpoint — the
// endpoint URLs are constants, not caller-supplied.
//
// Auth to Kalodata: canonical X-API-Key header ONLY (official guidance, Andrew Lin 2026-11-20), key from
// KALODATA_API_KEY (preferred) else KALODATA_SECRET_KEY. The key is read from env only; it is NEVER
// logged, returned, or echoed (every outbound response is passed through redact()).
// Gate: service_role OR a single-use x-pulse-nonce (fn_kalodata_consume_invoke_nonce) — identical to the
// product-detail broker, so no new trust surface. verify_jwt=true at the gateway.

const SECRET_ENV = "KALODATA_SECRET_KEY";
const API_KEY_ENV = "KALODATA_API_KEY";
const AUTH_HEADER = "X-API-Key";
// Hard-coded, non-chargeable credit endpoints ONLY. Not caller-overridable.
const BALANCE_URL = "https://www.kalodata.com/openapi/v1/credit/balance";
const LOGS_URL = "https://www.kalodata.com/openapi/v1/credit/logs";

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
  return s;
}
// Redacted JSON round-trip so a provider response can be returned safely (strips any accidental key echo).
function safeJson(body: unknown): unknown {
  try { return JSON.parse(redact(JSON.stringify(body ?? null))); } catch { return { note: "unserialisable" }; }
}
function kalodataKey(): string {
  const preferred = (Deno.env.get(API_KEY_ENV) ?? "").trim();
  return preferred.length > 0 ? preferred : (Deno.env.get(SECRET_ENV) ?? "").trim();
}
function kalodataAuthHeaders(key: string): Record<string, string> {
  return { [AUTH_HEADER]: key };
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

async function getBalance(key: string): Promise<{ http_status: number; ok: boolean; body: unknown }> {
  const r = await fetch(BALANCE_URL, { method: "GET", headers: { ...kalodataAuthHeaders(key) } });
  const body = await r.json().catch(() => ({}));
  return { http_status: r.status, ok: r.ok, body: safeJson(body) };
}
async function getLogs(key: string, logsBody: unknown): Promise<{ http_status: number; ok: boolean; body: unknown }> {
  const r = await fetch(LOGS_URL, { method: "POST", headers: { "content-type": "application/json", ...kalodataAuthHeaders(key) }, body: JSON.stringify(logsBody ?? {}) });
  const body = await r.json().catch(() => ({}));
  return { http_status: r.status, ok: r.ok, body: safeJson(body) };
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

  const key = kalodataKey();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", secret_present: Boolean(key) });
  if (!key) return jsonResponse(424, { ok: false, provider: "KALODATA", error: "server_secret_unavailable", note: "Set KALODATA_API_KEY (preferred) or KALODATA_SECRET_KEY." });

  // op: 'balance' | 'logs' | (default) 'both'. Only the two hard-coded credit endpoints are reachable.
  const op = String(payload.op ?? "both").trim().toLowerCase();
  const logsBody = (payload.logs_body && typeof payload.logs_body === "object" && !Array.isArray(payload.logs_body)) ? payload.logs_body : {};
  const out: Record<string, unknown> = { ok: true, provider: "KALODATA", mode: op, read_only: true, endpoints: { balance: BALANCE_URL, logs: LOGS_URL } };
  try {
    if (op === "balance" || op === "both") out.balance = await getBalance(key);
    if (op === "logs" || op === "both") out.logs = await getLogs(key, logsBody);
  } catch (e) {
    return jsonResponse(502, { ok: false, provider: "KALODATA", error: redact((e as Error).message).slice(0, 300) });
  }
  return jsonResponse(200, out);
});
