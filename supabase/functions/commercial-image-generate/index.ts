// STRATELOQ - Commercial Image Generate (secure, authenticated in-app trigger)
// Signed-in user -> this JWT-protected Edge Function -> server-side tenant/product
// authorization + asset eligibility -> resolves the AUTHORIZED reference server-side
// -> Gemini executor (n8n) -> storage -> Gemini identity validator (Product Asset
// Lock) -> provenance registration -> review-ready result. The browser never sees
// or supplies the reference URL, rights state, tenant, or any provider secret.
//
// CS.04 (BE330, deployed under founder authorisation): the reference is now
// resolved by fn_resolve_authorised_ai_reference,
// which returns an ACTUAL authorised customer-owned / first-party / explicitly-
// licensed / AI-authorised image (or a supplier image carrying EXPLICIT per-image
// AI-input permission), and NEVER a bare supplier (CJ), marketplace or research
// image. The supplier storefront (fn_resolve_storefront_assets) is no longer used
// as a generative source. This closes the "owned-image Gemini generation
// unavailable / supplier substitution" gap recorded in BE325/BE326 while keeping
// the BE324/BE326 fail-closed readiness gate and Product Asset Lock intact.
//
// BE329: for an authorised private storage object, this edge signs a FRESH
// short-lived URL at execution time (never a stored long-lived signed URL), and
// fails closed on sign failure — it never falls back to a stale URL and never
// substitutes any other image.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("N8N_GEMINI_WEBHOOK_SECRET") ?? Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";
const EXECUTOR_WEBHOOK = Deno.env.get("N8N_GEMINI_EXECUTOR_WEBHOOK") ?? "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-commercial-image";
const VALIDATOR_WEBHOOK = Deno.env.get("N8N_GEMINI_VALIDATOR_WEBHOOK") ?? "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-identity-validate";
const BUCKET = "pulse-generated-media";
const RATE_WINDOW_SEC = 600;
const RATE_MAX = 12;
// BE344 P1 — image model is now configurable (env-overridable), not hard-coded, so the
// recommended replacement can be set without a code change. CURRENT OFFICIAL STATUS
// (ai.google.dev, 2026-11-28): gemini-2.5-flash-image is GA and still live; it is
// DEPRECATED with an earliest shutdown of 2027-03-15 (NOT Oct 2026 — Oct 2 2025 was its
// release date), recommended replacement gemini-3.1-flash-lite-image (or
// gemini-nano-banana-2.1). MIGRATION NOTE: the newer image models are documented only on
// the new Interactions API (POST /v1beta/interactions, header Api-Revision:2026-05-20,
// input:[{type:text},{type:image,mime_type,data(base64)}], output in interaction.output_image.data),
// NOT :generateContent+inline_data. The actual provider call lives in the n8n workflow
// (N8N_GEMINI_EXECUTOR_WEBHOOK), so switching models is: set PULSE_GEMINI_IMAGE_MODEL +
// migrate that workflow to the Interactions API. No urgent change is required before 2027.
const IMAGE_MODEL = Deno.env.get("PULSE_GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";

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

// Sign a short-lived URL for a private storage object "bucket/path..." so the
// executor can fetch an owned/licensed reference image that has no public URL.
async function signStorageRef(ref: string): Promise<string> {
  const slash = ref.indexOf("/");
  if (slash <= 0) return "";
  const bucket = ref.slice(0, slash);
  const path = ref.slice(slash + 1);
  if (!path) return "";
  const s = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${bucket}/${path}`, {
    method: "POST", headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}`, "content-type": "application/json" },
    body: JSON.stringify({ expiresIn: 600 }),
  });
  if (!s.ok) return "";
  const sj = await s.json();
  return sj?.signedURL ? `${SUPABASE_URL}/storage/v1${sj.signedURL}` : "";
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

  // ---- STRATELOQ mandatory-onboarding gate (edge) BEGIN ----------------------
  // Protected customer workspace operation (provider-backed image generation):
  // onboarding is enforced SERVER-SIDE via fn_edge_onboarding_allowed (mig_352,
  // service_role only) — TRUE only when enforcement is definitely OFF or this
  // member's onboarding is definitely complete; any error DENIES (fail closed).
  // While onboarding_policy.enforcement_active = FALSE this always allows (no-op).
  try {
    const allowed = await rpc("fn_edge_onboarding_allowed", { p_auth_user_id: userId });
    if (allowed !== true) return json(403, { status: "ONBOARDING_INCOMPLETE" });
  } catch { return json(403, { status: "ONBOARDING_INCOMPLETE" }); }
  // ---- STRATELOQ mandatory-onboarding gate (edge) END ------------------------

  // ---- BE346: Ad Creative Studio FOUNDER-ONLY gate (edge) BEGIN ---------------
  // Image generation is part of the founder-only Ad Creative Studio. Check the
  // RESOLVED signed-in user via fn_is_founder_uid — NOT fn_is_founder(), which
  // returns true for the service role this edge runs as. Fail closed on any error.
  try {
    const founder = await rpc("fn_is_founder_uid", { p_auth_user_id: userId });
    if (founder !== true) return json(403, { status: "FOUNDER_ONLY", message: "The Ad Creative Studio is available to the founder only." });
  } catch { return json(403, { status: "FOUNDER_ONLY" }); }
  // ---- BE346: Ad Creative Studio FOUNDER-ONLY gate (edge) END -----------------

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

  // --- Resolve the AUTHORIZED reference server-side (never from the browser, never a supplier substitute) ---
  // CS.04 FAIL-CLOSED: fn_resolve_authorised_ai_reference returns an ACTUAL authorised customer-owned /
  // first-party / explicitly-licensed / AI-authorised image, or a supplier image with EXPLICIT per-image
  // AI-input permission. It mirrors the BE324/BE326 readiness gate at the per-image level and NEVER returns a
  // bare supplier, marketplace or research image. The supplier storefront is no longer a generative source.
  let refUrl = ""; let refProvider = ""; let refRights = ""; let refBasis = ""; let refAssetId: string | null = null;
  try {
    const ref = (await rpc("fn_resolve_authorised_ai_reference", { p_tenant: userId, p_product_id: productId, p_market: market })) as Record<string, unknown>;
    if (String(ref?.status ?? "") !== "AUTHORISED_REFERENCE_AVAILABLE") {
      return json(200, { status: "NOT_ELIGIBLE", reason: "NO_AUTHORIZED_REFERENCE",
        message: "No rights-cleared reference image is available to generate from. Upload an owned or licensed product image, or obtain written per-image AI-use permission." });
    }
    const r = (ref.reference ?? {}) as Record<string, unknown>;
    refProvider = String(r.source_provider ?? "");
    refRights = String(r.rights_state ?? "");
    refBasis = String(r.origin_basis ?? "");
    refAssetId = r.asset_id ? String(r.asset_id) : null;
    const storageRefIn = String(r.storage_ref ?? "");
    const imageUrlIn = String(r.image_url ?? "");
    const sourceUrlIn = String(r.source_url ?? "");
    if (storageRefIn) {
      // Authoritative private storage object ("bucket/path"): ALWAYS mint a FRESH short-lived signed URL
      // at execution time. Never rely on a stored long-lived signed URL (it has a fixed expiry and can be
      // invalidated). If signing fails, fail CLOSED with a retryable technical error — never fall back to a
      // stale URL, and never substitute a different (e.g. supplier) image. The resolver has already excluded
      // all unauthorised sources, so there is no supplier image to substitute here.
      refUrl = await signStorageRef(storageRefIn);
      if (!refUrl) return fail("REFERENCE_RESOLUTION_FAILED", "could not sign authorised private reference");
    } else if (/^https:\/\//i.test(imageUrlIn)) {
      // No private storage object: use the authorised asset's own public URL (e.g. a first-party/licensed CDN image).
      refUrl = imageUrlIn;
    } else if (/^https:\/\//i.test(sourceUrlIn)) {
      refUrl = sourceUrlIn;
    }
  } catch (e) { return fail("REFERENCE_RESOLUTION_FAILED", (e as Error).message); }
  if (!refUrl) return json(200, { status: "NOT_ELIGIBLE", reason: "NO_AUTHORIZED_REFERENCE", message: "No fetchable rights-cleared reference image is available to generate from." });

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
      p_reference: { url: refUrl, provider: refProvider, rights_state: refRights, origin_basis: refBasis, asset_id: refAssetId },
      p_generation: { provider: "GOOGLE_GEMINI", model: IMAGE_MODEL, workflow: "OYjIUMd0GS7OanbY", job_id: usedJobId, attempts: attempt, bucket: BUCKET, mime: "image/png", width: 1024, height: 1024 },
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
      provider: "GOOGLE_GEMINI", model: IMAGE_MODEL,
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
    reference_basis: refBasis,
    provider: "GOOGLE_GEMINI",
    model: IMAGE_MODEL,
    scene,
    auto_published: false,
  });
});
