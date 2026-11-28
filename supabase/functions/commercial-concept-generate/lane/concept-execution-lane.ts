// CANONICAL SERVER COPY — byte-for-byte logic of the tested Lovable module
// src/lib/creative-studio/concept-execution-lane.ts (BE342). Only import specifiers
// differ (Deno relative paths vs the Lovable "@/..." alias). This is the SINGLE
// source of execution truth the edge runs; there is no second, divergent
// implementation. Keep the two copies in sync (the BE342 Vitest suite covers the
// Lovable copy; concept-lane.test.ts covers this copy with the same invariants).
//
// Dependency-injected AI Concept execution. The provider receives only a
// rights-safe text prompt; generated output is always stored privately.
import {
  assertConceptRequestSafe,
  buildConceptGenerationRequest,
  type ConceptGenerationRequest,
  type ConceptScene,
} from "./creative-concept-prep.ts";
import type { ProductVisualIdentityPack } from "./product-visual-identity-pack.ts";

const URLISH = /(https?:|data:|www\.)/i;

export type ConceptProvenance = {
  prompt: string;
  provider: string;
  model: string;
  inputProvenance: {
    rightsBasis: "ORIGINAL_CONCEPT_TEXT_ONLY";
    referenceAsset: null;
  };
  outputIdentityVersion: string;
  rightsState: "ORIGINAL_CONCEPT";
  classification: "AI_CONCEPT_NOT_PRODUCT_VERIFIED";
  identityValidated: false;
  createdAt: string;
};

export type ConceptLaneResult =
  | { status: "unauthorized"; executionState: "BLOCKED" }
  | { status: "unsafe_request"; executionState: "BLOCKED"; request: ConceptGenerationRequest }
  | {
      status: "spend_approval_required";
      executionState: "PREPARED_NOT_EXECUTED";
      request: ConceptGenerationRequest;
    }
  | {
      status: "executed";
      executionState: "EXECUTED";
      request: ConceptGenerationRequest;
      privateRef: string;
      provenance: ConceptProvenance;
    };

export type ConceptLaneArgs = {
  pack: ProductVisualIdentityPack;
  productId: string;
  market: string | null;
  ownerId: string;
  authUserId: string | null;
  scene: ConceptScene;
  aspectRatio: string;
  founderBrief?: string | null;
  spendApproved: boolean;
  provider: {
    id: string;
    model: string;
    generate: (p: { prompt: string; aspectRatio: string }) => Promise<{ bytesRef: string }>;
  };
  storage: {
    putPrivate: (
      bytesRef: string,
      meta: Record<string, unknown>,
    ) => Promise<{ privateRef: string }>;
  };
  now?: () => string;
};

export async function executeConceptLane(args: ConceptLaneArgs): Promise<ConceptLaneResult> {
  if (args.authUserId !== args.ownerId) {
    return { status: "unauthorized", executionState: "BLOCKED" };
  }

  const request = buildConceptGenerationRequest({
    pack: args.pack,
    productId: args.productId,
    market: args.market,
    scene: args.scene,
    aspectRatio: args.aspectRatio,
    founderBrief: args.founderBrief,
  });

  try {
    assertConceptRequestSafe(request);
  } catch {
    return { status: "unsafe_request", executionState: "BLOCKED", request };
  }
  if (URLISH.test(request.prompt)) {
    return { status: "unsafe_request", executionState: "BLOCKED", request };
  }

  if (args.spendApproved !== true) {
    return {
      status: "spend_approval_required",
      executionState: "PREPARED_NOT_EXECUTED",
      request,
    };
  }

  const generated = await args.provider.generate({
    prompt: request.prompt,
    aspectRatio: args.aspectRatio,
  });
  const provenance: ConceptProvenance = {
    prompt: request.prompt,
    provider: args.provider.id,
    model: args.provider.model,
    inputProvenance: {
      rightsBasis: "ORIGINAL_CONCEPT_TEXT_ONLY",
      referenceAsset: null,
    },
    outputIdentityVersion: args.pack.identityVersion,
    rightsState: "ORIGINAL_CONCEPT",
    classification: "AI_CONCEPT_NOT_PRODUCT_VERIFIED",
    identityValidated: false,
    createdAt: args.now?.() ?? new Date().toISOString(),
  };
  const stored = await args.storage.putPrivate(generated.bytesRef, {
    productId: args.productId,
    market: args.market,
    ownerId: args.ownerId,
    scene: args.scene,
    aspectRatio: args.aspectRatio,
    provenance,
  });

  return {
    status: "executed",
    executionState: "EXECUTED",
    request,
    privateRef: stored.privateRef,
    provenance,
  };
}

export type ConceptPackResult = {
  identityVersion: string;
  results: Array<{ scene: ConceptScene; result: ConceptLaneResult }>;
};

export async function executeConceptPack(
  args: Omit<ConceptLaneArgs, "scene"> & { scenes: ConceptScene[] },
): Promise<ConceptPackResult> {
  const results: ConceptPackResult["results"] = [];
  for (const scene of args.scenes) {
    results.push({ scene, result: await executeConceptLane({ ...args, scene }) });
  }
  return { identityVersion: args.pack.identityVersion, results };
}

export function rejectConceptPromotion(_record: unknown): {
  allowed: false;
  reason: "AI concept is not a verified product asset; validation + commercial clearance required";
} {
  return {
    allowed: false,
    reason: "AI concept is not a verified product asset; validation + commercial clearance required",
  };
}
