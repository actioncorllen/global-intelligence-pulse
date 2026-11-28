// Deterministic tests for the commercial-concept-generate server lane.
// Run: `deno test supabase/functions/commercial-concept-generate/concept-lane.test.ts`
// Self-contained (no remote deps): mocked provider + storage; NO paid call, NO
// network, NO deploy. Covers the same invariants as the BE342 Vitest suite over the
// canonical Lovable copy, plus the edge-only helpers (spend decision, server-side
// pack-source mapping + identity-version determinism).
import {
  executeConceptLane,
  executeConceptPack,
  rejectConceptPromotion,
  type ConceptLaneArgs,
} from "./lane/concept-execution-lane.ts";
import {
  buildProductVisualIdentityPack,
  type ProductVisualIdentityPack,
} from "./lane/product-visual-identity-pack.ts";
import { conceptSafetyPrecheck, decideSpendAuthorized, mapPackSources } from "./edge-core.ts";

// --- tiny inline assert (keeps the suite self-contained) --------------------
function ok(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error("ASSERT FAILED: " + msg);
}
function eq<T>(a: T, b: T, msg: string) {
  if (a !== b) throw new Error(`ASSERT EQ FAILED: ${msg} (got ${JSON.stringify(a)} !== ${JSON.stringify(b)})`);
}

// --- fixtures ----------------------------------------------------------------
const OWNER = "7c8ddf9d-172c-4a89-a402-bb7066228b61";
const PRODUCT = "caa240db-1970-4caf-9db3-8cbe394a6a7a";

// A CONCEPT_ONLY pack (SharkNinja-shaped): appearance all UNVERIFIED -> original-unbranded.
function conceptPack(): ProductVisualIdentityPack {
  return buildProductVisualIdentityPack(
    mapPackSources(
      {
        identity_state: "CONCEPT_ONLY",
        label: "SharkNinja BlastBoss",
        supplier_link_allowed: false,
        fingerprint: {
          product_name: "SharkNinja BlastBoss",
          category: "blender",
          extraction_confidence: 0.4,
        },
      },
      { images: { total: 1, has_customer_owned: true }, ai_generation: { reference_eligible: true, execution_state: "AVAILABLE" } },
    ),
  );
}

type Call = { prompt: string; aspectRatio: string };
function mockProvider(calls: Call[]): ConceptLaneArgs["provider"] {
  return {
    id: "GOOGLE_GEMINI",
    model: "gemini-2.5-flash-image",
    generate: (p) => {
      calls.push(p);
      return Promise.resolve({ bytesRef: "pulse-generated-media/concept/" + calls.length + ".png" });
    },
  };
}
function mockStorage(puts: Array<{ bytesRef: string; meta: Record<string, unknown> }>): ConceptLaneArgs["storage"] {
  return {
    putPrivate: (bytesRef, meta) => {
      puts.push({ bytesRef, meta });
      return Promise.resolve({ privateRef: bytesRef });
    },
  };
}
function baseArgs(over: Partial<ConceptLaneArgs>): ConceptLaneArgs {
  const calls: Call[] = [];
  return {
    pack: conceptPack(),
    productId: PRODUCT,
    market: "US",
    ownerId: OWNER,
    authUserId: OWNER,
    scene: "LIFESTYLE",
    aspectRatio: "1:1",
    founderBrief: null,
    spendApproved: false,
    provider: mockProvider(calls),
    storage: mockStorage([]),
    now: () => "2026-11-28T00:00:00.000Z",
    ...over,
  };
}

// --- (A) ownership: wrong auth user is blocked, provider never called --------
Deno.test("unauthorized when authUserId != ownerId; provider/storage never called", async () => {
  const calls: Call[] = [];
  const puts: Array<{ bytesRef: string; meta: Record<string, unknown> }> = [];
  const r = await executeConceptLane(
    baseArgs({ authUserId: "11111111-1111-4111-8111-111111111111", spendApproved: true, provider: mockProvider(calls), storage: mockStorage(puts) }),
  );
  eq(r.status, "unauthorized", "status");
  eq(r.executionState, "BLOCKED", "state");
  eq(calls.length, 0, "provider not called");
  eq(puts.length, 0, "storage not called");
});

