"use client";
// STRATELOQ — Shared platform catalogue client contract (read + adopt).
// Decoding only. Uses the authenticated browser Supabase singleton. No provider call, no tenant id,
// no research logic client-side. Every value must be present in the authenticated server payload.
// Backend: fn_catalogue_browse_markets(), fn_catalogue_browse(market,...), fn_catalogue_adopt(catalogue_id).

import { supabase } from "@/integrations/supabase/client";

export type CatalogueOutcome<T> =
  | { status: "ok"; value: T }
  | { status: "unauthenticated" }
  | { status: "not_entitled" }
  | { status: "unsupported_market" }
  | { status: "temporary_failure" };

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v : null);
const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null;

async function rpc(name: string, args: Obj): Promise<{ data: unknown } | { error: { code?: string; message: string } }> {
  const { data, error } = await supabase.rpc(name as never, args as never);
  if (error) return { error: error as { code?: string; message: string } };
  return { data };
}
function mapStatus<T>(root: Obj | null): CatalogueOutcome<T> | null {
  const s = str(root?.status);
  if (s === "unauthenticated") return { status: "unauthenticated" };
  if (s === "not_entitled") return { status: "not_entitled" };
  if (s === "unsupported_market") return { status: "unsupported_market" };
  return null;
}

export interface CatalogueMarket { code: string; name: string; currency: string | null; productCount: number; hasData: boolean; }
export interface CatalogueItem {
  catalogueId: string; market: string; currency: string | null; title: string; category: string | null;
  opportunityBand: string | null; decision: string | null; opportunityScore: number | null;
  evidenceConfidence: string | null; coverage: number | null; imageState: string; imageRef: string | null;
  freshnessAsOf: string | null; isStale: boolean | null; sourceProvider: string | null;
}

export async function fetchCatalogueMarkets(): Promise<CatalogueOutcome<CatalogueMarket[]>> {
  try {
    const res = await rpc("fn_catalogue_browse_markets", {});
    if ("error" in res) return { status: "temporary_failure" };
    const root = obj(res.data); const mapped = mapStatus<CatalogueMarket[]>(root); if (mapped) return mapped;
    const rows = Array.isArray(root?.markets) ? (root!.markets as unknown[]) : [];
    const value = rows.map((r) => obj(r)).filter((r): r is Obj => !!r).map((r) => ({
      code: str(r.market) ?? "", name: str(r.market) ?? "", currency: str(r.currency),
      productCount: num(r.products) ?? 0, hasData: r.has_data === true,
    })).filter((m) => m.code);
    return { status: "ok", value };
  } catch { return { status: "temporary_failure" }; }
}

export async function fetchCatalogueBrowse(
  market: string, p: { filter?: string; search?: string | null; page?: number; pagesize?: number } = {},
): Promise<CatalogueOutcome<{ total: number; items: CatalogueItem[] }>> {
  try {
    const res = await rpc("fn_catalogue_browse", {
      p_market: market, p_filter: p.filter ?? "ALL", p_search: p.search ?? null, p_page: p.page ?? 1, p_pagesize: p.pagesize ?? 24,
    });
    if ("error" in res) return { status: "temporary_failure" };
    const root = obj(res.data); const mapped = mapStatus<{ total: number; items: CatalogueItem[] }>(root); if (mapped) return mapped;
    const rows = Array.isArray(root?.items) ? (root!.items as unknown[]) : [];
    const items = rows.map((r) => obj(r)).filter((r): r is Obj => !!r).map((r) => ({
      catalogueId: str(r.catalogue_id) ?? "", market: str(r.market) ?? market, currency: str(r.currency),
      title: str(r.title) ?? "", category: str(r.category), opportunityBand: str(r.opportunity_band),
      decision: str(r.decision), opportunityScore: num(r.opportunity_score), evidenceConfidence: str(r.evidence_confidence),
      coverage: num(r.coverage), imageState: str(r.image_state) ?? "PENDING_AUTHORIZED_MEDIA", imageRef: str(r.image_ref),
      freshnessAsOf: str(r.freshness_as_of), isStale: typeof r.is_stale === "boolean" ? r.is_stale : null,
      sourceProvider: str(r.source_provider),
    })).filter((i) => i.catalogueId);
    return { status: "ok", value: { total: num(root?.total) ?? items.length, items } };
  } catch { return { status: "temporary_failure" }; }
}

// Adopt a shared product into the signed-in customer's own account (private working copy) so the existing
// Save and research RPCs (which require a tenant-owned product) can operate on it. Returns the customer's productId.
export async function catalogueAdopt(catalogueId: string): Promise<CatalogueOutcome<{ productId: string; market: string }>> {
  try {
    const res = await rpc("fn_catalogue_adopt", { p_catalogue_id: catalogueId });
    if ("error" in res) return { status: "temporary_failure" };
    const root = obj(res.data); const mapped = mapStatus<{ productId: string; market: string }>(root); if (mapped) return mapped;
    const pid = str(root?.product_id); if (!pid) return { status: "temporary_failure" };
    return { status: "ok", value: { productId: pid, market: str(root?.market) ?? "" } };
  } catch { return { status: "temporary_failure" }; }
}
