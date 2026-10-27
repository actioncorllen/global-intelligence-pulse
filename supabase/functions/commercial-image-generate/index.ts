// STRATELOQ - Commercial Image Generate (secure, authenticated in-app trigger)
// Signed-in user -> this JWT-protected Edge Function -> server-side tenant/product
// authorization + asset eligibility -> resolves the AUTHORIZED reference server-side
// -> Gemini executor (n8n) -> storage -> Gemini identity validator (Product Asset
// Lock) -> provenance registration -> review-ready result. The browser never sees
// or supplies the reference URL, rights state, tenant, or any provider secret.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("N8N_GEMINI_WEBHOOK_SECRET") ?? Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";
const EXECUTOR_WEBHOOK = Deno.env.get("N8N_GEMINI_EXECUTOR_WEBHOOK") ?? "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-commercial-image";
const VALIDATOR_WEBHOOK = Deno.env.get("N8N_GEMINI_VALIDATOR_WEBHOOK") ?? "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-identity-validate";
const BUCKET = "pulse-generated-media";
const RATE_WINDOW_SEC = 600;
const RATE_MAX = 12;

// Browser-invoked (supabase.functions.invoke) — must answer the CORS preflight.
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SCENES: Record<string, string> = {
  CLEAN_STUDIO: "Place it on a clean seamless neutral studio background with soft even studio lighting and a subtle natural shadow; premium sharp e-commerce hero product photograph.",
  LIFESTYLE: "Place it in a tasteful, realistic lifestyle setting appropriate to this product, with warm natural lighting and a softly blurred background; premium e-commerce lifestyle photograph.",
  PRODUCT_IN_USE: "Show it naturally in use in a realistic everyday setting appropriate to this product, with warm natural lighting and a softly blurred background; premium e-commerce photograph.",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "content-type": "application/json", "cache-control": "no-store" } });
}

