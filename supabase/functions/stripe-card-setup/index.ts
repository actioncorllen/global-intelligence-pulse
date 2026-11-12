// STRATELOQ — stripe-card-setup (hosted card registration via Stripe Checkout, mode=setup)
// ----------------------------------------------------------------------------
// Signed-in member -> this edge -> (reuse or create) Stripe Customer bound to the
// AUTHENTICATED auth_user_id (server-side; never from client input) -> hosted
// Checkout Session (mode=setup) -> browser redirects to Stripe's PCI-compliant page.
// Card data NEVER touches Strateloq/Supabase/n8n. Registration lands via the
// signature-verified stripe-webhook (fn_psp_card_registered).
//
// TEST / LIVE SEPARATION (pilot-scoped):
//   - TEST is the default for every member, using STRIPE_SECRET_KEY (sk_test_).
//   - LIVE is used ONLY for a member on the live_card_pilot allowlist (mig_361), and ONLY when
//     STRIPE_LIVE_ALLOWED='true' AND a live key STRIPE_SECRET_KEY_LIVE (sk_live_ or rk_live_) is configured.
//   - The two keys are NEVER mixed: the live path uses the live key + live customer; the test path
//     uses the test key + test customer. Customer reuse is filtered by livemode so a test customer
//     id can never be used with the live key (or vice versa).
// INERT until the founder adds the live key AND a separate approval sets STRIPE_LIVE_ALLOWED='true':
// with either absent, useLive is false for everyone and behaviour is byte-identical to test today.
//
// FAIL CLOSED: no STRIPE_SECRET_KEY -> 424. A non-test key without STRIPE_LIVE_ALLOWED -> 424. If
// policy require_live_card is set but this member cannot do live (not pilot / live not ready) ->
// 424 with guidance (never a dead-end sandbox checkout that can't satisfy a live requirement).
// Not onboarding-gated: card setup is itself the CARD_SETUP_REQUIRED step.
import { isLiveKey, liveRoutingDecision } from "./routing.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const STRIPE_KEY_LIVE = Deno.env.get("STRIPE_SECRET_KEY_LIVE") ?? "";
const LIVE_ALLOWED = (Deno.env.get("STRIPE_LIVE_ALLOWED") ?? "") === "true";

const PROD_ORIGIN = "https://www.strateloq.com";
const ALLOWED_RETURN_ORIGINS = new Set<string>([
  PROD_ORIGIN,
  "https://strateloq.com",
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

async function stripe(key: string, path: string, params: Record<string, string>): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "content-type": "application/x-www-form-urlencoded" },
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

async function svcGet(pathAndQuery: string): Promise<unknown> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`,
    { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } });
  if (!r.ok) throw new Error(`svc ${r.status}`);
  return await r.json();
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

  // Decide TEST vs LIVE for THIS member. LIVE requires: approval flag ON, a live key configured,
  // and this member on the live_card_pilot allowlist. Otherwise TEST. Pilot check fails safe to
  // false (test) on any error, so a DB hiccup can never accidentally route a member to live.
  const liveConfigured = LIVE_ALLOWED && isLiveKey(STRIPE_KEY_LIVE);
  let isPilot = false;
  if (liveConfigured) {
    try {
      const rows = (await svcGet(`live_card_pilot?auth_user_id=eq.${userId}&enabled=is.true&select=auth_user_id&limit=1`)) as unknown[];
      isPilot = Array.isArray(rows) && rows.length > 0;
    } catch { isPilot = false; }
  }
  // Pure, unit-tested decision: live key (sk_live_ OR rk_live_) only for an allowlisted pilot
  // while the flag is on; non-pilot members always get the test key.
  const { useLive, activeKey } = liveRoutingDecision(LIVE_ALLOWED, STRIPE_KEY, STRIPE_KEY_LIVE, isPilot);

  // FAIL CLOSED for a live-card requirement: if policy requires a genuine LIVE card but this member
  // cannot do live (not pilot, or live not ready), DO NOT hand out a sandbox checkout that could
  // never satisfy the requirement. Read fails open to current behaviour (require_live_card=FALSE => no-op).
  if (!useLive) {
    let requireLive = false;
    try {
      const rows = (await svcGet(`onboarding_policy?select=require_live_card&limit=1`)) as Array<{ require_live_card?: boolean }>;
      requireLive = rows?.[0]?.require_live_card === true;
    } catch { requireLive = false; }
    if (requireLive) {
      return json(424, {
        status: "LIVE_CARD_REQUIRED_NOT_AVAILABLE",
        message: "A verified live payment card is required, but live card setup is not available for your account yet. Please check back shortly — no sandbox card can be used here.",
      });
    }
  }

  // Optional body: { context?: "billing", origin?: string }.
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

  // Reuse the member's Stripe customer of the SAME mode only (livemode must match the key),
  // so a test customer id is never used with the live key or vice versa.
  let customer = "";
  try {
    const arr = (await svcGet(
      `payment_method_registry?auth_user_id=eq.${userId}&livemode=eq.${useLive}&select=provider_customer_ref&order=created_at.desc&limit=1`)) as Array<{ provider_customer_ref?: string }>;
    customer = String(arr?.[0]?.provider_customer_ref ?? "");
  } catch { /* fall through to create */ }
  if (!customer) {
    const c = await stripe(activeKey, "customers", { "metadata[auth_user_id]": userId });
    if (!c.ok || !c.data.id) return json(502, { status: "CUSTOMER_CREATE_FAILED" });
    customer = String(c.data.id);
  }

  // Hosted Checkout Session, mode=setup (€0, no PaymentIntent). Binding: client_reference_id = uid.
  const s = await stripe(activeKey, "checkout/sessions", {
    mode: "setup",
    customer,
    client_reference_id: userId,
    currency: "eur",
    success_url: successUrl,
    cancel_url: cancelUrl,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, { status: "ok", mode: useLive ? "live" : "test", url: String(s.data.url), session_id: String(s.data.id ?? "") });
});
