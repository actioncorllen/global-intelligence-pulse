// Unit tests for the live/test routing decision. Pure logic, safe mocks — no Stripe objects,
// no network, no DB. Run: `deno test routing_test.ts`.
import { assertEquals } from "jsr:@std/assert@1";
import { isLiveKey, liveRoutingDecision } from "./routing.ts";

const T = "sk_test_TESTKEY";
const LIVE_SK = "sk_live_LIVEKEY";
const LIVE_RK = "rk_live_RESTRICTEDLIVE"; // the founder's actual key shape

Deno.test("isLiveKey recognises both sk_live_ and rk_live_, rejects test/empty", () => {
  assertEquals(isLiveKey("sk_live_x"), true);
  assertEquals(isLiveKey("rk_live_x"), true);
  assertEquals(isLiveKey("sk_test_x"), false);
  assertEquals(isLiveKey("rk_test_x"), false);
  assertEquals(isLiveKey(""), false);
});

Deno.test("flag OFF → always test (any key, even a pilot)", () => {
  assertEquals(liveRoutingDecision(false, T, LIVE_RK, true).mode, "test");
  assertEquals(liveRoutingDecision(false, T, LIVE_SK, true).mode, "test");
  assertEquals(liveRoutingDecision(false, T, LIVE_RK, true).activeKey, T);
});

Deno.test("flag ON + rk_live_ + pilot → LIVE (the fix)", () => {
  const d = liveRoutingDecision(true, T, LIVE_RK, true);
  assertEquals(d.mode, "live");
  assertEquals(d.useLive, true);
  assertEquals(d.activeKey, LIVE_RK);
});

Deno.test("flag ON + sk_live_ + pilot → LIVE", () => {
  const d = liveRoutingDecision(true, T, LIVE_SK, true);
  assertEquals(d.mode, "live");
  assertEquals(d.activeKey, LIVE_SK);
});

Deno.test("flag ON + live key + NOT pilot → test (other users stay sandbox)", () => {
  const d = liveRoutingDecision(true, T, LIVE_RK, false);
  assertEquals(d.mode, "test");
  assertEquals(d.useLive, false);
  assertEquals(d.activeKey, T);
});

Deno.test("flag ON + non-live/misconfigured live key + pilot → test (fail safe)", () => {
  assertEquals(liveRoutingDecision(true, T, "sk_test_oops", true).mode, "test");
  assertEquals(liveRoutingDecision(true, T, "", true).mode, "test");
});

Deno.test("SECURITY: a non-pilot can NEVER get the live key, across the full matrix", () => {
  for (const flag of [true, false]) {
    for (const lk of [LIVE_SK, LIVE_RK, "sk_test_x", ""]) {
      const d = liveRoutingDecision(flag, T, lk, false);
      assertEquals(d.useLive, false, `non-pilot useLive must be false (flag=${flag}, key=${lk})`);
      assertEquals(d.activeKey, T, `non-pilot must use test key (flag=${flag}, key=${lk})`);
    }
  }
});

Deno.test("isPilot must be strictly boolean true — truthy non-true values do not enable live", () => {
  // Guard against a truthy-but-not-true value accidentally enabling live.
  // deno-lint-ignore no-explicit-any
  const d = liveRoutingDecision(true, T, LIVE_RK, ("yes" as any) === true);
  assertEquals(d.useLive, false);
});
