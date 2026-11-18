"use client";
// STRATELOQ — "Shared Catalogue | My Research" workspace (W0.05).
// Segmented control switches between the shared platform catalogue (browse/adopt/save/research) and the
// customer's own research workspace (existing component). Handles loading / error / empty-market /
// not-entitled / unauthenticated states honestly. Browsing costs 0 research actions (server-enforced).

import { useState } from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Skeleton } from "@/components/ui/skeleton";
import { useCatalogueMarkets, useCatalogueBrowse } from "@/hooks/use-platform-catalogue";
import { CatalogueCountrySelector } from "@/components/business-discovery/CatalogueCountrySelector";
import { CatalogueOpportunityCard } from "@/components/business-discovery/CatalogueOpportunityCard";
// Existing customer research workspace (unchanged):
import { EcommerceWorkspace } from "@/components/business-discovery/EcommerceWorkspace";

export function CatalogueWorkspace() {
  const [tab, setTab] = useState<"catalogue" | "research">("catalogue");
  const [market, setMarket] = useState<string | null>(null);

  const markets = useCatalogueMarkets(tab === "catalogue");
  const firstWithData = markets.data?.status === "ok" ? markets.data.value.find((m) => m.hasData)?.code ?? null : null;
  const activeMarket = market ?? firstWithData;
  const browse = useCatalogueBrowse(tab === "catalogue" ? activeMarket : null);

  return (
    <Tabs value={tab} onValueChange={(v) => setTab(v as typeof tab)} className="w-full">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <TabsList>
          <TabsTrigger value="catalogue">Shared catalogue</TabsTrigger>
          <TabsTrigger value="research">My research</TabsTrigger>
        </TabsList>
        {tab === "catalogue" && (
          <CatalogueCountrySelector
            value={activeMarket}
            onChange={setMarket}
            markets={markets.data?.status === "ok" ? markets.data.value : []}
            disabled={markets.isLoading}
          />
        )}
      </div>

      <TabsContent value="catalogue" className="pt-4">
        {renderCatalogue()}
      </TabsContent>
      <TabsContent value="research" className="pt-4">
        <EcommerceWorkspace />
      </TabsContent>
    </Tabs>
  );

  function renderCatalogue() {
    if (markets.isLoading) return <GridSkeleton />;
    if (markets.data?.status === "unauthenticated" || browse.data?.status === "unauthenticated")
      return <Empty title="Sign in to browse the catalogue" body="The shared catalogue is available to signed-in subscribers." />;
    if (markets.data?.status === "not_entitled" || browse.data?.status === "not_entitled")
      return <Empty title="Catalogue access requires an active plan" body="Upgrade or reactivate your subscription to browse shared products." />;
    if (markets.data?.status === "temporary_failure")
      return <ErrorState onRetry={() => markets.refetch()} />;
    if (!activeMarket) return <Empty title="No markets available yet" body="Published products will appear here as markets are populated." />;
    if (browse.isLoading) return <GridSkeleton />;
    if (!browse.data || browse.data.status === "temporary_failure")
      return <ErrorState onRetry={() => browse.refetch()} />;
    if (browse.data.status === "unsupported_market")
      return <Empty title="Market not supported" body="This market is not available in the catalogue." />;
    if (browse.data.status !== "ok") return <ErrorState onRetry={() => browse.refetch()} />;

    const items = browse.data.value.items;
    if (items.length === 0)
      return <Empty title="No products for this market yet"
        body="Nothing is published here at the moment. Products that lose source rights are withdrawn automatically, so this list only shows currently cleared items." />;

    return (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {items.map((it) => <CatalogueOpportunityCard key={it.catalogueId} item={it} />)}
      </div>
    );
  }
}

function GridSkeleton() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
      {Array.from({ length: 8 }).map((_, i) => <Skeleton key={i} className="h-72 w-full rounded-lg" />)}
    </div>
  );
}
function Empty({ title, body }: { title: string; body: string }) {
  return (
    <div className="rounded-lg border border-dashed p-10 text-center">
      <p className="font-medium">{title}</p>
      <p className="text-sm text-muted-foreground mt-1 max-w-md mx-auto">{body}</p>
    </div>
  );
}
function ErrorState({ onRetry }: { onRetry: () => void }) {
  return (
    <div className="rounded-lg border border-dashed p-10 text-center">
      <p className="font-medium">Something went wrong</p>
      <p className="text-sm text-muted-foreground mt-1">We couldn’t load the catalogue just now.</p>
      <button className="mt-3 text-sm underline" onClick={onRetry}>Try again</button>
    </div>
  );
}
