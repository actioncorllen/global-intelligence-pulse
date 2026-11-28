// CANONICAL SERVER COPY — byte-for-byte logic of the tested Lovable module
// src/lib/creative-studio/creative-concept-prep.ts (BE341). Only import specifiers
// differ (Deno relative paths vs the Lovable "@/..." alias). Keep the two in sync.
//
// Pure, deterministic AI Concept request preparation. Consumes a
// ProductVisualIdentityPack; never executes a model, never carries image
// pixels/URLs or provider listing text, never claims exact-product depiction.
import type { PackAttribute, ProductVisualIdentityPack } from "./product-visual-identity-pack.ts";

export type ConceptScene = "CLEAN_STUDIO" | "LIFESTYLE" | "PRODUCT_IN_USE";
export const CONCEPT_LABEL = "AI CONCEPT — NOT PRODUCT VERIFIED" as const;

export type ConceptGenerationRequest = {
  mode: "AI_CONCEPT";
  label: typeof CONCEPT_LABEL;
  originalUnbranded: boolean;
  scene: ConceptScene;
  aspectRatio: string;
  prompt: string;
  usedAttributes: string[];
  identityVersion: string;
  provenance: {
    type: "ORIGINAL_CONCEPT"; referenceAsset: null; identityValidated: false;
    productId: string; market: string | null; identityVersion: string;
    rightsBasis: "ORIGINAL_CONCEPT_TEXT_ONLY";
  };
  rightsSafety: { includesImagePixels: false; includesImageUrls: boolean; repurposedProviderText: false };
  costControls: {
    provider: "DEFERRED"; estimatedUsd: null; requiresFounderSpendApproval: true;
    executionState: "PREPARED_NOT_EXECUTED";
  };
  blockedReasons: string[];
};

const APPEARANCE_KEYS = ["primaryColour", "bodyShape", "materialsFinish", "controlsPorts", "accessories"] as const;
const URLISH = /(https?:|data:|www\.)/i;

const SCENE_TEXT: Record<ConceptScene, string> = {
  CLEAN_STUDIO: "Scene: clean studio product shot on a neutral seamless background with soft, even lighting.",
  LIFESTYLE: "Scene: tasteful lifestyle setting in a generic, everyday environment with natural light.",
  PRODUCT_IN_USE: "Scene: the item shown in use by an anonymous person in a generic setting, no identifiable faces.",
};

const isVerified = (a: PackAttribute) => a.value !== null && a.confidence !== "UNVERIFIED";

function sanitiseBrief(raw: string | null | undefined): { text: string; hadUrl: boolean } {
  if (!raw) return { text: "", hadUrl: false };
  const tokens = raw.split(/\s+/).filter(Boolean);
  const kept = tokens.filter((t) => !URLISH.test(t));
  return { text: kept.join(" ").trim(), hadUrl: kept.length !== tokens.length };
}

export function buildConceptGenerationRequest(args: {
  pack: ProductVisualIdentityPack;
  productId: string;
  market: string | null;
  scene: ConceptScene;
  aspectRatio: string;
  founderBrief?: string | null;
}): ConceptGenerationRequest {
  const { pack, productId, market, scene, aspectRatio } = args;
  const originalUnbranded = APPEARANCE_KEYS.some((k) => pack[k].confidence === "UNVERIFIED" || pack[k].value === null);
  const usedAttributes: string[] = [];
  const blockedReasons: string[] = [];

  const category = isVerified(pack.category) ? (pack.category.value as string) : null;
  if (category) usedAttributes.push("category");
  const subject = category ?? "consumer product";

  const parts: string[] = [CONCEPT_LABEL + "."];
  if (originalUnbranded) {
    parts.push(
      `Create an original, unbranded concept — no brand names, no logos, no trademarked design; a generic ${subject} for ideation only. Do not depict or reproduce any specific real product.`,
    );
  } else if (isVerified(pack.canonicalIdentity)) {
    // Not reachable today (appearance is never verified); kept fail-safe and generic.
    usedAttributes.push("canonicalIdentity");
    parts.push(`Create a concept image of a ${subject}. Concept only, not a verified product depiction.`);
  }
  parts.push(SCENE_TEXT[scene]);
  parts.push(`Aspect ratio ${aspectRatio}.`);

  const brief = sanitiseBrief(args.founderBrief);
  if (brief.hadUrl) blockedReasons.push("url_stripped_from_brief");
  if (brief.text) parts.push(`Founder brief: ${brief.text}`);

  const prompt = parts.join(" ");
  return {
    mode: "AI_CONCEPT",
    label: CONCEPT_LABEL,
    originalUnbranded,
    scene,
    aspectRatio,
    prompt,
    usedAttributes,
    identityVersion: pack.identityVersion,
    provenance: {
      type: "ORIGINAL_CONCEPT", referenceAsset: null, identityValidated: false,
      productId, market, identityVersion: pack.identityVersion, rightsBasis: "ORIGINAL_CONCEPT_TEXT_ONLY",
    },
    rightsSafety: { includesImagePixels: false, includesImageUrls: URLISH.test(prompt), repurposedProviderText: false },
    costControls: {
      provider: "DEFERRED", estimatedUsd: null, requiresFounderSpendApproval: true,
      executionState: "PREPARED_NOT_EXECUTED",
    },
    blockedReasons,
  };
}

export function assertConceptRequestSafe(req: ConceptGenerationRequest): true {
  const fail = (m: string): never => { throw new Error("Unsafe concept request: " + m); };
  if (req.rightsSafety.includesImagePixels !== false) fail("image pixels");
  if (req.rightsSafety.includesImageUrls !== false || URLISH.test(req.prompt)) fail("image urls");
  if (req.rightsSafety.repurposedProviderText !== false) fail("provider text");
  if (req.provenance.type !== "ORIGINAL_CONCEPT") fail("provenance type");
  if (req.provenance.referenceAsset !== null) fail("reference asset");
  if (req.provenance.identityValidated !== false) fail("identity validated");
  if (req.label !== CONCEPT_LABEL) fail("label");
  if (req.costControls.executionState !== "PREPARED_NOT_EXECUTED") fail("execution state");
  return true;
}

export function conceptModeAvailability(pack: ProductVisualIdentityPack): {
  exact: boolean; hybrid: boolean; concept: boolean; reason: Record<string, string>;
} {
  const exact =
    pack.hasAuthorisedReferenceImage &&
    pack.rightsEligibility.referenceEligible &&
    pack.rightsEligibility.executionState === "AVAILABLE";
  const blocked = "Authorised owned/licensed reference image required";
  return {
    exact, hybrid: exact, concept: true,
    reason: {
      exact: exact ? "Authorised reference image available" : blocked,
      hybrid: exact ? "Authorised reference image available; uses identity pack constraints" : blocked,
      concept: "Original unbranded concept; no reference image needed",
    },
  };
}
