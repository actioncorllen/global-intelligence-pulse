"use client";
// STRATELOQ — Shared platform catalogue hooks. Mirrors use-product-explorer.ts (TanStack Query + supabase.rpc).
// Browsing + adopting consume NO research allowance (server-enforced). Save/research reuse the EXISTING RPCs
// via the adopted (tenant-owned) product id returned by catalogueAdopt.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  catalogueAdopt,
  fetchCatalogueBrowse,
  fetchCatalogueMarkets,
} from "@/lib/business-discovery/platform-catalogue-contract";
import { ECOMMERCE_WORKSPACE_QUERY_KEY } from "@/hooks/use-ecommerce-workspace";

export function useCatalogueMarkets(enabled: boolean) {
  return useQuery({
    queryKey: ["catalogue", "markets"],
    queryFn: fetchCatalogueMarkets,
    enabled,
    staleTime: 5 * 60_000,
    retry: false,
  });
}

export function useCatalogueBrowse(
  market: string | null,
  params: { filter?: string; search?: string | null; page?: number; pagesize?: number } = {},
) {
  return useQuery({
    queryKey: ["catalogue", "browse", market ?? "", params.filter ?? "ALL", params.search ?? "", params.page ?? 1, params.pagesize ?? 24],
    queryFn: () => fetchCatalogueBrowse(market as string, params),
    enabled: Boolean(market),
    staleTime: 60_000,
    retry: false,
  });
}

/**
 * Adopt a shared catalogue product into the customer's own account, then return the customer-owned
 * product id. Callers chain this before the EXISTING save_own_product / request-research RPCs, which
 * require a tenant-owned product. The server enforces entitlement; adoption never copies restricted
 * provider data and never consumes a research action.
 */
export function useCatalogueAdopt() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (catalogueId: string) => catalogueAdopt(catalogueId),
    onSuccess: (outcome) => {
      if (outcome.status === "ok") void qc.invalidateQueries({ queryKey: ECOMMERCE_WORKSPACE_QUERY_KEY });
    },
  });
}
