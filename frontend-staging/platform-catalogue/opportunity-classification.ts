// STRATELOQ — Truthful opportunity classification mapping (W0.04/W0.05).
// The backend (fn_pod_evaluate) now returns a CONFIDENCE-FLOORED opportunity_band: a high raw score on
// thin single-axis evidence (e.g. advertising activity alone, with NONE/LOW confidence) is floored to
// INSUFFICIENT and can never present as a high-test classification. This mapping renders the band, the
// decision and the evidence confidence honestly, and NEVER renders UNKNOWN values as zero.

export type Decision = "TEST" | "WATCH" | "AVOID" | "INSUFFICIENT_EVIDENCE" | string;
export type Confidence = "HIGH" | "MEDIUM" | "LOW" | "NONE" | string | null;

export interface ClassificationView {
  label: string;
  tone: "neutral" | "info" | "positive" | "caution" | "negative";
  // short, honest one-liner safe to show to a subscriber
  caption: string;
}

// Band is the authoritative, confidence-floored opportunity classification for display.
export function classifyBand(band: string | null, decision: Decision | null): ClassificationView {
  switch ((band ?? "").toUpperCase()) {
    case "EXCEPTIONAL":
    case "HIGH_CONFIDENCE_TEST":
      return { label: "High-confidence test", tone: "positive", caption: "Demand, competition and verified supplier economics all support a test." };
    case "STRONG_TEST":
      return { label: "Strong test candidate", tone: "positive", caption: "Multiple independent signals support a test; verify before scaling." };
    case "TRENDING_WATCH":
      return { label: "Trending — watch", tone: "info", caption: "Promising but not yet test-ready; gather more local evidence." };
    case "WATCH":
      return { label: "Watch", tone: "caution", caption: "Not test-ready — one or more gates unresolved." };
    case "AVOID":
      return { label: "Avoid", tone: "negative", caption: "Evidence or economics argue against this product in this market." };
    case "INSUFFICIENT":
    default:
      return {
        label: "Insufficient evidence",
        tone: "neutral",
        caption: decision === "WATCH"
          ? "Not enough verified evidence to classify this opportunity yet."
          : "Not enough verified evidence to classify this opportunity.",
      };
  }
}

export function classifyConfidence(conf: Confidence): { label: string; tone: ClassificationView["tone"] } {
  switch ((conf ?? "").toUpperCase()) {
    case "HIGH": return { label: "High confidence", tone: "positive" };
    case "MEDIUM": return { label: "Medium confidence", tone: "info" };
    case "LOW": return { label: "Low confidence", tone: "caution" };
    default: return { label: "Confidence unknown", tone: "neutral" };
  }
}

// Render any numeric metric honestly: null/undefined -> "Unknown" (never 0).
export function showNumber(n: number | null | undefined, opts?: { suffix?: string; digits?: number }): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return "Unknown";
  const v = opts?.digits !== undefined ? n.toFixed(opts.digits) : String(n);
  return opts?.suffix ? `${v}${opts.suffix}` : v;
}

// Local price rendering with currency + market; cross-market/estimated prices are labelled, never shown as local fact.
export function showLocalPrice(amount: number | null | undefined, currency: string | null, metricScope?: string | null): string {
  if (amount === null || amount === undefined || !Number.isFinite(amount)) return "Price unknown";
  const base = `${currency ?? ""} ${amount}`.trim();
  if (metricScope && metricScope !== "LOCAL") return `${base} (reference, not locally validated)`;
  return base;
}

// Freshness label; stale evidence is flagged, missing freshness is "Unknown", never implied fresh.
export function showFreshness(asOf: string | null, isStale: boolean | null): string {
  if (!asOf) return "Freshness unknown";
  const d = new Date(asOf);
  const when = Number.isNaN(d.getTime()) ? asOf : d.toLocaleDateString();
  return isStale ? `As of ${when} — stale` : `As of ${when}`;
}
