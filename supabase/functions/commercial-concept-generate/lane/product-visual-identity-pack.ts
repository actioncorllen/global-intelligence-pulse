// CANONICAL SERVER COPY — byte-for-byte logic of the tested Lovable module
// src/lib/creative-studio/product-visual-identity-pack.ts (BE340). Only the import
// specifier differs (Deno relative path vs the Lovable "@/..." alias) because the
// two deploy surfaces cannot share a package. The hash, attribute mapping and
// UNVERIFIED defaults are IDENTICAL, so buildProductVisualIdentityPack computes the
// SAME identityVersion on the server as in the browser. Keep the two in sync.
//
// Pure Product Visual Identity Pack assembler. Display-only: maps existing
// structured server fields; attributes with no structured source stay UNVERIFIED.
import type { ProductVisualIdentityPackSources } from "./pack-sources.ts";

export type PackConfidence = "HIGH" | "MEDIUM" | "LOW" | "UNVERIFIED";
export type PackAttribute = { value: string | null; source: string | null; confidence: PackConfidence };

export const UNVERIFIED_VISUAL_KEYS = [
  "primaryColour",
  "secondaryColour",
  "bodyShape",
  "proportions",
  "materialsFinish",
  "controlsPorts",
  "accessories",
  "dimensions",
  "functions",
  "visualConstraints",
  "neverInventFeatures",
] as const;
type VisualKey = (typeof UNVERIFIED_VISUAL_KEYS)[number];

export type ProductVisualIdentityPack = {
  canonicalIdentity: PackAttribute;
  brand: PackAttribute;
  model: PackAttribute;
  skuVariant: PackAttribute;
  category: PackAttribute;
  images: {
    total: number | null;
    hasCustomerOwned: boolean;
    hasSupplierAuthorized: boolean;
    hasMarketplaceReference: boolean;
  };
  rightsEligibility: { referenceEligible: boolean; executionState: string };
  identityState: string | null;
  identityVersion: string;
  hasAuthorisedReferenceImage: boolean;
} & Record<VisualKey, PackAttribute>;

const UNVERIFIED: PackAttribute = { value: null, source: null, confidence: "UNVERIFIED" };

/** Deterministic FNV-1a 32-bit hash, hex. */
function hash(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return "piv-" + h.toString(16).padStart(8, "0");
}

export function buildProductVisualIdentityPack(
  sources: ProductVisualIdentityPackSources,
): ProductVisualIdentityPack {
  const id = sources.identity;
  const fp = id?.fingerprint;
  const state = id?.identityState ?? null;
  const resolved = state === "IDENTITY_RESOLVED";
  const sku = fp?.supplierProductId ?? null;
  const cat = fp?.category ?? null;
  const ec = fp?.extractionConfidence;
  const name = fp?.productName ?? null;

  const canonicalIdentity: PackAttribute = {
    value: name,
    source: "identity_resolution",
    confidence: resolved ? "HIGH" : "LOW",
  };
  const skuVariant: PackAttribute = {
    value: sku,
    source: sku ? "supplier_identity:" + (fp?.supplierProvider ?? "") : null,
    confidence: resolved && id?.supplierLinkAllowed === true ? "HIGH" : "UNVERIFIED",
  };
  const category: PackAttribute = {
    value: cat,
    source: cat ? "identity_resolution" : null,
    confidence:
      typeof ec === "number" ? (ec >= 0.8 ? "HIGH" : ec >= 0.5 ? "MEDIUM" : "LOW") : "LOW",
  };
  const rd = sources.readiness;
  const images = rd?.images ?? {
    total: null,
    hasCustomerOwned: false,
    hasSupplierAuthorized: false,
    hasMarketplaceReference: false,
  };
  const rightsEligibility = {
    referenceEligible: rd?.referenceEligible === true,
    executionState: rd?.executionState ?? "UNKNOWN",
  };
  const visual = Object.fromEntries(
    UNVERIFIED_VISUAL_KEYS.map((k) => [k, { ...UNVERIFIED }]),
  ) as Record<VisualKey, PackAttribute>;

  return {
    canonicalIdentity,
    brand: { ...UNVERIFIED },
    model: { ...UNVERIFIED },
    skuVariant,
    category,
    ...visual,
    images,
    rightsEligibility,
    identityState: state,
    identityVersion: hash(JSON.stringify([name, sku, cat, state])),
    hasAuthorisedReferenceImage: images.hasCustomerOwned || rightsEligibility.referenceEligible,
  };
}

/** Attributes with a value and a non-UNVERIFIED confidence. */
export function verifiedAttributeCount(pack: ProductVisualIdentityPack): number {
  const attrs: PackAttribute[] = [
    pack.canonicalIdentity,
    pack.brand,
    pack.model,
    pack.skuVariant,
    pack.category,
    ...UNVERIFIED_VISUAL_KEYS.map((k) => pack[k]),
  ];
  return attrs.filter((a) => a.value !== null && a.confidence !== "UNVERIFIED").length;
}
