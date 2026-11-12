// STRATELOQ — stripe-webhook (signature-verified, idempotent PSP event ingestion)
// ----------------------------------------------------------------------------
// The ONLY writer of card registrations and wallet credits. Every request must carry a valid
// Stripe-Signature (HMAC-SHA256 over `${t}.${rawBody}`, 5-minute tolerance, timing-safe compare)
// that validates against the TEST secret (STRIPE_WEBHOOK_SECRET) OR the LIVE secret
// (STRIPE_WEBHOOK_SECRET_LIVE) — otherwise 400, nothing processed. Supporting BOTH secrets lets a
// separate TEST endpoint and a separate LIVE endpoint (each with its own signing secret) deliver to
// this one function without mixing secrets. Test and live are never confused: a live event is
// processed only if STRIPE_LIVE_ALLOWED='true', and the Stripe API key used to expand the event is
// selected by event.livemode (live key for live events, test key for test events).
// Event idempotency: fn_psp_webhook_begin (PK on event id). Wallet credits are also idempotent per
// payment reference. Member binding: client_reference_id, set server-side by the initiating edge.
// FAIL-CLOSED: no webhook secret at all -> 424. LIVE events ignored unless STRIPE_LIVE_ALLOWED='true'.
// LIVE card registration is additionally gated by independent pilot authorisation (pilot_auth.ts):
// a livemode=true setup registration proceeds ONLY for a positively-verified, enabled live_card_pilot.
import { liveCardRegistrationDecision, type PilotLookup } from "./pilot_auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const STRIPE_KEY_LIVE = Deno.env.get("STRIPE_SECRET_KEY_LIVE") ?? "";
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const WEBHOOK_SECRET_LIVE = Deno.env.get("STRIPE_WEBHOOK_SECRET_LIVE") ?? "";
const LIVE_ALLOWED = (Deno.env.get("STRIPE_LIVE_ALLOWED") ?? "") === "true";
const TOLERANCE_SEC = 300;

const json = (s: number, b: unknown) =>
  new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Verify a Stripe-Signature header against a single secret. Exported shape kept pure for testing. */
export async function verifyStripeSignature(
  header: string | null, rawBody: string, secret: string, nowEpochSec: number, toleranceSec: number,
): Promise<boolean> {
  if (!header || !secret) return false;
  let t = ""; const v1s: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2).map((x) => (x ?? "").trim());
    if (k === "t") t = v;
    else if (k === "v1" && v) v1s.push(v);
  }
  const ts = Number(t);
  if (!Number.isFinite(ts) || Math.abs(nowEpochSec - ts) > toleranceSec) return false;
  if (v1s.length === 0) return false;
  const expected = await hmacHex(secret, `${t}.${rawBody}`);
  let ok = false;
  for (const v of v1s) ok = timingSafeEqualStr(expected, v) || ok;
  return ok;
}

