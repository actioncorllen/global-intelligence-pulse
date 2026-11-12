// Pure live/test routing decision for stripe-card-setup — no I/O, unit-testable.
// LIVE is selected ONLY when: the approval flag is on, a LIVE secret key is configured
// (sk_live_ OR rk_live_ restricted), AND the member is on the server-side pilot allowlist.
// Any non-pilot member ALWAYS uses the test key — the live key is never selected for them.

export function isLiveKey(k: string): boolean {
  return k.startsWith("sk_live_") || k.startsWith("rk_live_");
}

export interface RoutingDecision {
  liveConfigured: boolean;
  useLive: boolean;
  activeKey: string;
  mode: "live" | "test";
}

export function liveRoutingDecision(
  liveAllowed: boolean,
  testKey: string,
  liveKey: string,
  isPilot: boolean,
): RoutingDecision {
  const liveConfigured = liveAllowed && isLiveKey(liveKey);
  const useLive = liveConfigured && isPilot === true;
  return {
    liveConfigured,
    useLive,
    activeKey: useLive ? liveKey : testKey,
    mode: useLive ? "live" : "test",
  };
}
