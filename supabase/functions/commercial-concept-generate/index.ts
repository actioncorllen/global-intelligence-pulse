// STRATELOQ — Commercial CONCEPT Generate (secure, authenticated in-app trigger).
// BE343 PREPARED ARTIFACT — committed, NOT deployed. Companion migration:
// supabase/migrations/mig_380_be343_original_concept_provenance.sql.
//
// This is the deployable server edge for the rights-safe AI Concept lane. It
// REUSES the tested execution logic verbatim (./lane/concept-execution-lane.ts,
// the canonical server copy of the BE342 Vitest-covered module) and adds only the
// Supabase/Deno wiring + real adapters. There is NO second, divergent concept
// implementation.
//
// It is the ORIGINAL_CONCEPT sibling of commercial-image-generate, and differs on
// purpose: a concept is an ORIGINAL, UNBRANDED, TEXT-ONLY image used for ideation,
// never a depiction of the real product. So this edge:
//   * sends the provider ONLY a rights-safe text prompt (no reference image, no
//     supplier/marketplace pixels, no external image URL — text-to-image);
//   * does NOT run Product Asset Lock identity validation (a concept is explicitly
//     NOT product-verified: identityValidated=false);
//   * stores output PRIVATELY and registers ORIGINAL_CONCEPT provenance in a table
//     that is structurally separate from commercial assets, with no promotion /
//     clearance / publish path;
//   * requires EXPLICIT, reserved, time-boxed spend authorisation via the existing
//     provider-budget primitive before any paid provider call.
//
// Server-side enforcement (founder BE343 P1 checklist):
//  (1) Authentication + (2) tenant ownership .... JWT user == commerce_products.user_id
//  (3) Product + market isolation ............... owner-scoped product; market passed through
//  (4) Permitted text-only input ................ lane builds a text prompt; assertConceptRequestSafe
//  (5) No supplier/marketplace image pixels ..... provider receives { prompt } only
//  (6) No external image URL references ......... URLISH guard on prompt + brief URL-stripping
//  (7) Identity-version consistency ............. identityVersion computed server-side, recorded
//  (8) Explicit spending authorisation .......... fn_provider_budget_try_consume (enforced && allowed)
//  (9) Budget reservation + limits .............. atomic reserve of a founder-opened max_calls/TTL budget
// (10) Private output storage ................... pulse-generated-media (private bucket), never public
// (11) Accurate generated-asset provenance ..... fn_register_concept_asset (ORIGINAL_CONCEPT)
// (12) No automatic product-identity validation . no Product Asset Lock here (identityValidated=false)
// (13) No automatic commercial clearance/export . separate table, no selected/publish; promotion refused
//      Revocation + rights enforcement .......... onboarding gate + revocable/expiring spend budget
//
// NO paid provider call occurs unless a founder-opened budget is reserved. The
// Gemini text-to-image executor webhook is wired at deploy time; nothing here runs
// in CI or at import (Deno.serve is the only side effect).

import {
  executeConceptLane,
  rejectConceptPromotion,
  type ConceptLaneArgs,
} from "./lane/concept-execution-lane.ts";
import { buildProductVisualIdentityPack } from "./lane/product-visual-identity-pack.ts";
import {
  conceptSafetyPrecheck,
  decideSpendAuthorized,
  mapPackSources,
  safeAspectRatio,
  safeScene,
} from "./edge-core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET =
  Deno.env.get("N8N_GEMINI_WEBHOOK_SECRET") ?? Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";
// TEXT-TO-IMAGE executor (no source image). Wired at deploy time to a Gemini
// gemini-2.5-flash-image text-to-image workflow. Distinct from the image edge's
// image-to-image executor so a reference photo can never be attached here.
const CONCEPT_EXECUTOR_WEBHOOK =
  Deno.env.get("N8N_GEMINI_CONCEPT_EXECUTOR_WEBHOOK") ??
  "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-original-concept";
const BUCKET = "pulse-generated-media";
const PROVIDER_BUDGET_KEY = "GEMINI_CONCEPT";
const PROVIDER_ID = "GOOGLE_GEMINI";
// Env-overridable (BE344 P1): gemini-2.5-flash-image is GA + live until an earliest
// shutdown of 2027-03-15 (recommended replacement gemini-3.1-flash-lite-image /
// gemini-nano-banana-2.1). Switching models = set PULSE_GEMINI_IMAGE_MODEL + migrate the
// text-to-image workflow to the new Interactions API (/v1beta/interactions); no code change.
const PROVIDER_MODEL = Deno.env.get("PULSE_GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
const RATE_WINDOW_SEC = 600;
const RATE_MAX = 12;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json", "cache-control": "no-store" },
  });
}