// --- (B) spend NOT approved: prepared, provider never called -----------------
Deno.test("spend not approved -> PREPARED_NOT_EXECUTED; provider never called", async () => {
  const calls: Call[] = [];
  const puts: Array<{ bytesRef: string; meta: Record<string, unknown> }> = [];
  const r = await executeConceptLane(baseArgs({ spendApproved: false, provider: mockProvider(calls), storage: mockStorage(puts) }));
  eq(r.status, "spend_approval_required", "status");
  eq(r.executionState, "PREPARED_NOT_EXECUTED", "state");
  eq(calls.length, 0, "provider not called");
  eq(puts.length, 0, "storage not called");
});

// --- (C) owner + spend approved: provider called once; URL-free; provenance --
Deno.test("owner + spend approved -> executed with URL-free prompt, private storage, ORIGINAL_CONCEPT provenance", async () => {
  const calls: Call[] = [];
  const puts: Array<{ bytesRef: string; meta: Record<string, unknown> }> = [];
  const r = await executeConceptLane(baseArgs({ spendApproved: true, provider: mockProvider(calls), storage: mockStorage(puts) }));
  ok(r.status === "executed", "executed");
  eq(calls.length, 1, "provider called exactly once");
  ok(!/(https?:|data:|www\.)/i.test(calls[0].prompt), "prompt has no URL");
  ok(/AI CONCEPT/.test(calls[0].prompt), "prompt carries the concept label");
  ok(/unbranded/i.test(calls[0].prompt), "original-unbranded instruction present");
  eq(puts.length, 1, "stored privately once");
  if (r.status === "executed") {
    eq(r.provenance.rightsState, "ORIGINAL_CONCEPT", "rights state");
    eq(r.provenance.classification, "AI_CONCEPT_NOT_PRODUCT_VERIFIED", "classification");
    eq(r.provenance.identityValidated, false, "identity not validated");
    eq(r.provenance.inputProvenance.referenceAsset, null, "no reference asset");
    eq(r.provenance.outputIdentityVersion, conceptPack().identityVersion, "identity version recorded");
  }
});

