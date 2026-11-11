// STRATELOQ — stripe-wallet-topup (prepaid research-credit purchase via hosted Checkout)
// ----------------------------------------------------------------------------
// Signed-in, ONBOARDING-COMPLETE member -> this edge -> server-side price lookup
// (wallet_price_point, ACTIVE only — inactive = denied, so this is INERT until the
// founder activates pricing) -> hosted Checkout Session (mode=payment) with the
// EXACT server-side amount. Credits land ONLY via the signature-verified
// stripe-webhook -> fn_wallet_credit_purchase (idempotent). The card on file never
// authorises this: every top-up is an explicit hosted-checkout confirmation.
// FAIL-CLOSED: no STRIPE_SECRET_KEY -> 424; live key refused without approval.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const LIVE_ALLOWED = (Deno.env.get("STRIPE_LIVE_ALLOWED") ?? "") === "true";
// Canonical production origin (founder-confirmed). The browser return URL is cosmetic —
// credits land ONLY via the signature-verified webhook, never by the return param — but it
// must land on a live origin.
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

async function stripe(path: string, params: Record<string, string>): Promise<{ ok: boolean; data: Record<string, unknown> }> {
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
  return { ok: res.ok, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });
  if (!STRIPE_KEY) return json(424, { status: "PAYMENTS_NOT_CONFIGURED", message: "Credit purchases are not available yet." });
  if (!STRIPE_KEY.startsWith("sk_test_") && !LIVE_ALLOWED) {
    return json(424, { status: "LIVE_MODE_NOT_APPROVED", message: "Live payments are not enabled." });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_ROLE, authorization: authHeader } });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    userId = String(((await u.json()) as { id?: string })?.id ?? "");
  } catch { return json(401, { status: "UNAUTHENTICATED" }); }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  // ---- STRATELOQ mandatory-onboarding gate (edge) BEGIN ----------------------
  // Workspace operation: fail closed via fn_edge_onboarding_allowed (mig_352).
  try {
    const allowed = await rpc("fn_edge_onboarding_allowed", { p_auth_user_id: userId });
    if (allowed !== true) return json(403, { status: "ONBOARDING_INCOMPLETE" });
  } catch { return json(403, { status: "ONBOARDING_INCOMPLETE" }); }
  // ---- STRATELOQ mandatory-onboarding gate (edge) END ------------------------

  let priceCode = "", reqOrigin = "";
  try {
    const b = (await req.json()) as { price_code?: string; origin?: string };
    priceCode = String(b?.price_code ?? "");
    reqOrigin = String(b?.origin ?? "");
  }
  catch { return json(400, { status: "INVALID_JSON" }); }
  if (!priceCode) return json(400, { status: "PRICE_CODE_REQUIRED" });
  const origin = safeReturnOrigin(reqOrigin);
  const successUrl = `${origin}/workspace/billing?topup=success`;
  const cancelUrl = `${origin}/workspace/billing?topup=cancelled`;

  // Server-side price authority: ACTIVE price points only (inactive -> denied; INERT today).
  let pp: { code?: string; amount_eur_cents?: number; credits?: number } | null = null;
  try {
    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/wallet_price_point?code=eq.${encodeURIComponent(priceCode)}&active=eq.true&select=code,amount_eur_cents,credits`,
      { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } });
    const arr = (await r.json()) as Array<Record<string, unknown>>;
    pp = (Array.isArray(arr) ? arr[0] : null) as typeof pp;
  } catch { /* fallthrough */ }
  if (!pp?.code || !pp.amount_eur_cents || !pp.credits) {
    return json(403, { status: "PRICE_POINT_NOT_ACTIVE", message: "This credit package is not available." });
  }

  const s = await stripe("checkout/sessions", {
    mode: "payment",
    client_reference_id: userId,
    "metadata[price_code]": String(pp.code),
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "eur",
    "line_items[0][price_data][unit_amount]": String(pp.amount_eur_cents),
    "line_items[0][price_data][product_data][name]": `Strateloq research credits — ${pp.credits} credits`,
    success_url: successUrl,
    cancel_url: cancelUrl,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, {
    status: "ok", url: String(s.data.url), session_id: String(s.data.id ?? ""),
    quoted: { price_code: pp.code, amount_eur_cents: pp.amount_eur_cents, credits: pp.credits, currency: "EUR" },
  });
});
