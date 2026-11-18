"use client";
// STRATELOQ — Save + deeper-research actions for catalogue products (W0.05).
// Both actions require a TENANT-OWNED product, so callers first adopt the shared card (catalogueAdopt)
// and pass the returned customer-owned productId here. Browsing + adoption cost 0 research actions;
// only explicit deeper research consumes a plan allowance (server-enforced reserve/settle/refund, W0.02).
// Backend: save_own_product(p_product_id,p_market); fn_own_request_product_market_research(p_product_id,p_market,p_freshness_hours).

import { supabase } from "@/integrations/supabase/client";

export type SaveOutcome =
  | { status: "ok"; saved: true }
  | { status: "unauthenticated" }
  | { status: "not_authorized" }
  | { status: "temporary_failure" };

export type ResearchOutcome =
  | { status: "researching"; runId: string | null; market: string }
  | { status: "cache_reused"; runId: string | null; market: string }     // fresh/in-flight result reused — NOT re-charged
  | { status: "allowance_blocked"; reason: string | null; remaining: number | null; limit: number | null }
  | { status: "unauthenticated" }
  | { status: "not_authorized" }
  | { status: "unsupported_market" }
  | { status: "temporary_failure" };

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v : null);
const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null;

export async function saveCatalogueProduct(ownedProductId: string, market: string): Promise<SaveOutcome> {
  try {
    const { data, error } = await supabase.rpc("save_own_product" as never, { p_product_id: ownedProductId, p_market: market } as never);
    if (error) {
      const code = (error as { code?: string }).code;
      if (code === "28000") return { status: "unauthenticated" };
      if (code === "42501") return { status: "not_authorized" };
      return { status: "temporary_failure" };
    }
    const root = obj(data);
    const s = str(root?.status);
    if (s === "SAVED" || root?.saved === true) return { status: "ok", saved: true };
    return { status: "temporary_failure" };
  } catch { return { status: "temporary_failure" }; }
}

export async function requestDeeperResearch(
  ownedProductId: string, market: string, freshnessHours = 168,
): Promise<ResearchOutcome> {
  try {
    const { data, error } = await supabase.rpc("fn_own_request_product_market_research" as never, {
      p_product_id: ownedProductId, p_market: market, p_freshness_hours: freshnessHours,
    } as never);
    if (error) {
      const code = (error as { code?: string }).code;
      if (code === "28000") return { status: "unauthenticated" };
      if (code === "42501") return { status: "not_authorized" };
      return { status: "temporary_failure" };
    }
    const root = obj(data);
    const s = (str(root?.status) ?? "").toUpperCase();
    if (s === "RESEARCHING") return { status: "researching", runId: str(root?.run_id), market: str(root?.market) ?? market };
    if (s === "CACHE_REUSED" || s === "CACHE_REUSED_IN_FLIGHT")
      return { status: "cache_reused", runId: str(root?.run_id), market: str(root?.market) ?? market };
    if (s === "ALLOWANCE_BLOCKED")
      return { status: "allowance_blocked", reason: str(root?.reason), remaining: num(root?.remaining), limit: num(root?.limit) };
    if (s === "UNSUPPORTED_MARKET") return { status: "unsupported_market" };
    if (s === "NOT_AUTHORIZED") return { status: "not_authorized" };
    return { status: "temporary_failure" };
  } catch { return { status: "temporary_failure" }; }
}
