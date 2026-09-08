// PULSE-ECOM-P13-META-CONVERSION-TRACKING-001
// Meta Conversions API (CAPI) server-side adapter + conversion dispatch ledger.
//
// SECURITY CONTRACT:
//   - The access token is resolved ONLY from the Edge Function environment at
//     runtime (Deno.env, allowlisted ref name). NEVER returned, logged, echoed,
//     or written to the database. The browser/client never receives it.
//   - The client CANNOT choose the dataset. It is resolved server-side from
//     public.meta_tracking_config for the tenant (arbitrary override rejected).
//   - Canonical Pulse events remain the source of truth; Meta is outbound only.
//   - Raw customer PII is hashed (SHA-256) before transmit and never logged.
//
// MODES:
//   emit    -> full production path: consent gate + idempotency + PURCHASE
//              source-of-truth guard + ledger lifecycle + Meta send + finalize.
//   verify  -> diagnostic: send ONE harmless PageView/ViewContent (no ledger).
//   map     -> build the Meta payload and RETURN it without sending.
//   quality -> read the dataset node (connectivity/readability).

import { createClient } from "jsr:@supabase/supabase-js@2";

const GRAPH_VERSION = "v26.0";
const GRAPH_HOST = "https://graph.facebook.com";
const ALLOWED_TOKEN_REFS = new Set(["META_CAPI_ACCESS_TOKEN"]);

