// Independent server-side pilot authorisation for LIVE card registration in stripe-webhook.
// Defense-in-depth: live Checkout Sessions are already created only for allowlisted pilots by
// stripe-card-setup, but the webhook INDEPENDENTLY re-verifies pilot membership before registering
// a LIVE card. Pure + unit-testable; no I/O.
//
// Rules:
//  - TEST (livemode=false) card registration is NOT pilot-gated — existing sandbox behaviour is preserved.
//  - LIVE (livemode=true) registration proceeds ONLY on a positively-verified, ENABLED pilot.
//  - Fail closed otherwise: missing / disabled / revoked -> deterministic refuse (HTTP 200 ack, no
//    retry storm); unverifiable (allowlist lookup failed) -> HTTP 500 (retryable), never register.
//  - payment_method.detached is handled elsewhere and is deliberately NOT gated, so a legitimate
//    live card can still be detached after pilot access is revoked.

export type PilotLookup =
  | { ok: true; enabled: boolean } // allowlist lookup succeeded (enabled=false covers missing/disabled/revoked)
  | { ok: false }; // allowlist lookup failed / unverifiable

export interface LiveRegDecision {
  register: boolean;
  httpStatus: number;
  outcome: string;
}

export function liveCardRegistrationDecision(livemode: boolean, pilot: PilotLookup): LiveRegDecision {
  if (!livemode) {
    return { register: true, httpStatus: 200, outcome: "register_test" };
  }
  if (!pilot.ok) {
    // Unverifiable (e.g. DB error) -> fail closed, signal retryable failure, do NOT register.
    return { register: false, httpStatus: 500, outcome: "live_pilot_unverifiable" };
  }
  if (!pilot.enabled) {
    // Missing / disabled / revoked -> deterministic refuse; acknowledge so Stripe stops retrying.
    return { register: false, httpStatus: 200, outcome: "live_pilot_denied" };
  }
  return { register: true, httpStatus: 200, outcome: "register_live" };
}
