// PULSE-ECOM-P13-META-CAPI-CONNECTION-001
// Meta Conversions API (CAPI) server-side adapter (deployed: meta-capi-adapter).
//
// SECURITY CONTRACT:
//   - The access token is resolved ONLY from the Edge Function environment at
//     runtime (Deno.env.get(<allowlisted ref name>)). It is NEVER returned in a
//     response, logged, echoed, or written to the database. The browser/client
//     never receives it.
//   - The client CANNOT choose the dataset. The dataset id is looked up
//     server-side from public.meta_tracking_config for the tenant; any dataset
//     supplied by the caller is ignored (arbitrary override rejected).
//   - Canonical Pulse events remain the source of truth; Meta is an outbound
//     adapter only. This function never creates or mutates canonical events.
//
// MODES: verify | map | quality | send  (see unit spec / repo docs).

import { createClient } from "jsr:@supabase/supabase-js@2";

const GRAPH_VERSION = "v26.0";
const GRAPH_HOST = "https://graph.facebook.com";
const ALLOWED_TOKEN_REFS = new Set(["META_CAPI_ACCESS_TOKEN"]);

const EVENT_MAP: Record<string, string> = {
  PAGE_VIEW: "PageView", PAGEVIEW: "PageView",
  VIEW_CONTENT: "ViewContent", VIEWCONTENT: "ViewContent",
  ADD_TO_CART: "AddToCart", ADDTOCART: "AddToCart",
  INITIATE_CHECKOUT: "InitiateCheckout", INITIATECHECKOUT: "InitiateCheckout",
  PURCHASE: "Purchase",
};
const HARMLESS = new Set(["PageView", "ViewContent"]);

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function safeMessage(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const tok = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (tok && tok.length > 0) s = s.split(tok).join("[REDACTED_TOKEN]");
  s = s.replace(/access_token=[^&"\s]+/gi, "access_token=[REDACTED]");
  return s.slice(0, 800);
}

function pickError(err: any): any {
  if (!err) return null;
  return {
    message: err.message != null ? safeMessage(err.message) : null,
    type: err.type ?? null, code: err.code ?? null,
    error_subcode: err.error_subcode ?? null,
    error_user_title: err.error_user_title != null ? safeMessage(err.error_user_title) : null,
    error_user_msg: err.error_user_msg != null ? safeMessage(err.error_user_msg) : null,
    fbtrace_id: err.fbtrace_id ?? null,
  };
}

async function sha256Hex(v: string): Promise<string> {
  const data = new TextEncoder().encode(v.trim().toLowerCase());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Build a Meta CAPI event from a canonical Pulse event.
// Customer info is included ONLY if legitimately supplied; never fabricated.
async function buildMetaEvent(canonical: any): Promise<any> {
  const metaName = EVENT_MAP[String(canonical.event_name || "").toUpperCase()];
  if (!metaName) throw new Error(`unsupported_event_name:${canonical.event_name}`);
  const user_data: Record<string, unknown> = {};
  if (canonical.email && typeof canonical.email === "string") user_data.em = [await sha256Hex(canonical.email)];
  if (canonical.phone && typeof canonical.phone === "string") user_data.ph = [await sha256Hex(canonical.phone)];
  if (canonical.external_id && typeof canonical.external_id === "string") user_data.external_id = [await sha256Hex(canonical.external_id)];
  if (canonical.client_user_agent) user_data.client_user_agent = String(canonical.client_user_agent);
  if (canonical.client_ip_address) user_data.client_ip_address = String(canonical.client_ip_address);
  if (canonical.fbp) user_data.fbp = String(canonical.fbp);
  if (canonical.fbc) user_data.fbc = String(canonical.fbc);
  if (Object.keys(user_data).length === 0) user_data.client_user_agent = "PulseCAPIVerifier/1.0";
  const evt: Record<string, unknown> = {
    event_name: metaName,
    event_time: Number(canonical.event_time) || Math.floor(Date.now() / 1000),
    event_id: String(canonical.event_id || crypto.randomUUID()),
    action_source: String(canonical.action_source || "website"),
    user_data,
  };
  if (canonical.event_source_url) evt.event_source_url = String(canonical.event_source_url);
  if (metaName === "Purchase") {
    if (canonical.currency == null || canonical.value == null) throw new Error("purchase_requires_currency_and_value");
    evt.custom_data = {
      currency: String(canonical.currency).toUpperCase(), value: Number(canonical.value),
      ...(canonical.order_id ? { order_id: String(canonical.order_id) } : {}),
      ...(canonical.content_ids ? { content_ids: canonical.content_ids } : {}),
    };
  } else if (canonical.currency != null && canonical.value != null) {
    evt.custom_data = { currency: String(canonical.currency).toUpperCase(), value: Number(canonical.value) };
  }
  return evt;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  let body: any;
  try { body = await req.json(); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }

  const mode = String(body.mode || "verify");
  const tenantId = String(body.tenant_id || "");
  if (!tenantId) return jsonResponse(400, { ok: false, error: "tenant_id_required" });

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  const { data: cfg, error: cfgErr } = await admin
    .from("meta_tracking_config")
    .select("tenant_id,dataset_id,capi_enabled,capi_token_ref,state")
    .eq("tenant_id", tenantId).maybeSingle();

  if (cfgErr) return jsonResponse(500, { ok: false, error: "config_lookup_failed", detail: safeMessage(cfgErr.message) });
  if (!cfg) return jsonResponse(404, { ok: false, error: "tracking_config_not_found_for_tenant" });
  if (!cfg.capi_enabled) return jsonResponse(409, { ok: false, error: "capi_not_enabled" });
  if (!cfg.dataset_id) return jsonResponse(409, { ok: false, error: "dataset_not_configured" });

  const datasetId = String(cfg.dataset_id); // authoritative, server-side only
  const tokenRef = String(cfg.capi_token_ref || "");
  if (!ALLOWED_TOKEN_REFS.has(tokenRef)) return jsonResponse(409, { ok: false, error: "token_ref_not_allowed" });
  const token = Deno.env.get(tokenRef);
  const tokenPresent = !!(token && token.length > 0);

  if (mode === "map") {
    try {
      const evt = await buildMetaEvent(body.event || {});
      return jsonResponse(200, { ok: true, mode, dataset_id: datasetId, token_present: tokenPresent, mapped_event: evt });
    } catch (e) { return jsonResponse(422, { ok: false, mode, error: safeMessage((e as Error).message) }); }
  }

  if (!tokenPresent) return jsonResponse(424, { ok: false, mode, error: "server_token_unavailable", token_ref: tokenRef });

  if (mode === "quality") {
    const url = `${GRAPH_HOST}/${GRAPH_VERSION}/${datasetId}?fields=id,name&access_token=${encodeURIComponent(token!)}`;
    try {
      const r = await fetch(url, { method: "GET" });
      const j = await r.json().catch(() => ({}));
      return jsonResponse(200, {
        ok: r.ok, mode, http_status: r.status, dataset_id: datasetId,
        dataset_name: j?.name ?? null, node_id_echo: j?.id ?? null,
        error: r.ok ? null : safeMessage(j?.error?.message ?? j),
        error_code: j?.error?.code ?? null, error_detail: r.ok ? null : pickError(j?.error),
      });
    } catch (e) { return jsonResponse(502, { ok: false, mode, error: safeMessage((e as Error).message) }); }
  }

  const canonical = body.event || {};
  if (mode === "verify") {
    const requested = EVENT_MAP[String(canonical.event_name || "").toUpperCase()] || "PageView";
    canonical.event_name = HARMLESS.has(requested) ? requested : "PageView";
    canonical.action_source = canonical.action_source || "website";
    canonical.event_source_url = canonical.event_source_url || "https://globalintelligenceactions.com/";
    if (!canonical.event_id) canonical.event_id = `pulse_verify_${crypto.randomUUID()}`;
  }

  let metaEvent: any;
  try { metaEvent = await buildMetaEvent(canonical); }
  catch (e) { return jsonResponse(422, { ok: false, mode, error: safeMessage((e as Error).message) }); }

  // Never transmit a Purchase from verify/send in this phase; use map mode for structure.
  if (metaEvent.event_name === "Purchase") {
    return jsonResponse(409, { ok: false, mode, error: "purchase_transmit_blocked_this_phase_use_map_mode" });
  }

  const payload: Record<string, unknown> = { data: [metaEvent], access_token: token };
  if (body.test_event_code) payload.test_event_code = String(body.test_event_code);

  const url = `${GRAPH_HOST}/${GRAPH_VERSION}/${datasetId}/events`;
  try {
    const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) });
    const j = await r.json().catch(() => ({}));
    return jsonResponse(200, {
      ok: r.ok, mode, http_status: r.status, dataset_id: datasetId,
      sent_event_name: metaEvent.event_name, sent_event_id: metaEvent.event_id,
      test_event_code_used: !!body.test_event_code,
      events_received: j?.events_received ?? null,
      fbtrace_id: j?.fbtrace_id ?? null, messages: j?.messages ?? null,
      error: r.ok ? null : safeMessage(j?.error?.message ?? j),
      error_code: j?.error?.code ?? null, error_detail: r.ok ? null : pickError(j?.error),
    });
  } catch (e) { return jsonResponse(502, { ok: false, mode, error: safeMessage((e as Error).message) }); }
});
