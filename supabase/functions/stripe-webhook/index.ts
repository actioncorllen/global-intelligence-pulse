// STRATELOQ — stripe-webhook (signature-verified, idempotent PSP event ingestion)
// ----------------------------------------------------------------------------
// The ONLY writer of card registrations and wallet credits. Every request must carry
// a valid Stripe-Signature (HMAC-SHA256 over `${t}.${rawBody}` with STRIPE_WEBHOOK_SECRET,
// 5-minute tolerance, timing-safe compare) — otherwise 400, nothing processed.
// Event idempotency: fn_psp_webhook_begin (PK on event id) — a replayed event is
// acknowledged 200 but has NO effect; wallet credits are ALSO idempotent per
// payment reference (fn_wallet_credit_purchase), so duplicates can never double-fund.
// Member binding: client_reference_id, set SERVER-SIDE by stripe-card-setup /
// stripe-wallet-topup from the authenticated user — never trusted from the browser.
// FAIL-CLOSED: no STRIPE_WEBHOOK_SECRET -> 424 (verify_jwt=false is safe: nothing
// can be processed without the signature). LIVE events are ignored unless
// STRIPE_LIVE_ALLOWED='true' (separate founder approval).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
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

/** Verify a Stripe-Signature header against the raw body. Exported shape kept pure for unit testing. */
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

async function stripeGet(path: string): Promise<Record<string, unknown>> {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_KEY}` },
  });
  const txt = await res.text();
  try { return txt ? JSON.parse(txt) : {}; } catch { return {}; }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json(405, { ok: false });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { ok: false, error: "server_not_configured" });
  if (!WEBHOOK_SECRET) return json(424, { ok: false, error: "webhook_not_configured" });

  const rawBody = await req.text();
  const nowSec = Math.floor(Date.now() / 1000);
  const valid = await verifyStripeSignature(req.headers.get("stripe-signature"), rawBody, WEBHOOK_SECRET, nowSec, TOLERANCE_SEC);
  if (!valid) return json(400, { ok: false, error: "invalid_signature" });

  let event: Record<string, unknown>;
  try { event = JSON.parse(rawBody) as Record<string, unknown>; } catch { return json(400, { ok: false, error: "invalid_json" }); }
  const eventId = String(event.id ?? "");
  const eventType = String(event.type ?? "unknown");
  const livemode = event.livemode === true;
  if (!eventId) return json(400, { ok: false, error: "no_event_id" });

  if (livemode && !LIVE_ALLOWED) {
    return json(200, { ok: true, ignored: "livemode_not_approved" });
  }

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
        const siId = String(obj.setup_intent ?? "");
        if (!siId) { await finish("setup_missing_intent"); return json(200, { ok: true }); }
        const si = await stripeGet(`setup_intents/${siId}?expand[]=payment_method`);
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
    // Non-2xx so Stripe retries; the event-claim row stays, so a retry that reaches a
    // healthy database is acknowledged as duplicate WITHOUT re-processing side effects
    // that already happened (card upsert + purchase are themselves idempotent anyway).
    return json(500, { ok: false, error: "processing_failed" });
  }
});
