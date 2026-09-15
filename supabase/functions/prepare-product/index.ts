// ============================================================================
// Pulse — Product Preparation trigger (PULSE-009B6C)
// ----------------------------------------------------------------------------
// Authenticated, owner-scoped entry point that STARTS asynchronous merchant-
// listing preparation for one of the caller's product acquisitions. The browser
// supplies ONLY an acquisition id; ownership + eligibility are resolved server
// side, the SELECTED|PREPARE_FAILED -> PREPARING transition is authorised by the
// begin_product_preparation RPC (service_role), and the frozen acquisition
// snapshots + run-scoped Business DNA are handed to the n8n Product Preparation
// Worker for a single bounded AI generation.
//
// SECURITY: verify_jwt is disabled at the platform gate because this handler
// authenticates itself (getUser) and derives identity server-side. The service-
// role key and the n8n webhook secret are read ONLY from the Edge environment;
// they are NEVER returned to the browser. The browser can never write
// prepared_package, the state, or a user_id. No token / secret is logged.
// ============================================================================

import { createClient } from "@supabase/supabase-js";

function reqEnv(v: string | undefined, name: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new Error(`invalid prepare-product environment configuration: ${name}`);
  }
  return v;
}
const SUPABASE_URL = reqEnv(Deno.env.get("SUPABASE_URL"), "SUPABASE_URL");
const SUPABASE_ANON_KEY = reqEnv(Deno.env.get("SUPABASE_ANON_KEY"), "SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = reqEnv(
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  "SUPABASE_SERVICE_ROLE_KEY",
);
const ALLOWED_ORIGINS = reqEnv(Deno.env.get("ISSUANCE_ALLOWED_ORIGINS"), "ISSUANCE_ALLOWED_ORIGINS");
// The preparation worker URL is public (not a secret); the shared webhook secret
// (same Header Auth credential as Business Discovery) authenticates the handoff.
const N8N_PREPARE_WEBHOOK =
  Deno.env.get("N8N_PREPARE_WEBHOOK") ??
  "https://tradingb.app.n8n.cloud/webhook/pulse-product-preparation";
const PULSE_DISCOVERY_WEBHOOK_SECRET = Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";

// A PREPARING row whose last update is older than this is treated as a dropped
// handoff and re-dispatched (worker execution timeout is 120s; leave margin).
const STALE_PREPARING_MS = 5 * 60 * 1000;

const CLIENT_OPTIONS = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
} as const;
const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, CLIENT_OPTIONS);
const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CLIENT_OPTIONS);

const allowedOrigins = new Set(
  ALLOWED_ORIGINS.split(",").map((s) => s.trim()).filter((s) => s.length > 0),
);

function buildCorsHeaders(allowedOrigin: string | null): Headers {
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (allowedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", allowedOrigin);
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, apikey, x-client-info");
  }
  return headers;
}
function jsonResponse(body: object, status: number, cors: Headers): Response {
  const headers = new Headers(cors);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function dispatchWorker(payload: object): Promise<"queued" | "handoff_failed"> {
  if (N8N_PREPARE_WEBHOOK.length === 0) return "handoff_failed";
  try {
    const res = await fetch(N8N_PREPARE_WEBHOOK, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(PULSE_DISCOVERY_WEBHOOK_SECRET.length > 0
          ? { "x-pulse-webhook-secret": PULSE_DISCOVERY_WEBHOOK_SECRET }
          : {}),
      },
      body: JSON.stringify(payload),
    });
    return res.ok ? "queued" : "handoff_failed";
  } catch {
    return "handoff_failed";
  }
}

