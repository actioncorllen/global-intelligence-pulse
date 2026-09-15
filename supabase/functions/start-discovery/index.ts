// ============================================================================
// Pulse — Business Discovery trigger (BUSINESS-DISCOVERY-002)
// ----------------------------------------------------------------------------
// Authenticated, member-scoped entry point that STARTS asynchronous Business
// Discovery for the calling member. URL-first: the customer supplies only their
// website; identity + ownership are resolved server-side; a concurrency/cost
// guard prevents duplicate paid runs.
//
// SECURITY: verify_jwt is disabled at the platform gate because this handler
// authenticates itself (getUser) and derives identity server-side. The
// service-role key and the n8n secret are read ONLY from the Edge environment;
// they are NEVER returned to the browser. No raw token / JWT / secret is logged.
// ============================================================================

import { createClient } from "@supabase/supabase-js";

function reqEnv(v: string | undefined, name: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new Error(`invalid start-discovery environment configuration: ${name}`);
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
const N8N_DISCOVERY_WEBHOOK = Deno.env.get("N8N_DISCOVERY_WEBHOOK") ?? "";
const PULSE_DISCOVERY_WEBHOOK_SECRET = Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";

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
    headers.set(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type, apikey, x-client-info",
    );
  }
  return headers;
}
function jsonResponse(body: object, status: number, cors: Headers): Response {
  const headers = new Headers(cors);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

function validateWebsite(raw: unknown): { ok: true; url: string } | { ok: false } {
  if (typeof raw !== "string" || raw.trim().length === 0) return { ok: false };
  const candidate = raw.trim();
  let u: URL;
  try {
    u = new URL(/^https?:\/\//i.test(candidate) ? candidate : `https://${candidate}`);
  } catch {
    return { ok: false };
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return { ok: false };
  const host = u.hostname.toLowerCase();
  if (!host.includes(".")) return { ok: false };
  const blocked =
    host === "localhost" ||
    host.endsWith(".local") ||
    host.endsWith(".internal") ||
    host === "0.0.0.0" ||
    host === "metadata.google.internal" ||
    /^127\./.test(host) ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^169\.254\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  if (blocked) return { ok: false };
  return { ok: true, url: u.toString() };
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
  let email: string | null = null;
  try {
    const { data, error } = await anonClient.auth.getUser(bearer);
    if (!error && data.user) {
      uid = data.user.id;
      email = data.user.email ?? null;
    }
  } catch {
    /* fall through to 401 */
  }
  if (uid === null) {
    return jsonResponse({ ok: false, code: "authentication_required" }, 401, cors);
  }

  let body: { website?: unknown };
  try {
    body = (await request.json()) as { website?: unknown };
  } catch {
    return jsonResponse({ ok: false, code: "invalid_request" }, 400, cors);
  }
  const site = validateWebsite(body?.website);
  if (!site.ok) {
    return jsonResponse({ ok: false, code: "invalid_website" }, 400, cors);
  }

  const memberQuery = await serviceClient
    .from("member")
    .select("id, email, business_name, application_ref")
    .eq("auth_user_id", uid)
    .maybeSingle();
  if (memberQuery.error) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }
  if (!memberQuery.data) {
    return jsonResponse({ ok: false, code: "not_a_member" }, 403, cors);
  }
  const member = memberQuery.data as {
    id: string;
    email: string | null;
    business_name: string | null;
    application_ref: string | null;
  };

  // 4b. Concurrency / cost guard. If an analysis is already in progress for this
  //     member, do NOT create another run or spend another Gemini+Claude pass —
  //     return the in-progress run. Self-heals: a stale 'queued' older than 15
  //     minutes (e.g. a dropped handoff) is allowed to start a fresh run.
  const stateQuery = await serviceClient
    .from("discovery_state")
    .select("analysis_status, started_at")
    .eq("member_id", member.id)
    .maybeSingle();
  if (!stateQuery.error && stateQuery.data?.analysis_status === "queued") {
    const startedMs = stateQuery.data.started_at
      ? new Date(stateQuery.data.started_at).getTime()
      : 0;
    if (Date.now() - startedMs < 15 * 60 * 1000) {
      const inflight = await serviceClient
        .from("discovery_runs")
        .select("id")
        .eq("member_id", member.id)
        .eq("run_status", "queued")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      return jsonResponse(
        {
          ok: true,
          status: "queued",
          worker: "in_progress",
          run_id: inflight.data?.id ?? null,
          deduped: true,
        },
        200,
        cors,
      );
    }
  }

  // 4c. Persist the submitted website onto the member's business profile so it
  //     prefills the refresh/URL-first entry and populates the read contract.
  //     Non-fatal: URL-first discovery does not depend on the profile form.
  if (member.application_ref) {
    await serviceClient
      .from("business_profiles")
      .update({ website: site.url })
      .eq("application_id", member.application_ref);
  }

  const bridge = await serviceClient
    .from("users")
    .upsert({ id: uid, email: email ?? member.email }, { onConflict: "id", ignoreDuplicates: true });
  if (bridge.error) {
    return jsonResponse({ ok: false, code: "identity_bridge_failed" }, 503, cors);
  }

  const runInsert = await serviceClient
    .from("discovery_runs")
    .insert({ user_id: uid, member_id: member.id, website: site.url, run_status: "queued" })
    .select("id")
    .single();
  if (runInsert.error || !runInsert.data) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }
  const runId = runInsert.data.id as string;

  const queued = await serviceClient
    .from("discovery_state")
    .update({ analysis_status: "queued", started_at: new Date().toISOString() })
    .eq("member_id", member.id);
  if (queued.error) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }

  let worker: "queued" | "handoff_failed" | "unconfigured" = "unconfigured";
  if (N8N_DISCOVERY_WEBHOOK.length > 0) {
    try {
      const res = await fetch(N8N_DISCOVERY_WEBHOOK, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(PULSE_DISCOVERY_WEBHOOK_SECRET.length > 0
            ? { "x-pulse-webhook-secret": PULSE_DISCOVERY_WEBHOOK_SECRET }
            : {}),
        },
        body: JSON.stringify({
          contract_version: 1,
          discovery_run_id: runId,
          website: site.url,
          known_profile: {
            business_name: member.business_name,
          },
          requested_at: new Date().toISOString(),
        }),
      });
      worker = res.ok ? "queued" : "handoff_failed";
    } catch {
      worker = "handoff_failed";
    }
  }

  return jsonResponse({ ok: true, status: "queued", worker, run_id: runId }, 200, cors);
});
