"use client";
// STRATELOQ — Shared catalogue product card (W0.05). Shows a TRUTHFUL opportunity classification:
// confidence-floored band, decision, confidence, and evidence — with UNKNOWN rendered as "Unknown"
// (never zero), prices labelled by currency/market (cross-market references labelled), freshness/staleness
// shown, and only authorized images rendered (otherwise a neutral placeholder). Save / deeper research
// go through adoption (useSaveFromCatalogue / useResearchFromCatalogue).

import { Card, CardContent, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import type { CatalogueItem } from "@/lib/business-discovery/platform-catalogue-contract";
import { classifyBand, classifyConfidence, showNumber, showFreshness } from "@/lib/business-discovery/opportunity-classification";
import { useSaveFromCatalogue, useResearchFromCatalogue } from "@/hooks/use-catalogue-actions";
import { useToast } from "@/components/ui/use-toast";

const toneClass: Record<string, string> = {
  positive: "bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-100",
  info: "bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-100",
  caution: "bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100",
  negative: "bg-rose-100 text-rose-900 dark:bg-rose-900/40 dark:text-rose-100",
  neutral: "bg-muted text-muted-foreground",
};

// Only render an image when the backend marked it authorized; otherwise a neutral placeholder.
function imageIsAuthorized(item: CatalogueItem): boolean {
  return item.imageState === "AUTHORIZED" && !!item.imageRef;
}

export function CatalogueOpportunityCard({ item }: { item: CatalogueItem }) {
  const band = classifyBand(item.opportunityBand, item.decision);
  const conf = classifyConfidence(item.evidenceConfidence);
  const save = useSaveFromCatalogue();
  const research = useResearchFromCatalogue();
  const { toast } = useToast();

  async function onSave() {
    const o = await save.mutateAsync({ catalogueId: item.catalogueId, market: item.market });
    toast(o.status === "ok"
      ? { title: "Saved to your products" }
      : { title: "Could not save", description: friendly(o.status), variant: "destructive" });
  }
  async function onResearch() {
    const o = await research.mutateAsync({ catalogueId: item.catalogueId, market: item.market });
    if (o.status === "researching") toast({ title: "Deep research started", description: "One research action used." });
    else if (o.status === "cache_reused") toast({ title: "Using recent results", description: "No action charged." });
    else if (o.status === "allowance_blocked") toast({ title: "Research limit reached", description: `Remaining: ${showNumber(o.remaining)} of ${showNumber(o.limit)}`, variant: "destructive" });
    else toast({ title: "Could not start research", description: friendly(o.status), variant: "destructive" });
  }

  return (
    <Card className="flex flex-col h-full">
      <div className="aspect-video w-full overflow-hidden rounded-t-lg bg-muted flex items-center justify-center">
        {imageIsAuthorized(item)
          ? <img src={item.imageRef!} alt={item.title} className="h-full w-full object-cover" loading="lazy" />
          : <span className="text-xs text-muted-foreground px-3 text-center">Image pending authorized media</span>}
      </div>
      <CardHeader className="pb-2">
        <CardTitle className="text-base leading-snug line-clamp-2">{item.title || "Untitled product"}</CardTitle>
        <div className="flex flex-wrap items-center gap-2 pt-1">
          <Badge className={toneClass[band.tone]}>{band.label}</Badge>
          <Badge variant="outline">{item.decision ?? "No decision"}</Badge>
          <Badge variant="outline" className={toneClass[conf.tone]}>{conf.label}</Badge>
        </div>
      </CardHeader>
      <CardContent className="flex-1 space-y-2 text-sm">
        <p className="text-muted-foreground">{band.caption}</p>
        <dl className="grid grid-cols-2 gap-x-3 gap-y-1">
          <dt className="text-muted-foreground">Market</dt><dd>{item.market}{item.currency ? ` · ${item.currency}` : ""}</dd>
          <dt className="text-muted-foreground">Category</dt><dd>{item.category ?? "Unknown"}</dd>
          <dt className="text-muted-foreground">Opportunity score</dt><dd>{showNumber(item.opportunityScore)}</dd>
          <dt className="text-muted-foreground">Evidence coverage</dt><dd>{item.coverage === null ? "Unknown" : `${Math.round((item.coverage ?? 0) * 100)}%`}</dd>
          <dt className="text-muted-foreground">Freshness</dt><dd>{showFreshness(item.freshnessAsOf, item.isStale)}</dd>
          <dt className="text-muted-foreground">Source</dt><dd>{item.sourceProvider ?? "Unknown"}</dd>
        </dl>
      </CardContent>
      <CardFooter className="gap-2">
        <Button size="sm" variant="secondary" onClick={onSave} disabled={save.isPending}>
          {save.isPending ? "Saving…" : "Save"}
        </Button>
        <Button size="sm" onClick={onResearch} disabled={research.isPending}>
          {research.isPending ? "Starting…" : "Deep research"}
        </Button>
      </CardFooter>
    </Card>
  );
}

function friendly(s: string): string {
  switch (s) {
    case "unauthenticated": return "Please sign in.";
    case "not_authorized": return "Your plan does not allow this.";
    case "unsupported_market": return "This market is not supported.";
    default: return "Please try again.";
  }
}
