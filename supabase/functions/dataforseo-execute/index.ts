// STRATELOQ — DATAFORSEO-EXECUTE — budget-enforcing sole-chokepoint executor for chargeable DataForSEO.
//
// WHY THIS EXISTS (GPD.06 spend-security completion, 2026-11-24):
// Every prior DataForSEO path lived in n8n with an HTTP Basic credential. n8n cannot bind a credential to
// one workflow, so an operator could build a fresh direct-HTTP workflow and skip the DB budget authoriser.
// This edge function is the single server-side pathway that is meant to HOLD the provider credential (as
// edge secrets, NOT in n8n). It fail-closes through the EXISTING DB authoriser (fn_dataforseo_pilot_consume)
// before any provider call, and reconciles the actual provider cost afterward (fn_dataforseo_merchant_record_cost).
// It introduces NO new budget system or ledger — it reuses research_budget_config + provider_call_budget +
// dataforseo_merchant_dispatch exactly as the n8n gate did.
//
// ENFORCED BOUNDARY (all three must pass before a single provider request is made):
//   1. DATAFORSEO_EXECUTOR_TOKEN present AND x-executor-token header matches it  (unset => ALL dispatch 401)
//   2. DATAFORSEO_LOGIN + DATAFORSEO_PASSWORD present                            (unset => 503 BEFORE consume)
//   3. fn_dataforseo_pilot_consume(...) returns authorized=true                  (default config => PAID_DISABLED)
// The provider fetch() below is lexically unreachable unless (3) authorises. Budget is consumed atomically
// (idempotency-key claim + FOR UPDATE provider-budget), so retries/concurrency can never exceed approval.
//
// PROBE (read-only): {"probe":true,...} returns the live gate decision via fn_dataforseo_pilot_preauthorize.
// It never authenticates, never reads the provider credential, never consumes budget, never calls the provider.
//
// SECRETS are env-only; never logged, never returned. verify_jwt=false (own token gate, like billing-webhook).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EXECUTOR_TOKEN = Deno.env.get("DATAFORSEO_EXECUTOR_TOKEN") ?? "";
const DFS_LOGIN = Deno.env.get("DATAFORSEO_LOGIN") ?? "";
const DFS_PASSWORD = Deno.env.get("DATAFORSEO_PASSWORD") ?? "";

const GLOBAL_TENANT = "00000000-0000-4000-8000-000000000001"; // fn_global_intelligence_uid()

// Whitelisted chargeable operations -> {provider_code (matches authoriser), endpoint}. Nothing else dispatches.
const OPS: Record<string, { provider: string; url: string }> = {
  SEARCH_VOLUME:      { provider: "DATAFORSEO_SEARCH_VOLUME", url: "https://api.dataforseo.com/v3/keywords_data/google_ads/search_volume/task_post" },
  SEARCH_VOLUME_LIVE: { provider: "DATAFORSEO_SEARCH_VOLUME", url: "https://api.dataforseo.com/v3/keywords_data/google_ads/search_volume/live" },
  MERCHANT_PRODUCTS:  { provider: "DATAFORSEO_MERCHANT",       url: "https://api.dataforseo.com/v3/merchant/google/products/task_post" },
  SELLERS:            { provider: "DATAFORSEO_SELLERS",        url: "https://api.dataforseo.com/v3/merchant/google/sellers/task_post" },
};