// Retryable operational failure (HTTP 200 + discriminated status, so the browser's
// supabase.functions.invoke resolves cleanly). Never the spend/rights gate.
function fail(status: string, detail: string): Response {
  return json(200, {
    status,
    usable: false,
    retryable: true,
    detail,
    message: "Concept generation didn't complete. Please try again.",
  });
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_ROLE,
      authorization: `Bearer ${SERVICE_ROLE}`,
    },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  let parsed: unknown = null;
  try {
    parsed = txt ? JSON.parse(txt) : null;
  } catch {
    parsed = txt;
  }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 200)}`);
  return parsed;
}

async function callWebhook(
  url: string,
  body: unknown,
): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(WEBHOOK_SECRET ? { "x-pulse-webhook-secret": WEBHOOK_SECRET } : {}),
    },
    body: JSON.stringify(body),
  });
  const txt = await res.text();
  let data: Record<string, unknown> = {};
  try {
    data = txt ? JSON.parse(txt) : {};
  } catch {
    data = { raw: txt };
  }
  return { ok: res.ok, status: res.status, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });

  // (1) Authentication — resolve the signed-in user from their JWT (server-side).
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_ROLE, authorization: authHeader },
    });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    const uj = await u.json();
    userId = String(uj?.id ?? "");
  } catch {
    return json(401, { status: "UNAUTHENTICATED" });
  }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  // (13) Revocation/rights — mandatory-onboarding gate (fail closed on any error).
  try {
    const allowed = await rpc("fn_edge_onboarding_allowed", { p_auth_user_id: userId });
    if (allowed !== true) return json(403, { status: "ONBOARDING_INCOMPLETE" });
  } catch {
    return json(403, { status: "ONBOARDING_INCOMPLETE" });
  }

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return json(400, { status: "INVALID_JSON" });
  }
  const productId = String(body.product_id ?? "");
  const market = body.market ? String(body.market) : null;
  const scene = safeScene(body.scene);
  const aspectRatio = safeAspectRatio(body.aspect_ratio);
  const founderBrief = typeof body.founder_brief === "string" ? body.founder_brief : null;
  const requestId = String(body.request_id ?? crypto.randomUUID());
  if (!/^[0-9a-f-]{36}$/i.test(productId)) return json(400, { status: "INVALID_PRODUCT" });

  // (2) Tenant/product ownership — never trust the browser.
  let product: Record<string, unknown> | null = null;
  try {
    const pr = await fetch(
      `${SUPABASE_URL}/rest/v1/commerce_products?id=eq.${productId}&select=id,user_id,title`,
      { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } },
    );
    const arr = await pr.json();
    product = Array.isArray(arr) ? (arr[0] ?? null) : null;
  } catch {
    /* fallthrough */
  }
  if (!product) return json(404, { status: "PRODUCT_NOT_FOUND" });
  if (String(product.user_id) !== userId) return json(403, { status: "CROSS_TENANT_REJECTED" });

  // Rate / abuse protection (per tenant) over the concept table.
  try {
    const since = new Date(Date.now() - RATE_WINDOW_SEC * 1000).toISOString();
    const rl = await fetch(
      `${SUPABASE_URL}/rest/v1/concept_generated_assets?tenant_id=eq.${userId}&created_at=gte.${since}&select=id`,
      {
        headers: {
          apikey: SERVICE_ROLE,
          authorization: `Bearer ${SERVICE_ROLE}`,
          Prefer: "count=exact",
        },
      },
    );
    const cr = rl.headers.get("content-range") ?? "";
    const n = Number(cr.split("/")[1] ?? "0");
    if (n >= RATE_MAX)
      return json(429, {
        status: "RATE_LIMITED",
        message: "Too many concept generations recently. Please wait a moment and try again.",
      });
  } catch {
    /* non-fatal */
  }

  // (6)+(7) Build the Product Visual Identity Pack server-side from authoritative
  // identity resolution + readiness, so identityVersion is authoritative (never
  // browser-supplied). The edge already verified ownership, so it uses the
  // non-owner readiness RPC via service role (auth.uid() is null here).
  let identityJson: unknown = null;
  let readinessJson: unknown = null;
  try {
    identityJson = await rpc("fn_product_identity_resolution", { p_product_id: productId });
    readinessJson = await rpc("fn_product_commercial_asset_readiness", {
      p_product_id: productId,
      p_market: market,
    });
  } catch (e) {
    return fail("IDENTITY_SOURCES_FAILED", (e as Error).message);
  }
  const pack = buildProductVisualIdentityPack(mapPackSources(identityJson, readinessJson));

  // (4)+(5)+(6) Rights-safety pre-check BEFORE any spend reservation, so a blocked /
  // unsafe request never consumes a paid budget slot (BE344 P2 hardening). The lane
  // re-validates and still refuses to call the provider for an unsafe request; this
  // only moves the refusal ahead of the budget reservation.
  const pre = conceptSafetyPrecheck({ pack, productId, market, scene, aspectRatio, founderBrief });
  if (!pre.safe) {
    return json(200, {
      status: "BLOCKED_UNSAFE_REQUEST",
      usable: false,
      label: pre.request.label,
      blocked_reasons: pre.request.blockedReasons,
      message: "This concept request could not be made rights-safe and was not executed.",
    });
  }

  // (8)+(9) Explicit spend authorisation + budget reservation. Reserve ONE slot of
  // a founder-opened GEMINI_CONCEPT budget (max_calls + TTL). FAIL-CLOSED: spend is
  // authorised only when a budget was explicitly opened AND a slot remained
  // (enforced && allowed). With no open budget, the concept is PREPARED_NOT_EXECUTED
  // and the provider is NEVER called. Reserved only AFTER the safety pre-check passes
  // and immediately before the provider call, so an unsafe request burns no budget.
  let spendApproved = false;
  try {
    const consume = (await rpc("fn_provider_budget_try_consume", {
      p_provider: PROVIDER_BUDGET_KEY,
      p_user_id: userId,
      p_market: market,
    })) as Record<string, unknown>;
    spendApproved = decideSpendAuthorized(consume);
  } catch {
    spendApproved = false; // fail closed
  }

  // Real adapters. The provider receives ONLY the text prompt (text-to-image).
  const provider: ConceptLaneArgs["provider"] = {
    id: PROVIDER_ID,
    model: PROVIDER_MODEL,
    generate: async ({ prompt, aspectRatio }) => {
      const jobId = `ccg-${requestId}`;
      // Defence in depth: never forward anything URL-ish to the provider.
      if (/(https?:|data:|www\.)/i.test(prompt)) throw new Error("prompt_url_blocked");
      const gen = await callWebhook(CONCEPT_EXECUTOR_WEBHOOK, {
        job_id: jobId,
        mode: "TEXT_TO_IMAGE",
        prompt,
        aspect_ratio: aspectRatio,
        size: "1024x1024",
        // NB: no source_image_url — concepts are generated from text only.
      });
      const d = gen.data ?? {};
      if (!gen.ok || d.ok === false || !d.storage_path) {
        throw new Error(`concept_exec:${String(d.reason ?? d.detail ?? gen.status)}`);
      }
      return { bytesRef: String(d.storage_path) };
    },
  };
  const storage: ConceptLaneArgs["storage"] = {
    // (10) The executor writes into the PRIVATE pulse-generated-media bucket; we
    // only form the private object ref. No public URL is ever minted here.
    putPrivate: (bytesRef) => Promise.resolve({ privateRef: `${BUCKET}/${bytesRef}` }),
  };

  let result;
  try {
    result = await executeConceptLane({
      pack,
      productId,
      market,
      ownerId: String(product.user_id),
      authUserId: userId,
      scene,
      aspectRatio,
      founderBrief,
      spendApproved,
      provider,
      storage,
    });
  } catch (e) {
    return fail("GENERATION_FAILED", (e as Error).message);
  }

  if (result.status === "unauthorized")
    return json(403, { status: "CROSS_TENANT_REJECTED" });
  if (result.status === "unsafe_request")
    return json(200, {
      status: "BLOCKED_UNSAFE_REQUEST",
      usable: false,
      label: result.request.label,
      blocked_reasons: result.request.blockedReasons,
      message: "This concept request could not be made rights-safe and was not executed.",
    });
  if (result.status === "spend_approval_required")
    return json(200, {
      status: "PREPARED_NOT_EXECUTED",
      usable: false,
      execution_state: "PREPARED_NOT_EXECUTED",
      label: result.request.label,
      identity_version: result.request.identityVersion,
      prompt_preview: result.request.prompt,
      requires_founder_spend_approval: true,
      message:
        "Concept prepared. Generation requires an explicit founder-opened spend budget (GEMINI_CONCEPT); nothing was generated.",
    });

  // (11) Persist ORIGINAL_CONCEPT provenance (separate table; no commercial status).
  let reg: Record<string, unknown>;
  try {
    reg = (await rpc("fn_register_concept_asset", {
      p_tenant: userId,
      p_product_id: productId,
      p_market: market,
      p_storage_ref: result.privateRef,
      p_generation: {
        provider: PROVIDER_ID,
        model: PROVIDER_MODEL,
        job_id: `ccg-${requestId}`,
        bucket: BUCKET,
        mime: "image/png",
        scene,
        aspect_ratio: aspectRatio,
      },
      p_provenance: result.provenance,
    })) as Record<string, unknown>;
  } catch (e) {
    return fail("PROVENANCE_FAILED", (e as Error).message);
  }
  if (reg?.ok !== true) return fail("PROVENANCE_FAILED", String(reg?.error ?? "register_failed"));

  // (12) A concept can never be promoted to a verified commercial asset.
  const promotion = rejectConceptPromotion(reg);

  return json(200, {
    status: "CONCEPT_READY_FOR_REVIEW",
    usable: false, // review-only: a concept is NOT a usable commercial/product asset
    execution_state: "EXECUTED",
    concept_asset_id: reg.concept_asset_id,
    classification: "AI_CONCEPT_NOT_PRODUCT_VERIFIED",
    label: result.request.label,
    identity_version: result.provenance.outputIdentityVersion,
    rights_state: "ORIGINAL_CONCEPT",
    identity_validated: false,
    provider: PROVIDER_ID,
    model: PROVIDER_MODEL,
    scene,
    aspect_ratio: aspectRatio,
    promotion_allowed: promotion.allowed, // always false
    auto_published: false,
    message:
      "AI concept generated for review. It is an original, unbranded concept — NOT a verified depiction of the real product — and cannot be published or exported as a product image.",
  });
});