// Operational pipeline failure (an EXPECTED runtime outcome on a legitimate,
// authorized request — e.g. Gemini returns 200 with finishReason IMAGE_OTHER and
// declines to render, the n8n executor errors, storage/provenance hiccups). These
// return HTTP 200 with a discriminated `status` so the browser's
// supabase.functions.invoke() RESOLVES cleanly: a non-2xx makes invoke THROW,
// which hides this body from the client and trips the app's error overlay. The
// frontend branches on `status` and shows the retryable technical-failure UX
// ("Image generation didn't complete. Please try again." → Try again).
// This is NEVER the identity gate: a generated candidate that fails Product Asset
// Lock is IDENTITY_VALIDATION_FAILED (a real candidate to inspect), not this.
function fail(status: string, detail: string): Response {
  return json(200, {
    status,
    usable: false,
    retryable: true,
    detail,
    message: "Image generation didn't complete. Please try again.",
  });
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  let parsed: unknown = null; try { parsed = txt ? JSON.parse(txt) : null; } catch { parsed = txt; }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 200)}`);
  return parsed;
}

async function callWebhook(url: string, body: unknown): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...(WEBHOOK_SECRET ? { "x-pulse-webhook-secret": WEBHOOK_SECRET } : {}) },
    body: JSON.stringify(body),
  });
  const txt = await res.text();
  let data: Record<string, unknown> = {}; try { data = txt ? JSON.parse(txt) : {}; } catch { data = { raw: txt }; }
  return { ok: res.ok, status: res.status, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  // CORS preflight — the browser sends OPTIONS before the authenticated POST.
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });

  // --- Authentication: resolve the signed-in user from their JWT (server-side) ---
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_ROLE, authorization: authHeader } });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    const uj = await u.json();
    userId = String(uj?.id ?? "");
  } catch { return json(401, { status: "UNAUTHENTICATED" }); }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  let body: Record<string, unknown>;
  try { body = (await req.json()) as Record<string, unknown>; } catch { return json(400, { status: "INVALID_JSON" }); }
  const productId = String(body.product_id ?? "");
  const market = body.market ? String(body.market) : null;
  const scene = SCENES[String(body.scene ?? "LIFESTYLE")] ? String(body.scene ?? "LIFESTYLE") : "LIFESTYLE";
  const requestId = String(body.request_id ?? crypto.randomUUID());
  if (!/^[0-9a-f-]{36}$/i.test(productId)) return json(400, { status: "INVALID_PRODUCT" });

  // --- Server-side tenant/product ownership (never trust the browser) ---
  let product: Record<string, unknown> | null = null;
  try {
    const pr = await fetch(`${SUPABASE_URL}/rest/v1/commerce_products?id=eq.${productId}&select=id,user_id,title`, { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } });
    const arr = await pr.json(); product = Array.isArray(arr) ? arr[0] ?? null : null;
  } catch { /* fallthrough */ }
  if (!product) return json(404, { status: "PRODUCT_NOT_FOUND" });
  if (String(product.user_id) !== userId) return json(403, { status: "CROSS_TENANT_REJECTED" });
  const title = String(product.title ?? "product");

  // --- Rate / abuse protection (per tenant) ---
  try {
    const since = new Date(Date.now() - RATE_WINDOW_SEC * 1000).toISOString();
    const rl = await fetch(`${SUPABASE_URL}/rest/v1/commerce_generated_assets?tenant_id=eq.${userId}&created_at=gte.${since}&select=id`, { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}`, Prefer: "count=exact" } });
    const cr = rl.headers.get("content-range") ?? ""; const n = Number((cr.split("/")[1] ?? "0"));
    if (n >= RATE_MAX) return json(429, { status: "RATE_LIMITED", message: "Too many image generations recently. Please wait a moment and try again." });
  } catch { /* non-fatal */ }

  // --- Authoritative eligibility gate (server-side) ---
  let readiness: Record<string, unknown>;
  try { readiness = (await rpc("fn_product_commercial_asset_readiness", { p_product_id: productId, p_market: market })) as Record<string, unknown>; }
  catch (e) { return fail("ELIGIBILITY_CHECK_FAILED", (e as Error).message); }
  const ai = (readiness?.ai_generation ?? {}) as Record<string, unknown>;
  if (ai.reference_eligible !== true || ai.execution_state !== "AVAILABLE") {
    return json(200, { status: "NOT_ELIGIBLE", reason: readiness?.commercial_asset_readiness ?? "NOT_ELIGIBLE",
      message: String(ai.requires ?? "A customer-owned or supplier-authorized image is required.") });
  }

  // --- Resolve the AUTHORIZED reference server-side (never from the browser) ---
  let refUrl = ""; let refProvider = ""; let refRights = ""; let supplierProductId: string | null = null;
  try {
    const sup = (await rpc("fn_product_supplier_identity", { p_product_id: productId })) as Record<string, unknown>;
    refProvider = String(sup?.provider ?? ""); supplierProductId = sup?.supplier_product_id ? String(sup.supplier_product_id) : null;
    if (sup?.has_supplier === true && supplierProductId) {
      const resolved = (await rpc("fn_resolve_storefront_assets", { p_supplier: refProvider, p_supplier_product_id: supplierProductId, p_market: market })) as Record<string, unknown>;
      const primary = (resolved?.primary_image ?? {}) as Record<string, unknown>;
      refUrl = String(primary?.source_url ?? ""); refRights = "SUPPLIER_PROVIDED";
    }
  } catch (e) { return fail("REFERENCE_RESOLUTION_FAILED", (e as Error).message); }
  if (!refUrl) return json(200, { status: "NOT_ELIGIBLE", reason: "NO_AUTHORIZED_REFERENCE", message: "No rights-cleared reference image is available to generate from." });

  // --- Build the product-preserving prompt from an allowlisted scene ---
  // Product Asset Lock is enforced by the identity validator; this prompt only
  // steers generation toward preserving the EXACT product (it never weakens the gate).
  const prompt = `Reproduce the EXACT product from the provided reference photo, pixel-faithful, as the single subject. Keep THIS SAME ${title} completely unchanged and identical to the reference: same overall shape and silhouette, housing and body, the exact base and its control interface (do NOT add, remove, or change any buttons, switches, touch controls, ports or indicators — if the reference base is a smooth touch-control base, keep it smooth with no physical buttons), the lens/projector head, gooseneck/arm, wings/panels and every accessory, the same proportions, materials, textures, finish and colour, and the same projected pattern if any. Do NOT redesign, stylise, beautify, or substitute the product or any of its parts, and do NOT invent a different or generic ${title}. Only the surrounding scene may change: ${SCENES[scene]} Do not add any text, words, letters, numbers, logos, badges, price tags, stickers, watermarks, UI overlays, ratings, reviews, people's faces or promotional graphics.`;

  // --- Secure server-to-server generation (Gemini executor) ---
  // Bounded resilience for Gemini's intermittent render refusal: Gemini can
  // return HTTP 200 with finishReason IMAGE_OTHER and produce no image. The
  // executor reports exactly that case as {ok:false, reason:"IMAGE_OTHER"}
  // (no image, no storage object, no candidate). Retry it EXACTLY once, with the
  // SAME server-resolved authorized reference and the SAME product-preservation
  // prompt. No other outcome is ever retried (identity rejection, storage,
  // provenance, eligibility, rights, auth, rate-limit and arbitrary provider
  // errors all fall straight through). Hard cap: 2 Gemini attempts per action.
  const baseJobId = `cig-${requestId}`;
  const MAX_ATTEMPTS = 2;
  let gen: { ok: boolean; status: number; data: Record<string, unknown> } | null = null;
  let usedJobId = baseJobId;
  let attempt = 0;
  while (attempt < MAX_ATTEMPTS) {
    attempt++;
    usedJobId = `${baseJobId}-a${attempt}`;
    try {
      gen = await callWebhook(EXECUTOR_WEBHOOK, { job_id: usedJobId, source_image_url: refUrl, prompt, size: "1024x1024", attempt });
    } catch (e) { return fail("GENERATION_FAILED", `attempt${attempt}:${(e as Error).message}`); }
    const d = gen.data ?? {};
    // Success: an image with a storage path.
    if (gen.ok && d.ok !== false && d.storage_path) break;
    // ONLY the IMAGE_OTHER render refusal is retried, and only once.
    if (d.reason === "IMAGE_OTHER" && attempt < MAX_ATTEMPTS) continue;
    // Second IMAGE_OTHER, or any other executor failure → stop; no more calls.
    return fail("GENERATION_FAILED", `attempt${attempt}:${String(d.reason ?? d.detail ?? gen.status)}`);
  }
  const storagePath = String(gen!.data.storage_path ?? "");
  const storageRef = String(gen!.data.storage_ref ?? (storagePath ? `${BUCKET}/${storagePath}` : ""));
  if (!storagePath) return fail("STORAGE_FAILED", "no storage path returned");

  // --- Signed URL for in-app review/inspection (tenant-scoped, short lived) ---
  // Computed for BOTH outcomes so a rejected candidate can be shown for
  // inspection; it never authorizes use — only the server verdict does.
  let signedUrl: string | null = null;
  try {
    const s = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${BUCKET}/${storagePath}`, {
      method: "POST", headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}`, "content-type": "application/json" },
      body: JSON.stringify({ expiresIn: 3600 }),
    });
    if (s.ok) { const sj = await s.json(); if (sj?.signedURL) signedUrl = `${SUPABASE_URL}/storage/v1${sj.signedURL}`; }
  } catch { /* non-fatal */ }

  // --- Product Asset Lock: mandatory identity validation ---
  let verdict: Record<string, unknown> = { verdict: "PENDING" };
  try {
    const val = await callWebhook(VALIDATOR_WEBHOOK, { reference_url: refUrl, generated_path: storagePath });
    verdict = (val.data.identity_validation ?? val.data) as Record<string, unknown>;
  } catch (e) { verdict = { verdict: "VALIDATION_ERROR", error: (e as Error).message }; }

  // --- Persist honest provenance (generation + reference + identity) ---
  let reg: Record<string, unknown>;
  try {
    reg = (await rpc("fn_register_generated_commercial_asset", {
      p_tenant: userId, p_product_id: productId, p_storage_ref: storageRef,
      p_reference: { url: refUrl, provider: refProvider, rights_state: refRights },
      p_generation: { provider: "GOOGLE_GEMINI", model: "gemini-2.5-flash-image", workflow: "OYjIUMd0GS7OanbY", job_id: usedJobId, attempts: attempt, bucket: BUCKET, mime: "image/png", width: 1024, height: 1024 },
      p_identity: verdict,
    })) as Record<string, unknown>;
  } catch (e) { return fail("PROVENANCE_FAILED", (e as Error).message); }

  const idState = String(reg.identity_validation_status ?? "PENDING_IDENTITY_VALIDATION");
  if (idState !== "IDENTITY_VALIDATED") {
    // Server-authoritative rejection. The signed URL is returned only so the
    // customer can inspect why it failed; the candidate is NOT usable.
    return json(200, { status: "IDENTITY_VALIDATION_FAILED", generated_asset_id: reg.generated_asset_id,
      identity_validation_status: idState, identity_validation: verdict,
      commercial_asset_status: reg.commercial_asset_status, signed_url: signedUrl, usable: false,
      provider: "GOOGLE_GEMINI", model: "gemini-2.5-flash-image",
      message: "The generated image changed the product too much and can't be used." });
  }

  return json(200, {
    status: "READY_FOR_REVIEW",
    generated_asset_id: reg.generated_asset_id,
    commercial_asset_status: reg.commercial_asset_status,
    identity_validation_status: idState,
    identity_validation: verdict,
    usable: true,
    storage_ref: storageRef,
    signed_url: signedUrl,
    provider: "GOOGLE_GEMINI",
    model: "gemini-2.5-flash-image",
    scene,
    auto_published: false,
  });
});
