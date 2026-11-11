// STRATELOQ — stripe-membership-checkout (PREPARED, NOT DEPLOYED — founder-approved activation only)
// ----------------------------------------------------------------------------
// The MISSING real-customer membership purchase contract. Mirrors stripe-card-setup exactly, but
// opens a hosted Checkout Session in mode=subscription for a RECURRING price the FOUNDER defines in
// Stripe. On completion, the signature-verified stripe-webhook activates the member's entitlement
// via fn_psp_membership_activated (mig_360) — source=PROVIDER, status from Stripe.
//
// NO INVENTED PRICING: the price, interval, amount and currency are NOT in this file. The price is
// read from the STRIPE_MEMBERSHIP_PRICE_ID secret (a Stripe price id the founder creates). All
// commercial terms live in Stripe and flow back through the webhook. This file hardcodes none.
//
// FAIL CLOSED / INERT until the founder activates it:
//   - not deployed (prepared in repo only);
//   - returns 424 MEMBERSHIP_PRICE_NOT_CONFIGURED if STRIPE_MEMBERSHIP_PRICE_ID is unset;
//   - returns 424 if no Stripe key, or a live key without STRIPE_LIVE_ALLOWED='true';
//   - never charges by itself: it only creates a hosted Checkout Session; the customer confirms
//     on Stripe's PCI page. Card data never touches Strateloq/Supabase.
// ACTIVATION (separate founder approval): deploy this function, set STRIPE_MEMBERSHIP_PRICE_ID,
// add the subscription handlers to stripe-webhook (see docs/BILLING-READINESS.md), test in TEST
// mode end-to-end, then enable live only after the live-card safeguards are verified.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const LIVE_ALLOWED = (Deno.env.get("STRIPE_LIVE_ALLOWED") ?? "") === "true";
// Founder-supplied Stripe recurring price id (e.g. price_...). NO fallback, NO hardcoded price.
const MEMBERSHIP_PRICE_ID = Deno.env.get("STRIPE_MEMBERSHIP_PRICE_ID") ?? "";

const PROD_ORIGIN = "https://strateloq.com";
const ALLOWED_RETURN_ORIGINS = new Set<string>([
  PROD_ORIGIN,
  "https://www.strateloq.com",
  "https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app",
]);
function safeReturnOrigin(requested: string): string {
  try {
    const u = new URL(requested);
    if (u.protocol === "https:") {
      const origin = `https://${u.host.toLowerCase()}`;
      if (ALLOWED_RETURN_ORIGINS.has(origin)) return origin;
    }
  } catch { /* fall through to production */ }
  return PROD_ORIGIN;
}

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (s: number, b: unknown) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store" } });

async function stripe(path: string, params: Record<string, string>): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${STRIPE_KEY}`, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params).toString(),
  });
  const txt = await res.text();
  let data: Record<string, unknown> = {}; try { data = txt ? JSON.parse(txt) : {}; } catch { data = { raw: txt.slice(0, 200) }; }
  if (!res.ok) {
    const e = (data.error ?? {}) as Record<string, unknown>;
    console.error(`stripe ${path} failed`, JSON.stringify({
      status: res.status, type: e.type, code: e.code, param: e.param,
      message: String(e.message ?? "").slice(0, 300),
    }));
  }
  return { ok: res.ok, status: res.status, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });
  if (!STRIPE_KEY) return json(424, { status: "PAYMENTS_NOT_CONFIGURED", message: "Membership checkout is not available yet." });
  if (!STRIPE_KEY.startsWith("sk_test_") && !LIVE_ALLOWED) {
    return json(424, { status: "LIVE_MODE_NOT_APPROVED", message: "Live payments are not enabled." });
  }
  // Fail closed until the founder configures the recurring price. No price => no paid flow.
  if (!MEMBERSHIP_PRICE_ID) {
    return json(424, { status: "MEMBERSHIP_PRICE_NOT_CONFIGURED", message: "Paid membership is not available yet." });
  }

  // Authenticate the member (server-side)
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_ROLE, authorization: authHeader } });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    userId = String(((await u.json()) as { id?: string })?.id ?? "");
  } catch { return json(401, { status: "UNAUTHENTICATED" }); }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  // Preserve COMP: a member who already holds an active entitlement should not be charged.
  // fn_entitlement_status is owner-scoped; if it reports an active entitlement, refuse to start
  // a paid subscription (COMP founders can never be silently converted to paying).
  try {
    const es = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_entitlement_status`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: authHeader },
      body: "{}",
    });
    if (es.ok) {
      const st = (await es.json()) as { entitlement_active?: boolean; status?: string } | null;
      if (st?.entitlement_active === true) {
        return json(409, { status: "ALREADY_ENTITLED", message: "You already have an active membership." });
      }
    }
  } catch { /* non-fatal: proceed to checkout */ }

  let reqOrigin = "";
  try {
    const b = (await req.json()) as { origin?: string };
    reqOrigin = String(b?.origin ?? "");
  } catch { /* empty body ok */ }
  const origin = safeReturnOrigin(reqOrigin);
  const successUrl = `${origin}/onboarding?membership=success`;
  const cancelUrl = `${origin}/onboarding?membership=cancelled`;

  // Reuse the member's Stripe customer where one is on record (e.g. from card setup)
  let customer = "";
  try {
    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/payment_method_registry?auth_user_id=eq.${userId}&select=provider_customer_ref&order=created_at.desc&limit=1`,
      { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } });
    const arr = (await r.json()) as Array<{ provider_customer_ref?: string }>;
    customer = String(arr?.[0]?.provider_customer_ref ?? "");
  } catch { /* fall through to create */ }
  if (!customer) {
    const c = await stripe("customers", { "metadata[auth_user_id]": userId });
    if (!c.ok || !c.data.id) return json(502, { status: "CUSTOMER_CREATE_FAILED" });
    customer = String(c.data.id);
  }

  // Hosted Checkout Session, mode=subscription. Binding: client_reference_id = authenticated uid.
  // The recurring price (and therefore amount / interval / currency) comes ENTIRELY from Stripe.
  const s = await stripe("checkout/sessions", {
    mode: "subscription",
    customer,
    client_reference_id: userId,
    "line_items[0][price]": MEMBERSHIP_PRICE_ID,
    "line_items[0][quantity]": "1",
    "subscription_data[metadata][auth_user_id]": userId,
    success_url: successUrl,
    cancel_url: cancelUrl,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, { status: "ok", url: String(s.data.url), session_id: String(s.data.id ?? "") });
});
