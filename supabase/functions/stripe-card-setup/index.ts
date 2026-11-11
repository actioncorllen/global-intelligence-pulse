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
// Canonical production origin (founder-confirmed). The browser return URL is cosmetic —
// a card is registered ONLY by the signature-verified webhook, never by the return param —
// but it must land on a live origin.
const PROD_ORIGIN = "https://strateloq.com";
// EXACT authorised return origins only — production plus the single Strateloq preview host.
// No wildcard: other Lovable projects' *.lovable.app / *.lovableproject.com hosts are NOT
// trusted. A client-proposed origin is honoured only on an exact, case-normalised match;
// anything else (legacy domain, another project's preview, an attacker URL) falls back to
// production. Never an open redirect.
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
    // Diagnosable failures: Stripe error class/code/param/message only — never keys or card data.
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

  // Optional body: { context?: "billing", origin?: string }. "billing" returns to the
  // Billing & Credits panel instead of onboarding; origin is validated server-side
  // (allowlist above) — a legacy or arbitrary origin is ignored in favour of production.
  let context = "", reqOrigin = "";
  try {
    const b = (await req.json()) as { context?: string; origin?: string };
    context = String(b?.context ?? "");
    reqOrigin = String(b?.origin ?? "");
  } catch { /* empty body ok */ }
  const origin = safeReturnOrigin(reqOrigin);
  const returnPath = context === "billing" ? "/workspace/billing" : "/onboarding";
  const successUrl = `${origin}${returnPath}?card=success`;
  const cancelUrl = `${origin}${returnPath}?card=cancelled`;

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
  // No payment_method_types: current Stripe API versions (2026-10-28.endive) refuse it on
  // Checkout Sessions (methods are Dashboard-managed); mode=setup instead requires currency.
  const s = await stripe("checkout/sessions", {
    mode: "setup",
    customer,
    client_reference_id: userId,
    currency: "eur",
    success_url: successUrl,
    cancel_url: cancelUrl,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, { status: "ok", url: String(s.data.url), session_id: String(s.data.id ?? "") });
});
