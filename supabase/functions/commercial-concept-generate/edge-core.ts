// Pure edge helpers for commercial-concept-generate. Kept out of index.ts (which
// owns Deno.serve + network/RPC I/O) so the deterministic tests can import them
// without starting the HTTP server. Logic here is server-only wiring; the
// rights-safe execution semantics live in ./lane/concept-execution-lane.ts.
import type { ProductVisualIdentityPackSources } from "./lane/pack-sources.ts";
import {
  assertConceptRequestSafe,
  buildConceptGenerationRequest,
  type ConceptGenerationRequest,
  type ConceptScene,
} from "./lane/creative-concept-prep.ts";
import type { ProductVisualIdentityPack } from "./lane/product-visual-identity-pack.ts";

/**
 * Rights-safety pre-check run BEFORE any spend reservation. The lane itself also
 * refuses to call the provider for an unsafe request, but the edge must not consume
 * a paid budget slot for a request that will never be sent. So the edge builds +
 * asserts the request first; only a safe request proceeds to reserve budget and
 * execute. Deterministic and pure (mirrors the lane's own safety invariants).
 */
export function conceptSafetyPrecheck(args: {
  pack: ProductVisualIdentityPack;
  productId: string;
  market: string | null;
  scene: ConceptScene;
  aspectRatio: string;
  founderBrief?: string | null;
}): { safe: boolean; request: ConceptGenerationRequest } {
  const request = buildConceptGenerationRequest(args);
  let safe = true;
  try {
    assertConceptRequestSafe(request);
  } catch {
    safe = false;
  }
  if (/(https?:|data:|www\.)/i.test(request.prompt)) safe = false;
  return { safe, request };
}

/**
 * Explicit spend authorisation decision over fn_provider_budget_try_consume's
 * result. FAIL-CLOSED by construction: the concept is spend-authorised ONLY when
 * a founder-opened budget both exists (`enforced === true`) AND still had a slot
 * to reserve (`allowed === true`). The provider-budget primitive returns
 * {allowed:true, enforced:false} for a provider with NO open budget (its
 * "unenforced" branch); the concept lane treats that as NOT authorised, so a
 * concept is never generated without an explicit, reserved, time-boxed budget.
 */
export function decideSpendAuthorized(consume: Record<string, unknown> | null): boolean {
  if (!consume) return false;
  return consume.allowed === true && consume.enforced === true;
}

const str = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v : null;
const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;
const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
/** supplier_product_id may arrive as a number; stringify it exactly as the client does. */
const idStr = (v: unknown): string | null =>
  typeof v === "number" && Number.isFinite(v) ? String(v) : str(v);

/**
 * Map the raw RPC payloads (fn_product_identity_resolution +
 * fn_product_commercial_asset_readiness) into ProductVisualIdentityPackSources
 * using the SAME field decoding as the Lovable client
 * (fetchProductVisualIdentityPackSources). This guarantees the server computes an
 * identical deterministic identityVersion (identity-version consistency). The edge
 * uses the non-owner readiness RPC (it has already verified ownership itself and
 * calls via service role, where auth.uid() is null); identityVersion depends only
 * on identity-resolution fields, so the owned/non-owned distinction cannot change it.
 */
export function mapPackSources(
  identityJson: unknown,
  readinessJson: unknown,
): ProductVisualIdentityPackSources {
  let identity: ProductVisualIdentityPackSources["identity"] = null;
  if (isObj(identityJson)) {
    const fp = isObj(identityJson.fingerprint) ? identityJson.fingerprint : {};
    identity = {
      identityState: str(identityJson.identity_state),
      label: str(identityJson.label),
      supplierLinkAllowed: identityJson.supplier_link_allowed === true,
      strongIdentifierCount: num(identityJson.strong_identifier_count),
      fingerprint: {
        productName: str(fp.product_name),
        category: str(fp.category),
        brand: str(fp.brand),
        supplierProvider: str(fp.supplier_provider),
        supplierProductId: idStr(fp.supplier_product_id),
        productFamilyKey: str(fp.product_family_key),
        extractionConfidence: num(fp.extraction_confidence),
      },
    };
  }
  let readiness: ProductVisualIdentityPackSources["readiness"] = null;
  if (isObj(readinessJson)) {
    const im = isObj(readinessJson.images) ? readinessJson.images : {};
    const ai = isObj(readinessJson.ai_generation) ? readinessJson.ai_generation : {};
    readiness = {
      images: {
        total: num(im.total),
        hasCustomerOwned: im.has_customer_owned === true,
        hasSupplierAuthorized: im.has_supplier_authorized === true,
        hasMarketplaceReference: im.has_marketplace_reference === true,
      },
      referenceEligible: ai.reference_eligible === true,
      executionState: str(ai.execution_state),
    };
  }
  return { identity, readiness };
}

/** Allowlisted scenes, mirroring the lane's ConceptScene union. */
export const CONCEPT_SCENES = ["CLEAN_STUDIO", "LIFESTYLE", "PRODUCT_IN_USE"] as const;
export function safeScene(v: unknown): (typeof CONCEPT_SCENES)[number] {
  return (CONCEPT_SCENES as readonly string[]).includes(String(v))
    ? (v as (typeof CONCEPT_SCENES)[number])
    : "LIFESTYLE";
}

/** Allowlisted aspect ratios for concept images (no video here). */
export const CONCEPT_ASPECT_RATIOS = ["1:1", "4:5", "16:9"] as const;
export function safeAspectRatio(v: unknown): (typeof CONCEPT_ASPECT_RATIOS)[number] {
  return (CONCEPT_ASPECT_RATIOS as readonly string[]).includes(String(v))
    ? (v as (typeof CONCEPT_ASPECT_RATIOS)[number])
    : "1:1";
}