const EVENT_MAP: Record<string, string> = {
  PAGE_VIEW: "PageView", PAGEVIEW: "PageView",
  VIEW_CONTENT: "ViewContent", VIEWCONTENT: "ViewContent",
  SEARCH: "Search",
  ADD_TO_CART: "AddToCart", ADDTOCART: "AddToCart",
  INITIATE_CHECKOUT: "InitiateCheckout", INITIATECHECKOUT: "InitiateCheckout",
  ADD_PAYMENT_INFO: "AddPaymentInfo", ADDPAYMENTINFO: "AddPaymentInfo",
  PURCHASE: "Purchase",
};
const HARMLESS = new Set(["PageView", "ViewContent", "Search"]);

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function safeMessage(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const tok = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (tok && tok.length > 0) s = s.split(tok).join("[REDACTED_TOKEN]");
  s = s.replace(/access_token=[^&"]+/gi, "access_token=[REDACTED]");
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
// Customer identifiers are hashed; nothing is fabricated.
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

async function fingerprint(parts: (string | null | undefined)[]): Promise<string> {
  return (await sha256Hex(parts.map((p) => p ?? "").join("|"))).slice(0, 40);
}

// Resolve effective consent: privacy-safe default is to send ONLY when GRANTED.
function resolveConsent(tenantConsent: boolean | null, eventConsent: boolean | undefined): string {
  if (tenantConsent === false || eventConsent === false) return "DENIED";
  if (tenantConsent === true || eventConsent === true) return "GRANTED";
  return "UNKNOWN";
}

async function postMeta(datasetId: string, token: string, metaEvent: any, testCode?: string) {
  const payload: Record<string, unknown> = { data: [metaEvent], access_token: token };
  if (testCode) payload.test_event_code = String(testCode);
  const url = `${GRAPH_HOST}/${GRAPH_VERSION}/${datasetId}/events`;
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) });
  const j = await r.json().catch(() => ({}));
  return { r, j };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  let body: any;
  try { body = await req.json(); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }

  const mode = String(body.mode || "verify");
  const provider = String(body.provider || "META").toUpperCase();
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

  const datasetId = String(cfg.dataset_id);
  const tokenRef = String(cfg.capi_token_ref || "");
  if (!ALLOWED_TOKEN_REFS.has(tokenRef)) return jsonResponse(409, { ok: false, error: "token_ref_not_allowed" });
  const token = Deno.env.get(tokenRef);
  const tokenPresent = !!(token && token.length > 0);

  // ---- MAP: build payload, never send ----
  if (mode === "map") {
    try {
      const evt = await buildMetaEvent(body.event || {});
      return jsonResponse(200, { ok: true, mode, dataset_id: datasetId, token_present: tokenPresent, mapped_event: evt });
    } catch (e) { return jsonResponse(422, { ok: false, mode, error: safeMessage((e as Error).message) }); }
  }

  if (!tokenPresent) return jsonResponse(424, { ok: false, mode, error: "server_token_unavailable", token_ref: tokenRef });

  // ---- QUALITY: read dataset node ----
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

  // ---- EMIT: full production dispatch path with ledger ----
  if (mode === "emit") {
    const ev = body.event || {};
    const eventId = String(ev.event_id || "");
    if (!eventId) return jsonResponse(400, { ok: false, mode, error: "event_id_required_for_emit" });
    const metaName = EVENT_MAP[String(ev.event_name || "").toUpperCase()];
    if (!metaName) return jsonResponse(422, { ok: false, mode, error: `unsupported_event_name:${ev.event_name}` });

    const isTest = !!body.is_test;
    const fp = await fingerprint([tenantId, provider, eventId, metaName, ev.order_id]);

    // Idempotency: look up any existing ledger row for this (tenant,provider,event_id).
    const { data: existing } = await admin
      .from("conversion_dispatch_ledger")
      .select("id,state,attempt_count,max_attempts,provider_ref")
      .eq("tenant_id", tenantId).eq("provider", provider).eq("event_id", eventId).maybeSingle();

    if (existing && existing.state === "ACCEPTED") {
      return jsonResponse(200, { ok: true, mode, state: "DEDUPLICATED", ledger_id: existing.id,
        dedup: true, note: "event already accepted; not resent", provider_ref: existing.provider_ref });
    }
    if (existing && existing.attempt_count >= existing.max_attempts && existing.state !== "RETRYABLE") {
      return jsonResponse(200, { ok: false, mode, state: existing.state, ledger_id: existing.id,
        error: "max_attempts_exhausted" });
    }

    // Consent gate (reuse user_consent.behavioral_tracking + per-event consent).
    const { data: uc } = await admin.from("user_consent")
      .select("behavioral_tracking").eq("user_id", tenantId).maybeSingle();
    const tenantConsent = uc ? !!uc.behavioral_tracking : null;
    const eventConsent = body.consent && typeof body.consent.behavioral_tracking === "boolean"
      ? body.consent.behavioral_tracking : undefined;
    const consentState = resolveConsent(tenantConsent, eventConsent);

    const baseRow: Record<string, unknown> = {
      tenant_id: tenantId, provider, event_id: eventId,
      commerce_event_uuid: ev.commerce_event_uuid ?? null,
      event_name: metaName, order_id: ev.order_id ?? null,
      consent_state: consentState, event_fingerprint: fp, is_test: isTest,
      updated_at: new Date().toISOString(),
    };

    async function upsertLedger(extra: Record<string, unknown>) {
      const row = { ...baseRow, ...extra };
      const { data, error } = await admin.from("conversion_dispatch_ledger")
        .upsert(row, { onConflict: "tenant_id,provider,event_id" })
        .select("id,state").maybeSingle();
      if (error) throw new Error("ledger_write_failed:" + safeMessage(error.message));
      return data;
    }

    // Consent forbids / unknown -> REJECTED, no Meta call.
    if (consentState !== "GRANTED") {
      const led = await upsertLedger({ state: "REJECTED", error_class: "CONSENT_" + consentState });
      return jsonResponse(200, { ok: false, mode, state: "REJECTED", ledger_id: led?.id,
        blocked: "CONSENT_" + consentState, consent_state: consentState });
    }

    // PURCHASE source-of-truth guard: never emit a Purchase without a verified
    // order source. No connected payment/order provider exists yet.
    if (metaName === "Purchase" && body.order_source_verified !== true) {
      const led = await upsertLedger({ state: "REJECTED", error_class: "PURCHASE_SOURCE_REQUIRED" });
      return jsonResponse(200, { ok: false, mode, state: "REJECTED", ledger_id: led?.id,
        blocked: "BLOCKED_EXTERNAL_CHECKOUT_SOURCE",
        note: "Purchase requires a verified payment/order source of truth" });
    }

    let metaEvent: any;
    try { metaEvent = await buildMetaEvent(ev); }
    catch (e) {
      const led = await upsertLedger({ state: "REJECTED", error_class: "INVALID_EVENT" });
      return jsonResponse(422, { ok: false, mode, state: "REJECTED", ledger_id: led?.id, error: safeMessage((e as Error).message) });
    }

    // VALIDATED -> QUEUED -> SENT (attempt increment).
    const nextAttempt = (existing?.attempt_count ?? 0) + 1;
    await upsertLedger({ state: "SENT", attempt_count: nextAttempt, last_attempt_at: new Date().toISOString() });

    try {
      const { r, j } = await postMeta(datasetId, token!, metaEvent, body.test_event_code);
      if (r.ok && (j?.events_received ?? 0) >= 1) {
        const led = await upsertLedger({ state: "ACCEPTED", provider_ref: j?.fbtrace_id ?? null,
          provider_response: { events_received: j?.events_received ?? null, fbtrace_id: j?.fbtrace_id ?? null, http_status: r.status } });
        return jsonResponse(200, { ok: true, mode, state: "ACCEPTED", ledger_id: led?.id,
          dataset_id: datasetId, sent_event_id: metaEvent.event_id, sent_event_name: metaEvent.event_name,
          consent_state: consentState, events_received: j?.events_received ?? null,
          fbtrace_id: j?.fbtrace_id ?? null, test_event_code_used: !!body.test_event_code });
      }
      // Failure: 5xx -> RETRYABLE (bounded), else FAILED.
      const retryable = r.status >= 500 || r.status === 429;
      const state = retryable && nextAttempt < (existing?.max_attempts ?? 5) ? "RETRYABLE" : "FAILED";
      const led = await upsertLedger({ state, error_class: "META_" + (j?.error?.code ?? r.status),
        provider_ref: j?.fbtrace_id ?? null,
        provider_response: { http_status: r.status, error: pickError(j?.error) } });
      return jsonResponse(200, { ok: false, mode, state, ledger_id: led?.id, http_status: r.status,
        error: safeMessage(j?.error?.message ?? j), error_detail: pickError(j?.error) });
    } catch (e) {
      const state = nextAttempt < (existing?.max_attempts ?? 5) ? "RETRYABLE" : "FAILED";
      const led = await upsertLedger({ state, error_class: "TRANSPORT" });
      return jsonResponse(502, { ok: false, mode, state, ledger_id: led?.id, error: safeMessage((e as Error).message) });
    }
  }

  // ---- VERIFY: diagnostic harmless send (no ledger) ----
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
  if (metaEvent.event_name === "Purchase") {
    return jsonResponse(409, { ok: false, mode, error: "purchase_transmit_blocked_use_emit_with_verified_source" });
  }
  try {
    const { r, j } = await postMeta(datasetId, token!, metaEvent, body.test_event_code);
    return jsonResponse(200, {
      ok: r.ok, mode, http_status: r.status, dataset_id: datasetId,
      sent_event_name: metaEvent.event_name, sent_event_id: metaEvent.event_id,
      test_event_code_used: !!body.test_event_code,
      events_received: j?.events_received ?? null, fbtrace_id: j?.fbtrace_id ?? null, messages: j?.messages ?? null,
      error: r.ok ? null : safeMessage(j?.error?.message ?? j),
      error_code: j?.error?.code ?? null, error_detail: r.ok ? null : pickError(j?.error),
    });
  } catch (e) { return jsonResponse(502, { ok: false, mode, error: safeMessage((e as Error).message) }); }
});
