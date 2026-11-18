"use client";
// STRATELOQ — 18-market country selector for the shared catalogue (W0.05).
// Lists all 18 approved markets; markets with no published data are shown but disabled with an honest
// "no data yet" note (never hidden, never faked). Data presence comes from fn_catalogue_browse_markets().

import { Select, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { CatalogueMarket } from "@/lib/business-discovery/platform-catalogue-contract";

// Canonical 18 approved markets (matches ecommerce_market_universe eligible set).
export const APPROVED_MARKETS: ReadonlyArray<{ code: string; name: string; currency: string }> = [
  { code: "AT", name: "Austria", currency: "EUR" }, { code: "AU", name: "Australia", currency: "AUD" },
  { code: "BE", name: "Belgium", currency: "EUR" }, { code: "CA", name: "Canada", currency: "CAD" },
  { code: "CH", name: "Switzerland", currency: "CHF" }, { code: "DE", name: "Germany", currency: "EUR" },
  { code: "ES", name: "Spain", currency: "EUR" }, { code: "FR", name: "France", currency: "EUR" },
  { code: "GB", name: "United Kingdom", currency: "GBP" }, { code: "HK", name: "Hong Kong", currency: "HKD" },
  { code: "IE", name: "Ireland", currency: "EUR" }, { code: "IT", name: "Italy", currency: "EUR" },
  { code: "MY", name: "Malaysia", currency: "MYR" }, { code: "NL", name: "Netherlands", currency: "EUR" },
  { code: "PH", name: "Philippines", currency: "PHP" }, { code: "PL", name: "Poland", currency: "PLN" },
  { code: "SG", name: "Singapore", currency: "SGD" }, { code: "US", name: "United States", currency: "USD" },
];

export function CatalogueCountrySelector(props: {
  value: string | null;
  onChange: (code: string) => void;
  markets?: CatalogueMarket[]; // from fetchCatalogueMarkets(); drives which have data
  disabled?: boolean;
}) {
  const dataByCode = new Map((props.markets ?? []).map((m) => [m.code, m]));
  return (
    <Select value={props.value ?? undefined} onValueChange={props.onChange} disabled={props.disabled}>
      <SelectTrigger className="w-[220px]" aria-label="Select market">
        <SelectValue placeholder="Select a market" />
      </SelectTrigger>
      <SelectContent>
        <SelectGroup>
          <SelectLabel>Approved markets (18)</SelectLabel>
          {APPROVED_MARKETS.map((m) => {
            const d = dataByCode.get(m.code);
            const hasData = d?.hasData ?? false;
            const count = d?.productCount ?? 0;
            return (
              <SelectItem key={m.code} value={m.code} disabled={!hasData}>
                <span className="inline-flex items-center gap-2">
                  <span>{m.name} ({m.code}) · {m.currency}</span>
                  <span className="text-xs text-muted-foreground">
                    {hasData ? `${count} product${count === 1 ? "" : "s"}` : "no data yet"}
                  </span>
                </span>
              </SelectItem>
            );
          })}
        </SelectGroup>
      </SelectContent>
    </Select>
  );
}
