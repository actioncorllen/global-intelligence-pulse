// Unit tests for the independent LIVE pilot-authorisation gate. Pure logic, safe mocks — no Stripe,
// no network, no DB. Covers authorised, unauthorised, missing, revoked, unverifiable, and the retry
// semantics (deterministic outputs; denied -> 200 ack, unverifiable -> 500 retryable).
import { assertEquals } from "jsr:@std/assert@1";
import { liveCardRegistrationDecision, type PilotLookup } from "./pilot_auth.ts";

const ENABLED: PilotLookup = { ok: true, enabled: true };
const DISABLED: PilotLookup = { ok: true, enabled: false }; // also = missing / revoked
const UNVERIFIABLE: PilotLookup = { ok: false };

Deno.test("TEST-mode registration is NOT pilot-gated (sandbox preserved)", () => {
  for (const p of [ENABLED, DISABLED, UNVERIFIABLE]) {
    const d = liveCardRegistrationDecision(false, p);
    assertEquals(d.register, true);
    assertEquals(d.outcome, "register_test");
  }
});

Deno.test("LIVE + authorised enabled pilot -> register", () => {
  const d = liveCardRegistrationDecision(true, ENABLED);
  assertEquals(d.register, true);
  assertEquals(d.httpStatus, 200);
  assertEquals(d.outcome, "register_live");
});

Deno.test("LIVE + unauthorised/disabled/missing/revoked -> refuse (200 ack, no register)", () => {
  const d = liveCardRegistrationDecision(true, DISABLED);
  assertEquals(d.register, false);
  assertEquals(d.httpStatus, 200); // acknowledge so Stripe stops retrying a will-never-succeed event
  assertEquals(d.outcome, "live_pilot_denied");
});

Deno.test("LIVE + unverifiable (allowlist lookup failed) -> fail closed, 500 retryable, no register", () => {
  const d = liveCardRegistrationDecision(true, UNVERIFIABLE);
  assertEquals(d.register, false);
  assertEquals(d.httpStatus, 500);
  assertEquals(d.outcome, "live_pilot_unverifiable");
});

Deno.test("retries: decision is deterministic for identical inputs", () => {
  for (const [lm, p] of [[true, ENABLED], [true, DISABLED], [true, UNVERIFIABLE], [false, DISABLED]] as [boolean, PilotLookup][]) {
    assertEquals(liveCardRegistrationDecision(lm, p), liveCardRegistrationDecision(lm, p));
  }
});

Deno.test("SECURITY: a LIVE card registers ONLY for a positively-verified enabled pilot", () => {
  for (const p of [DISABLED, UNVERIFIABLE]) {
    assertEquals(liveCardRegistrationDecision(true, p).register, false);
  }
  assertEquals(liveCardRegistrationDecision(true, ENABLED).register, true);
});