// --- (D) a URL in the founder brief is stripped before the provider ----------
Deno.test("founder brief URL is stripped from the provider prompt", async () => {
  const calls: Call[] = [];
  const r = await executeConceptLane(
    baseArgs({ spendApproved: true, founderBrief: "sleek and premium see https://cj.example/p/123 for ref", provider: mockProvider(calls) }),
  );
  ok(r.status === "executed", "executed");
  eq(calls.length, 1, "provider called");
  ok(!/https?:\/\//i.test(calls[0].prompt), "no url in prompt");
  ok(/sleek and premium/.test(calls[0].prompt), "brief text kept");
});

// --- (E) a 3-scene pack shares ONE identity version --------------------------
Deno.test("executeConceptPack shares a single identity version across scenes", async () => {
  const r = await executeConceptPack({ ...baseArgs({ spendApproved: true }), scenes: ["CLEAN_STUDIO", "LIFESTYLE", "PRODUCT_IN_USE"] });
  eq(r.results.length, 3, "three scenes");
  eq(r.identityVersion, conceptPack().identityVersion, "pack identity version");
  for (const s of r.results) {
    if (s.result.status === "executed") eq(s.result.provenance.outputIdentityVersion, r.identityVersion, "scene " + s.scene + " shares version");
  }
});

// --- (F) promotion is never allowed ------------------------------------------
Deno.test("rejectConceptPromotion is always refused", () => {
  const p = rejectConceptPromotion({ concept_asset_id: "x" });
  eq(p.allowed, false, "never allowed");
});

// --- (G) edge spend decision is fail-closed ----------------------------------
Deno.test("decideSpendAuthorized requires enforced && allowed", () => {
  eq(decideSpendAuthorized({ allowed: true, enforced: true, remaining: 2 }), true, "enforced+allowed -> true");
  eq(decideSpendAuthorized({ allowed: true, enforced: false, reason: "no_budget_unenforced" }), false, "unenforced (no budget) -> false");
  eq(decideSpendAuthorized({ allowed: false, enforced: true, reason: "budget_exceeded" }), false, "exhausted -> false");
  eq(decideSpendAuthorized(null), false, "null -> false");
  eq(decideSpendAuthorized({}), false, "empty -> false");
});

// --- (H) server pack-source mapping reproduces the client identity version ----
// NOTE (precision): JS numbers are IEEE-754 doubles, so a supplier id beyond
// Number.MAX_SAFE_INTEGER (2^53) loses precision the moment it is a JS number —
// in the Lovable client AND here, identically. The deployed RPCs return
// supplier_product_id as a JSON STRING (text column + fn_product_supplier_identity),
// so the real path never loses precision. This test proves: (a) a numeric input is
// stringified exactly as the client's idStr does within the safe range, and
// (b) a realistic 19-digit STRING id (the real shape) is preserved exactly and
// hashes deterministically.
Deno.test("mapPackSources: numeric id stringified (safe range) == string id; 19-digit string id preserved", () => {
  const SAFE = 90071992547409; // < 2^53
  const packNum = buildProductVisualIdentityPack(
    mapPackSources(
      { identity_state: "IDENTITY_RESOLVED", supplier_link_allowed: true, fingerprint: { product_name: "Widget", category: "tool", supplier_product_id: SAFE, supplier_provider: "CJ", extraction_confidence: 0.9 } },
      { images: {}, ai_generation: { reference_eligible: true, execution_state: "AVAILABLE" } },
    ),
  );
  const packStr = buildProductVisualIdentityPack(
    mapPackSources(
      { identity_state: "IDENTITY_RESOLVED", supplier_link_allowed: true, fingerprint: { product_name: "Widget", category: "tool", supplier_product_id: String(SAFE), supplier_provider: "CJ", extraction_confidence: 0.9 } },
      { images: {}, ai_generation: { reference_eligible: true, execution_state: "AVAILABLE" } },
    ),
  );
  eq(packNum.skuVariant.value, String(SAFE), "numeric sku stringified exactly (safe range)");
  eq(packNum.identityVersion, packStr.identityVersion, "numeric and string sku hash identically (safe range)");

  // The real shape: a 19-digit CJ id delivered as a STRING is preserved exactly.
  const realistic = "2608250310481611400";
  const packReal = buildProductVisualIdentityPack(
    mapPackSources(
      { identity_state: "IDENTITY_RESOLVED", supplier_link_allowed: true, fingerprint: { product_name: "Widget", category: "tool", supplier_product_id: realistic, supplier_provider: "CJ", extraction_confidence: 0.9 } },
      { images: {}, ai_generation: { reference_eligible: true, execution_state: "AVAILABLE" } },
    ),
  );
  eq(packReal.skuVariant.value, realistic, "19-digit string id preserved exactly");
  // Determinism: same inputs -> same version; distinct identities -> distinct version.
  const packReal2 = buildProductVisualIdentityPack(
    mapPackSources(
      { identity_state: "IDENTITY_RESOLVED", supplier_link_allowed: true, fingerprint: { product_name: "Widget", category: "tool", supplier_product_id: realistic, supplier_provider: "CJ", extraction_confidence: 0.9 } },
      { images: {}, ai_generation: { reference_eligible: true, execution_state: "AVAILABLE" } },
    ),
  );
  eq(packReal.identityVersion, packReal2.identityVersion, "deterministic for identical inputs");
  ok(packReal.identityVersion !== conceptPack().identityVersion, "distinct identities differ");
});

// --- (I) BE344 P2: safety pre-check runs before spend; safe for a normal pack ---
Deno.test("conceptSafetyPrecheck: safe for a normal pack, builds a URL-free labelled request", () => {
  const r = conceptSafetyPrecheck({
    pack: conceptPack(), productId: PRODUCT, market: "US", scene: "LIFESTYLE", aspectRatio: "1:1",
    founderBrief: "warm kitchen morning https://cj.example/x",
  });
  ok(r.safe === true, "normal pack is safe");
  ok(!/(https?:|data:|www\.)/i.test(r.request.prompt), "prompt is URL-free (brief URL stripped)");
  eq(r.request.label, "AI CONCEPT — NOT PRODUCT VERIFIED", "carries the concept label");
  eq(r.request.provenance.type, "ORIGINAL_CONCEPT", "ORIGINAL_CONCEPT provenance");
  eq(r.request.provenance.referenceAsset, null, "no reference asset");
});