Deno.serve(async (request: Request): Promise<Response> => {
  const origin = request.headers.get("Origin");
  const allowedOrigin = origin !== null && allowedOrigins.has(origin) ? origin : null;
  const cors = buildCorsHeaders(allowedOrigin);
  if (allowedOrigin === null) {
    return jsonResponse({ ok: false, code: "forbidden_origin" }, 403, cors);
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    const headers = new Headers(cors);
    headers.set("Allow", "POST, OPTIONS");
    headers.set("Content-Type", "application/json");
    return new Response(JSON.stringify({ ok: false, code: "method_not_allowed" }), {
      status: 405,
      headers,
    });
  }

  const authHeader = request.headers.get("Authorization") ?? "";
  const bearer = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  let uid: string | null = null;
  try {
    const { data, error } = await anonClient.auth.getUser(bearer);
    if (!error && data.user) uid = data.user.id;
  } catch {
    /* fall through to 401 */
  }
  if (uid === null) {
    return jsonResponse({ ok: false, code: "authentication_required" }, 401, cors);
  }

  let body: { acquisition_id?: unknown };
  try {
    body = (await request.json()) as { acquisition_id?: unknown };
  } catch {
    return jsonResponse({ ok: false, code: "invalid_request" }, 400, cors);
  }
  const acquisitionId = typeof body?.acquisition_id === "string" ? body.acquisition_id.trim() : "";
  if (!UUID_RE.test(acquisitionId)) {
    return jsonResponse({ ok: false, code: "invalid_acquisition" }, 400, cors);
  }

  // Owner-scoped read. RLS is bypassed by the service role, so ownership is
  // enforced explicitly on user_id here — never trust a browser-supplied owner.
  const acqQuery = await serviceClient
    .from("product_acquisitions")
    .select(
      "id, state, updated_at, source_run_id, winning_product_snapshot, selected_supplier_snapshot, sourcing_spec_snapshot",
    )
    .eq("id", acquisitionId)
    .eq("user_id", uid)
    .maybeSingle();
  if (acqQuery.error) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }
  if (!acqQuery.data) {
    return jsonResponse({ ok: false, code: "not_found" }, 404, cors);
  }
  const acq = acqQuery.data as {
    id: string;
    state: string;
    updated_at: string | null;
    source_run_id: string | null;
    winning_product_snapshot: unknown;
    selected_supplier_snapshot: unknown;
    sourcing_spec_snapshot: unknown;
  };

  // Terminal / already-advanced states short-circuit without spending a run.
  if (acq.state === "READY_FOR_REVIEW") {
    return jsonResponse({ ok: true, status: "ready" }, 200, cors);
  }
  if (acq.state !== "SELECTED" && acq.state !== "PREPARE_FAILED" && acq.state !== "PREPARING") {
    return jsonResponse({ ok: false, code: "not_eligible", state: acq.state }, 409, cors);
  }

  // Build the run-scoped Business DNA context from the acquisition's OWN source
  // run (never the latest unrelated discovery), tenant-checked on user_id.
  let businessDna: unknown = {};
  if (acq.source_run_id) {
    const runQuery = await serviceClient
      .from("discovery_runs")
      .select("raw_contract")
      .eq("id", acq.source_run_id)
      .eq("user_id", uid)
      .maybeSingle();
    if (!runQuery.error && runQuery.data) {
      const rc = (runQuery.data as { raw_contract?: Record<string, unknown> }).raw_contract ?? {};
      businessDna = (rc as Record<string, unknown>).business_dna ??
        (rc as Record<string, unknown>).dna ?? {};
    }
  }
  const workerPayload = {
    contract_version: 1,
    acquisition_id: acq.id,
    source_run_id: acq.source_run_id,
    winning_product: acq.winning_product_snapshot ?? {},
    selected_supplier: acq.selected_supplier_snapshot ?? {},
    sourcing_spec: acq.sourcing_spec_snapshot ?? {},
    business_dna: businessDna,
    requested_at: new Date().toISOString(),
  };

  // In-progress guard: a fresh PREPARING run is left alone; a stale one is
  // re-dispatched (dropped handoff) without a second state transition.
  if (acq.state === "PREPARING") {
    const updatedMs = acq.updated_at ? new Date(acq.updated_at).getTime() : 0;
    if (Date.now() - updatedMs < STALE_PREPARING_MS) {
      return jsonResponse({ ok: true, status: "preparing", in_progress: true }, 200, cors);
    }
    const worker = await dispatchWorker(workerPayload);
    return jsonResponse({ ok: true, status: "preparing", worker, recovered: true }, 200, cors);
  }

  // SELECTED | PREPARE_FAILED -> PREPARING, authorised server-side.
  const begin = await serviceClient.rpc("begin_product_preparation", {
    p_acquisition_id: acq.id,
    p_user_id: uid,
  });
  if (begin.error) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }
  const beginStatus =
    begin.data && typeof begin.data === "object"
      ? (begin.data as { status?: unknown }).status
      : null;
  if (beginStatus === "already_ready") {
    return jsonResponse({ ok: true, status: "ready" }, 200, cors);
  }
  if (beginStatus === "already_preparing") {
    return jsonResponse({ ok: true, status: "preparing", in_progress: true }, 200, cors);
  }
  if (beginStatus !== "preparing") {
    return jsonResponse({ ok: false, code: "not_eligible" }, 409, cors);
  }

  const worker = await dispatchWorker(workerPayload);
  return jsonResponse({ ok: true, status: "preparing", worker }, 200, cors);
});