function J(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

// Call a public RPC as service_role (RLS bypassed). Returns the function's jsonb result.
async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  let j: unknown = null;
  try { j = t ? JSON.parse(t) : null; } catch { j = t; }
  if (!r.ok) throw new Error(`rpc ${fn} ${r.status}`);
  return j;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return J(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return J(400, { ok: false, reason: "BAD_JSON" }); }

  const operation = String(b?.operation ?? "").toUpperCase().trim();
  const market = String(b?.market ?? "").toUpperCase().trim();
  const op = OPS[operation];
  if (!op) return J(400, { ok: false, reason: "UNKNOWN_OPERATION", operation });
  if (!market) return J(400, { ok: false, reason: "MARKET_REQUIRED" });
  const tenant = (typeof b?.tenant_id === "string" && b.tenant_id) ? b.tenant_id as string : GLOBAL_TENANT;

  // ---------- READ-ONLY PROBE: no auth, no secret, no spend, never calls the provider ----------
  if (b?.probe === true) {
    try {
      const gate = await rpc("fn_dataforseo_pilot_preauthorize",
        { p_user_id: tenant, p_market: market, p_operation_code: operation, p_provider_code: op.provider });
      return J(200, { ok: true, probe: true, operation, market, provider: op.provider, gate });
    } catch (e) {
      return J(502, { ok: false, probe: true, reason: "PROBE_RPC_ERROR", detail: String(e) });
    }
  }

  // ---------- GATE 1: executor token (unset token => all dispatch refused, fail-closed) ----------
  const token = req.headers.get("x-executor-token") ?? "";
  if (!EXECUTOR_TOKEN || token !== EXECUTOR_TOKEN) {
    return J(401, { ok: false, reason: "EXECUTOR_TOKEN_REQUIRED" });
  }

  const idem = String(b?.idempotency_key ?? "").trim();
  if (!idem) return J(400, { ok: false, reason: "IDEMPOTENCY_KEY_REQUIRED" });

  // ---------- GATE 2: provider credential present (checked BEFORE consume so a missing secret
  //            never consumes a budget slot) ----------
  if (!DFS_LOGIN || !DFS_PASSWORD) {
    return J(503, { ok: false, reason: "EXECUTOR_CREDENTIAL_UNSET",
      note: "DataForSEO credential is not configured in the edge secret store; no budget consumed, no provider call" });
  }

  // ---------- GATE 3: the single budget authoriser (fail-closed) ----------
  let auth: Record<string, unknown>;
  try {
    auth = await rpc("fn_dataforseo_pilot_consume", {
      p_user_id: tenant, p_market: market, p_operation_code: operation, p_provider_code: op.provider,
      p_request: (b?.payload ?? {}), p_idempotency_key: idem, p_keyword: (b?.keyword ?? null),
    }) as Record<string, unknown>;
  } catch (e) {
    return J(502, { ok: false, reason: "AUTHORISER_ERROR", detail: String(e) });
  }
  if (auth?.authorized !== true) {
    // Not authorised => NO provider call. Nothing was charged.
    return J(402, { ok: false, reason: (auth?.reason ?? "NOT_AUTHORIZED"), gate: auth });
  }
  // Exactly-once: a completed prior dispatch replays without re-calling the provider.
  if (auth?.idempotent_replay === true) {
    return J(200, { ok: true, idempotent_replay: true, reason: auth?.reason, idempotency_key: idem });
  }
  const projected = Number(auth?.projected_cost_micro ?? 0);

  // ---------- PROVIDER CALL (only reachable after GATE 3 authorises) ----------
  const payload = Array.isArray(b?.payload) ? b.payload : [b?.payload ?? {}];
  const basic = btoa(`${DFS_LOGIN}:${DFS_PASSWORD}`);
  let provResp: Record<string, unknown> | null = null;
  let provHttp = 0, provText = "";
  try {
    const pr = await fetch(op.url, {
      method: "POST",
      headers: { authorization: `Basic ${basic}`, "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    provHttp = pr.status;
    provText = await pr.text();
    try { provResp = JSON.parse(provText); } catch { provResp = null; }
  } catch (e) {
    // Network failure AFTER consume: record FAILED (excluded from month spend). The budget slot stays
    // consumed (fail-closed: a failed attempt can never grant extra spend). Same idempotency key replays.
    await rpc("fn_dataforseo_merchant_record_cost",
      { p_idempotency_key: idem, p_actual_cost_micro: 0, p_task_id: null, p_status: "FAILED" }).catch(() => {});
    return J(502, { ok: false, reason: "PROVIDER_NETWORK_ERROR", detail: String(e), idempotency_key: idem });
  }

  // DataForSEO envelope: status_code 20000 == OK; top-level `cost` is the actual USD charge for this call.
  const dfsOk = !!provResp && Number(provResp.status_code) === 20000;
  const costUsd = Number((provResp as Record<string, unknown>)?.cost ?? 0);
  const actualMicro = Math.max(0, Math.round((isFinite(costUsd) ? costUsd : 0) * 1_000_000));
  const tasks = (provResp as { tasks?: Array<{ id?: string }> } | null)?.tasks;
  const taskId = Array.isArray(tasks) && tasks[0]?.id ? String(tasks[0].id) : null;
  const recStatus = dfsOk ? (operation === "SEARCH_VOLUME_LIVE" ? "INGESTED" : "SUBMITTED") : "FAILED";

  // ---------- RECONCILE ACTUAL COST (post-dispatch) ----------
  let rec: unknown;
  try {
    rec = await rpc("fn_dataforseo_merchant_record_cost",
      { p_idempotency_key: idem, p_actual_cost_micro: actualMicro, p_task_id: taskId, p_status: recStatus });
  } catch (e) {
    rec = { ok: false, reason: "RECORD_COST_ERROR", detail: String(e) };
  }

  return J(dfsOk ? 200 : 502, {
    ok: dfsOk, operation, market, provider: op.provider, idempotency_key: idem,
    projected_cost_micro: projected, actual_cost_micro: actualMicro,
    cost_variance_micro: actualMicro - projected, cost_reconciled: rec, task_id: taskId,
    provider_status_code: (provResp as Record<string, unknown>)?.status_code ?? null,
    provider_http_status: provHttp,
    result: dfsOk ? provResp : {
      status_code: (provResp as Record<string, unknown>)?.status_code ?? null,
      status_message: (provResp as Record<string, unknown>)?.status_message ?? provText.slice(0, 300),
    },
  });
});
