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
const APP_ORIGIN = Deno.env.get("STRATELOQ_APP_ORIGIN") ?? "https://globalintelligenceactions.com";
const SUCCESS_URL = Deno.env.get("STRIPE_TOPUP_SUCCESS_URL") ?? `${APP_ORIGIN}/workspace/billing?topup=success`;
const CANCEL_URL = Deno.env.get("STRIPE_TOPUP_CANCEL_URL") ?? `${APP_ORIGIN}/workspace/billing?topup=cancelled`;

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

  let priceCode = "";
  try { priceCode = String(((await req.json()) as { price_code?: string })?.price_code ?? ""); }
  catch { return json(400, { status: "INVALID_JSON" }); }
  if (!priceCode) return json(400, { status: "PRICE_CODE_REQUIRED" });

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
    success_url: SUCCESS_URL,
    cancel_url: CANCEL_URL,
  });
  if (!s.ok || !s.data.url) return json(502, { status: "SESSION_CREATE_FAILED" });
  return json(200, {
    status: "ok", url: String(s.data.url), session_id: String(s.data.id ?? ""),
    quoted: { price_code: pp.code, amount_eur_cents: pp.amount_eur_cents, credits: pp.credits, currency: "EUR" },
  });
});
