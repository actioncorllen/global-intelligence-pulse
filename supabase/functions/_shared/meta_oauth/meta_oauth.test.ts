// STRATELOQ-016C — Deno test coverage for the Meta ORGANIC OAuth logic.
// Run in CI:  deno test --allow-none supabase/functions/_shared/meta_oauth/meta_oauth.test.ts
// (The authoritative, environment-independent suite is
//  scripts/tests/meta_oauth_pure.test.mjs, runnable under Node too.)

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { metaFacebookOrganicScopesOk, scopeSubsetOk } from "./scopes.ts";
import { capabilitiesFromMetaTasks } from "./capabilities.ts";
import { generateOAuthState, looksLikeToken, sha256Hex } from "./security.ts";
import { processCallback } from "../../meta-facebook-oauth-callback/logic.ts";
import { processSelectPage } from "../../meta-facebook-select-page/logic.ts";

function mockGraph(over: Record<string, unknown> = {}) {
  return {
    exchangeCode: async () => ({ ok: true, status: 200, data: { access_token: "SHORT" } }),
    exchangeLongLived: async () => ({ ok: true, status: 200, data: { access_token: "LL" } }),
    discoverPages: async () => ({ ok: true, status: 200, data: [{ id: "PAGE_1", name: "Pulse", tasks: ["CREATE_CONTENT"] }] }),
    grantedScopes: async () => ({ ok: true, status: 200, data: ["pages_show_list", "pages_read_engagement", "pages_manage_posts", "business_management"] }),
    pageAccessToken: async () => ({ ok: true, status: 200, data: { id: "PAGE_1", name: "Pulse", access_token: "PT", tasks: ["CREATE_CONTENT"] } }),
    verifyPageReadOnly: async () => ({ ok: true, status: 200, data: { id: "PAGE_1", name: "Pulse" } }),
    debugToken: async () => ({ ok: true, status: 200, data: { data: { expires_at: 0 } } }),
    revokePermissions: async () => ({ ok: true, status: 200, data: { success: true } }),
    ...over,
    // deno-lint-ignore no-explicit-any
  } as any;
}

Deno.test("scope subset accepts extras, rejects missing", () => {
  assert(metaFacebookOrganicScopesOk(["pages_show_list", "pages_read_engagement", "pages_manage_posts", "business_management", "public_profile"]).ok);
  assert(!metaFacebookOrganicScopesOk(["pages_show_list"]).ok);
  assert(scopeSubsetOk(["A"], ["a"]).ok);
});

Deno.test("capabilities derived from tasks only", () => {
  assert(capabilitiesFromMetaTasks(["CREATE_CONTENT"]).includes("PUBLISH_IMAGE"));
  assert(!capabilitiesFromMetaTasks(["ANALYZE"]).some((c) => c.startsWith("PUBLISH_")));
  assertEquals(capabilitiesFromMetaTasks([]).length, 0);
});

Deno.test("security primitives", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert(looksLikeToken("eyJabc.def.ghi"));
  assert(generateOAuthState() !== generateOAuthState());
});

const callbackDeps = (over = {}) => ({
  code: "C", state: "S", metaError: null, appId: "A", appSecret: "X",
  appBaseUrl: "https://app.example/con", graph: mockGraph(),
  consumeState: async () => ({ ok: true, connection_id: "CONN", tenant_id: "T", redirect_uri: "https://cb" }),
  putUserSecret: async () => "social:CONN:user",
  setDiscovered: async () => ({ ok: true }),
  ...over,
});

Deno.test("callback happy path → select_page", async () => {
  const r = await processCallback(callbackDeps()) as { redirectTo: string };
  assertEquals(new URL(r.redirectTo).searchParams.get("status"), "select_page");
});

Deno.test("callback invalid/expired/reused state → generic invalid_state", async () => {
  for (const reason of ["unknown_state", "expired", "already_consumed"]) {
    const r = await processCallback(callbackDeps({ consumeState: async () => ({ ok: false, reason }) })) as { redirectTo: string };
    assertEquals(new URL(r.redirectTo).searchParams.get("reason"), "invalid_state");
  }
});

const selectDeps = (over = {}) => ({
  connectionId: "CONN", pageId: "PAGE_1", callerTenant: "T", appId: "A", appSecret: "X",
  graph: mockGraph(),
  loadPending: async () => ({ tenant_id: "T", authorization_status: "PENDING_OAUTH", secret_ref: "social:CONN:user", discovered_ids: ["PAGE_1"] }),
  readUserSecret: async () => "LL",
  putPageSecret: async () => "social:CONN:page",
  finalize: async (a: { pageTasks: string[] }) => ({ ok: true, connection_id: "CONN", capabilities: capabilitiesFromMetaTasks(a.pageTasks) }),
  ...over,
});

Deno.test("select-page connects with real capabilities", async () => {
  const r = await processSelectPage(selectDeps());
  assertEquals(r.status, 200);
  assert((r.body.capabilities as string[]).includes("PUBLISH_IMAGE"));
});

Deno.test("select-page rejects tenant mismatch + insufficient scopes", async () => {
  assertEquals((await processSelectPage(selectDeps({ callerTenant: "OTHER" }))).status, 403);
  const insuff = await processSelectPage(selectDeps({ graph: mockGraph({ grantedScopes: async () => ({ ok: true, status: 200, data: ["pages_show_list"] }) }) }));
  assertEquals(insuff.status, 403);
  assertEquals(insuff.body.error, "insufficient_scopes");
});
