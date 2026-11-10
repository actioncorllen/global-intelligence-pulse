// PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001
// READ-ONLY Meta Insights reader. Never activates, never mutates budgets, never spends.
// Token resolved ONLY from env; never returned/logged. Zero-delivery is valid evidence.

const GRAPH_VERSION = "v26.0";
const GRAPH_HOST = "https://graph.facebook.com";

// ---- STRATELOQ mandatory-onboarding gate (edge) BEGIN ------------------------
// AuthZ hardening: previously this endpoint relied on the platform verify_jwt
// gate alone, which the PUBLIC anon key satisfies — any anon-key holder could
// read ad insights for arbitrary object ids. Now the service-role key (internal
// jobs) passes unchanged, and any other caller must be a signed-in user; when
// onboarding enforcement is active that user must also have completed onboarding
// (fn_edge_onboarding_allowed, mig_352 — fail closed). While
// onboarding_policy.enforcement_active = FALSE, signed-in users pass as before.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

/** null = authorized; otherwise the denial Response. */
async function authorizeCaller(req: Request): Promise<Response | null> {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^bearer\s+/i, "").trim();
  if (SERVICE_ROLE && timingSafeEqualStr(bearer, SERVICE_ROLE)) return null; // internal job
  if (!bearer || !SUPABASE_URL || !SERVICE_ROLE) {
    return jsonResponse(401, { ok: false, error: "unauthenticated" });
  }
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${bearer}` },
    });
    if (!u.ok) return jsonResponse(401, { ok: false, error: "unauthenticated" });
    userId = String(((await u.json()) as { id?: string })?.id ?? "");
  } catch {
    return jsonResponse(401, { ok: false, error: "unauthenticated" });
  }
  if (!userId) return jsonResponse(401, { ok: false, error: "unauthenticated" });
  try {
    const g = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_edge_onboarding_allowed`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
      body: JSON.stringify({ p_auth_user_id: userId }),
    });
    if (!g.ok || (await g.text()).trim() !== "true") {
      return jsonResponse(403, { ok: false, error: "onboarding_incomplete" });
    }
  } catch {
    return jsonResponse(403, { ok: false, error: "onboarding_incomplete" });
  }
  return null;
}
// ---- STRATELOQ mandatory-onboarding gate (edge) END --------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const tok = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (tok && tok.length > 0) s = s.split(tok).join("[REDACTED_TOKEN]");
  s = s.replace(/access_token=[^&"]+/gi, "access_token=[REDACTED]");
  return s.slice(0, 800);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  // ---- STRATELOQ mandatory-onboarding gate (edge) BEGIN ----------------------
  const denied = await authorizeCaller(req);
  if (denied) return denied;
  // ---- STRATELOQ mandatory-onboarding gate (edge) END ------------------------
  let body: any;
  try { body = await req.json(); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }
  const objectId = String(body.object_id || "");
  if (!objectId) return jsonResponse(400, { ok: false, error: "object_id_required" });

  const token = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (!token) return jsonResponse(424, { ok: false, error: "server_token_unavailable" });

  const fields = "spend,impressions,reach,frequency,clicks,inline_link_clicks,actions,action_values";
  const url = `${GRAPH_HOST}/${GRAPH_VERSION}/${objectId}/insights?fields=${fields}&access_token=${encodeURIComponent(token)}`;
  try {
    const r = await fetch(url, { method: "GET" }); // READ-ONLY
    const j = await r.json().catch(() => ({}));
    return jsonResponse(200, {
      ok: r.ok, http_status: r.status, object_id: objectId,
      data: Array.isArray(j?.data) ? j.data : null,       // empty array == zero delivery (valid)
      zero_delivery: Array.isArray(j?.data) && j.data.length === 0,
      error: r.ok ? null : redact(j?.error?.message ?? j),
      error_code: j?.error?.code ?? null,
      error_subcode: j?.error?.error_subcode ?? null,
    });
  } catch (e) {
    return jsonResponse(502, { ok: false, object_id: objectId, error: redact((e as Error).message) });
  }
});
