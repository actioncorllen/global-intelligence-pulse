"use client";
// STRATELOQ — Save / deeper-research actions from a shared catalogue card (W0.05).
// Each action ADOPTS the shared card into the signed-in customer's account first (private working copy,
// 0 research actions), then calls the existing tenant-owned RPC. Deeper research is metered server-side.

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { catalogueAdopt } from "@/lib/business-discovery/platform-catalogue-contract";
import { saveCatalogueProduct, requestDeeperResearch, type SaveOutcome, type ResearchOutcome } from "@/lib/business-discovery/catalogue-actions-contract";
import { ECOMMERCE_WORKSPACE_QUERY_KEY } from "@/hooks/use-ecommerce-workspace";

type AdoptFail = Exclude<SaveOutcome, { status: "ok" }> ;

export function useSaveFromCatalogue() {
  const qc = useQueryClient();
  return useMutation<SaveOutcome, Error, { catalogueId: string; market: string }>({
    mutationFn: async ({ catalogueId, market }) => {
      const adopted = await catalogueAdopt(catalogueId);
      if (adopted.status !== "ok") return mapAdoptFailure(adopted.status);
      return saveCatalogueProduct(adopted.value.productId, market);
    },
    onSuccess: (o) => { if (o.status === "ok") void qc.invalidateQueries({ queryKey: ECOMMERCE_WORKSPACE_QUERY_KEY }); },
  });
}

export function useResearchFromCatalogue() {
  const qc = useQueryClient();
  return useMutation<ResearchOutcome, Error, { catalogueId: string; market: string; freshnessHours?: number }>({
    mutationFn: async ({ catalogueId, market, freshnessHours }) => {
      const adopted = await catalogueAdopt(catalogueId);
      if (adopted.status !== "ok") return mapAdoptFailureResearch(adopted.status);
      return requestDeeperResearch(adopted.value.productId, market, freshnessHours ?? 168);
    },
    onSuccess: (o) => {
      if (o.status === "researching" || o.status === "cache_reused")
        void qc.invalidateQueries({ queryKey: ECOMMERCE_WORKSPACE_QUERY_KEY });
    },
  });
}

function mapAdoptFailure(s: string): AdoptFail {
  if (s === "unauthenticated") return { status: "unauthenticated" };
  if (s === "not_entitled") return { status: "not_authorized" };
  return { status: "temporary_failure" };
}
function mapAdoptFailureResearch(s: string): ResearchOutcome {
  if (s === "unauthenticated") return { status: "unauthenticated" };
  if (s === "not_entitled") return { status: "not_authorized" };
  if (s === "unsupported_market") return { status: "unsupported_market" };
  return { status: "temporary_failure" };
}