/** True if the signature validates against EITHER the live or the test secret (whichever present). */
async function verifyAnySecret(header: string | null, rawBody: string, nowSec: number): Promise<boolean> {
  if (WEBHOOK_SECRET_LIVE && await verifyStripeSignature(header, rawBody, WEBHOOK_SECRET_LIVE, nowSec, TOLERANCE_SEC)) return true;
  if (WEBHOOK_SECRET && await verifyStripeSignature(header, rawBody, WEBHOOK_SECRET, nowSec, TOLERANCE_SEC)) return true;
  return false;
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  let parsed: unknown = null; try { parsed = txt ? JSON.parse(txt) : null; } catch { parsed = txt; }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}`);
  return parsed;
}

async function stripeGet(apiKey: string, path: string): Promise<Record<string, unknown>> {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  const txt = await res.text();
  try { return txt ? JSON.parse(txt) : {}; } catch { return {}; }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json(405, { ok: false });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { ok: false, error: "server_not_configured" });
  if (!WEBHOOK_SECRET && !WEBHOOK_SECRET_LIVE) return json(424, { ok: false, error: "webhook_not_configured" });

  const rawBody = await req.text();
  const nowSec = Math.floor(Date.now() / 1000);
  const valid = await verifyAnySecret(req.headers.get("stripe-signature"), rawBody, nowSec);
  if (!valid) return json(400, { ok: false, error: "invalid_signature" });

  let event: Record<string, unknown>;
  try { event = JSON.parse(rawBody) as Record<string, unknown>; } catch { return json(400, { ok: false, error: "invalid_json" }); }
  const eventId = String(event.id ?? "");
  const eventType = String(event.type ?? "unknown");
  const livemode = event.livemode === true;
  if (!eventId) return json(400, { ok: false, error: "no_event_id" });

  // Live events are processed only under explicit approval. Also select the matching Stripe API key.
  if (livemode && !LIVE_ALLOWED) {
    return json(200, { ok: true, ignored: "livemode_not_approved" });
  }
  const apiKey = livemode ? STRIPE_KEY_LIVE : STRIPE_KEY;

  // Idempotency: first claim wins; replays acknowledge without effect.
  try {
    const begin = (await rpc("fn_psp_webhook_begin", { p_event_id: eventId, p_event_type: eventType, p_livemode: livemode })) as Record<string, unknown>;
    if (begin?.duplicate === true) return json(200, { ok: true, duplicate: true });
  } catch { return json(500, { ok: false, error: "dedupe_unavailable" }); }

  const finish = async (outcome: string) => { try { await rpc("fn_psp_webhook_finish", { p_event_id: eventId, p_outcome: outcome }); } catch { /* best effort */ } };
  const obj = ((event.data as Record<string, unknown>)?.object ?? {}) as Record<string, unknown>;

  try {
    if (eventType === "checkout.session.completed") {
      const mode = String(obj.mode ?? "");
      const uid = String(obj.client_reference_id ?? "");
      if (mode === "setup" && uid) {
        // INDEPENDENT pilot authorisation for LIVE card registration (defense in depth).
        // Test-mode registrations are not gated (no extra DB call); live-mode requires a
        // positively-verified, enabled live_card_pilot. Fail closed otherwise.
        let pilot: PilotLookup = { ok: true, enabled: false };
        if (livemode) {
          try {
            const p = await rpc("fn_live_card_pilot", { p_uid: uid });
            pilot = { ok: true, enabled: p === true };
          } catch { pilot = { ok: false }; }
        }
        const gate = liveCardRegistrationDecision(livemode, pilot);
        if (!gate.register) {
          // A RETRYABLE (5xx) refusal (e.g. the pilot lookup transiently failed) must be persisted
          // so fn_psp_webhook_begin RECLAIMS the event on the next Stripe retry — it reclaims only
          // outcomes LIKE 'error:%'. A DETERMINISTIC (2xx) refusal (not a pilot) is terminal and is
          // persisted as-is so retries are correctly treated as duplicates. The card registration
          // itself is idempotent, so a reclaimed reprocess can never double-register.
          await finish(gate.httpStatus >= 500 ? `error:${gate.outcome}` : gate.outcome);
          return json(gate.httpStatus, { ok: gate.httpStatus < 400, handled: "card_setup", refused: gate.outcome });
        }
        const siId = String(obj.setup_intent ?? "");
        if (!siId) { await finish("setup_missing_intent"); return json(200, { ok: true }); }
        const si = await stripeGet(apiKey, `setup_intents/${siId}?expand[]=payment_method`);
        const pm = (si.payment_method ?? {}) as Record<string, unknown>;
        const card = (pm.card ?? {}) as Record<string, unknown>;
        const r = (await rpc("fn_psp_card_registered", {
          p_auth_user_id: uid,
          p_customer_ref: String(si.customer ?? obj.customer ?? ""),
          p_pm_ref: String(pm.id ?? ""),
          p_brand: String(card.brand ?? ""), p_last4: String(card.last4 ?? ""),
          p_exp_month: Number(card.exp_month ?? 0) || null, p_exp_year: Number(card.exp_year ?? 0) || null,
          p_livemode: livemode,  // record whether this is a LIVE or TEST payment method
        })) as Record<string, unknown>;
        await finish(`card_registered:${r?.status}`);
        return json(200, { ok: true, handled: "card_setup" });
      }
      if (mode === "payment" && uid) {
        const meta = (obj.metadata ?? {}) as Record<string, unknown>;
        const r = (await rpc("fn_wallet_credit_purchase", {
          p_auth_user_id: uid,
          p_price_code: String(meta.price_code ?? ""),
          p_payment_ref: String(obj.payment_intent ?? obj.id ?? ""),
          p_evidence: { summary: `stripe checkout ${String(obj.id ?? "")}`, amount_total: obj.amount_total, currency: obj.currency },
        })) as Record<string, unknown>;
        await finish(`wallet_purchase:${r?.status}${r?.idempotent_replay === true ? ":replay" : ""}`);
        return json(200, { ok: true, handled: "wallet_topup", result: r?.status });
      }
      await finish("session_ignored");
      return json(200, { ok: true, ignored: "unbound_session" });
    }
    if (eventType === "payment_method.detached") {
      const r = (await rpc("fn_psp_card_detached", { p_pm_ref: String(obj.id ?? "") })) as Record<string, unknown>;
      await finish(`card_detached:${r?.status}`);
      return json(200, { ok: true, handled: "card_detached" });
    }
    await finish("ignored_type");
    return json(200, { ok: true, ignored: eventType });
  } catch (e) {
    await finish(`error:${(e as Error).message.slice(0, 120)}`);
    // Non-2xx so Stripe retries; the event-claim row stays, so a retry that reaches a healthy
    // database is acknowledged as duplicate WITHOUT re-processing side effects that already
    // happened (card upsert + purchase are themselves idempotent anyway).
    return json(500, { ok: false, error: "processing_failed" });
  }
});
