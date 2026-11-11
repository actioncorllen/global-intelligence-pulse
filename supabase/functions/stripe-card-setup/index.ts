// STRATELOQ — stripe-card-setup (hosted card registration via Stripe Checkout, mode=setup)
// ----------------------------------------------------------------------------
// Signed-in member -> this edge -> (reuse or create) Stripe Customer bound to the
// AUTHENTICATED auth_user_id (server-side; never from client input) -> hosted
// Checkout Session (mode=setup) -> browser redirects to Stripe's PCI-compliant page.
// Card data NEVER touches Strateloq/Supabase/n8n. Registration lands via the
// signature-verified stripe-webhook (fn_psp_card_registered).
//
// FAIL-CLOSED / INERT: without STRIPE_SECRET_KEY this returns 424. A LIVE-mode key
// (sk_live_) is refused unless STRIPE_LIVE_ALLOWED='true' (separate founder approval).
// This function is intentionally NOT onboarding-gated: card setup is itself an
// onboarding step (CARD_SETUP_REQUIRED) and must be reachable by incomplete members.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const LIVE_ALLOWED = (Deno.env.get("STRIPE_LIVE_ALLOWED") ?? "") === "true";
const APP_ORIGIN = Deno.env.get("STRATELOQ_APP_ORIGIN") ?? "https://globalintelligenceactions.com";
const SUCCESS_URL = Deno.env.get("STRIPE_SETUP_SUCCESS_URL") ?? `${APP_ORIGIN}/onboarding?card=success`;
const CANCEL_URL = Deno.env.get("STRIPE_SETUP_CANCEL_URL") ?? `${APP_ORIGIN}/onboarding?card=cancelled`;
const BILLING_SUCCESS_URL = `${APP_ORIGIN}/workspace/billing?card=success`;
const BILLING_CANCEL_URL = `${APP_ORIGIN}/workspace/billing?card=cancelled`;

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
  return { ok: res.ok, status: res.status, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });
  if (!STRIPE_KEY) return json(424, { status: "PAYMENTS_NOT_CONFIGURED", message: "Card setup is not available yet." });
  if (!STRIPE_KEY.startsWith("sk_test_") && !LIVE_ALLOWED) {
    return json(424, { status: "LIVE_MODE_NOT_APPROVED", message: "Live payments are not enabled." });
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

  // Optional context: "billing" returns to the Billing & Credits panel instead of onboarding.
  let context = "";
  try { context = String(((await req.json()) as { context?: string })?.context ?? ""); } catch { /* empty body ok */ }
  const successUrl = context === "billing" ? BILLING_SUCCESS_URL : SUCCESS_URL;
  const cancelUrl = context === "billing" ? BILLING_CANCEL_URL : CANCEL_URL;

  // Reuse the member's existing Stripe customer where one is on record (any status)
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

  // Hosted Checkout Session, mode=setup. Binding: client_reference_id = authenticated uid.
  const s = await stripe("checkout/sessions", {
    mode: "setup",
    customer,
    client_reference_id: userId,
    "payment_method_types[0]": "card",
    success_url: successUrl,
    cancel_url: cancelUrl,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, { status: "ok", url: String(s.data.url), session_id: String(s.data.id ?? "") });
});
