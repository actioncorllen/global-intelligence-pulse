// CANONICAL SERVER COPY — keep in sync with the Lovable client type of the same
// shape in src/lib/commerce/commerce-actions-api.ts (ProductVisualIdentityPackSources).
// This is the raw, structured source bundle the edge assembles server-side from
// fn_product_identity_resolution + fn_product_commercial_asset_readiness_owned,
// then feeds to buildProductVisualIdentityPack so the server computes the SAME
// deterministic identityVersion the client would (identity-version consistency).
export type ProductVisualIdentityPackSources = {
  identity: {
    identityState: string | null;
    label: string | null;
    supplierLinkAllowed: boolean;
    strongIdentifierCount: number | null;
    fingerprint: {
      productName: string | null;
      category: string | null;
      brand: string | null;
      supplierProvider: string | null;
      supplierProductId: string | null;
      productFamilyKey: string | null;
      extractionConfidence: number | null;
    };
  } | null;
  readiness: {
    images: {
      total: number | null;
      hasCustomerOwned: boolean;
      hasSupplierAuthorized: boolean;
      hasMarketplaceReference: boolean;
    };
    referenceEligible: boolean;
    executionState: string | null;
  } | null;
};
