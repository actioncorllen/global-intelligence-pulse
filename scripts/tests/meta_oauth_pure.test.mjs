// STRATELOQ-016C — deterministic unit tests (Node, no Deno/DB/Meta required).
// Run:  node --experimental-strip-types scripts/tests/meta_oauth_pure.test.mjs
//
// Exercises the PURE helpers and the dependency-injected callback/select-page
// core logic with fully MOCKED Meta responses. No live Meta call is made and no
// live/mocked run is ever reported as a real connection.

import {
  META_FACEBOOK_ORGANIC_REQUIRED_SCOPES,
  scopeSubsetOk,
  metaFacebookOrganicScopesOk,
} from "../../supabase/functions/_shared/meta_oauth/scopes.ts";
import { capabilitiesFromMetaTasks, capabilitiesSupportMedia } from "../../supabase/functions/_shared/meta_oauth/capabilities.ts";
import { sha256Hex, generateOAuthState, looksLikeToken, isValidSecretRef, redact } from "../../supabase/functions/_shared/meta_oauth/security.ts";
import { processCallback } from "../../supabase/functions/meta-facebook-oauth-callback/logic.ts";
import { processSelectPage } from "../../supabase/functions/meta-facebook-select-page/logic.ts";

let passed = 0, failed = 0;
function check(name, cond) {
  if (cond) { passed++; console.log(`  PASS  ${name}`); }
  else { failed++; console.log(`  FAIL  ${name}`); }
}
async function section(title, fn) { console.log(`\n# ${title}`); await fn(); }

// ---- Mock Meta Graph factory -------------------------------------------------
function mockGraph(overrides = {}) {
  return {
    async exchangeCode() { return { ok: true, status: 200, data: { access_token: "SHORT_USER_TOKEN" } }; },
    async exchangeLongLived() { return { ok: true, status: 200, data: { access_token: "LL_USER_TOKEN", expires_in: 5184000 } }; },
    async discoverPages() { return { ok: true, status: 200, data: [{ id: "PAGE_1", name: "Pulse Intelligence", tasks: ["CREATE_CONTENT", "ANALYZE", "MANAGE"] }] }; },
    async grantedScopes() { return { ok: true, status: 200, data: ["pages_show_list", "pages_read_engagement", "pages_manage_posts", "business_management", "public_profile"] }; },
    async pageAccessToken() { return { ok: true, status: 200, data: { id: "PAGE_1", name: "Pulse Intelligence", access_token: "PAGE_TOKEN", tasks: ["CREATE_CONTENT", "ANALYZE"] } }; },
    async verifyPageReadOnly() { return { ok: true, status: 200, data: { id: "PAGE_1", name: "Pulse Intelligence", fan_count: 12 } }; },
    async debugToken() { return { ok: true, status: 200, data: { data: { expires_at: 0, is_valid: true } } }; },
    async revokePermissions() { return { ok: true, status: 200, data: { success: true } }; },
    ...overrides,
  };
}

await section("scope subset validation (§10 subset / extra / missing)", async () => {
  check("exact required set ok", metaFacebookOrganicScopesOk(META_FACEBOOK_ORGANIC_REQUIRED_SCOPES).ok);
  check("extra legitimate scopes accepted", metaFacebookOrganicScopesOk([
    ...META_FACEBOOK_ORGANIC_REQUIRED_SCOPES, "pages_manage_metadata", "public_profile", "email",
  ]).ok);
  const missing = metaFacebookOrganicScopesOk(["pages_show_list", "pages_read_engagement", "business_management"]);
  check("missing required scope rejected", !missing.ok && missing.missing.includes("pages_manage_posts"));
  check("case-insensitive match", scopeSubsetOk(["Pages_Manage_Posts"], ["PAGES_MANAGE_POSTS"]).ok);
  check("comma/space string form accepted", scopeSubsetOk(["a", "b"], "a, b c").ok);
});

await section("capabilities derived from tasks, never from scopes (§5)", async () => {
  const withCreate = capabilitiesFromMetaTasks(["CREATE_CONTENT", "ANALYZE"]);
  check("CREATE_CONTENT grants PUBLISH_IMAGE", withCreate.includes("PUBLISH_IMAGE"));
  check("CREATE_CONTENT grants PUBLISH_VIDEO", withCreate.includes("PUBLISH_VIDEO"));
  const noCreate = capabilitiesFromMetaTasks(["ANALYZE", "MODERATE", "MANAGE"]);
  check("no CREATE_CONTENT => no PUBLISH_*", !noCreate.some((c) => c.startsWith("PUBLISH_")));
  check("any task => READ_PROFILE", noCreate.includes("READ_PROFILE"));
  check("empty tasks => []", capabilitiesFromMetaTasks([]).length === 0);
  check("media support check", capabilitiesSupportMedia(withCreate, "VIDEO") && !capabilitiesSupportMedia(noCreate, "VIDEO"));
});

await section("token-shape guard + secret_ref validity (§4)", async () => {
  check("JWT rejected", looksLikeToken("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"));
  check("Bearer rejected", looksLikeToken("Bearer abcdef123456"));
  check("long opaque token rejected", looksLikeToken("A".repeat(210)));
  check("valid secret_ref accepted", isValidSecretRef("social:11111111-1111-1111-1111-111111111111:page"));
  check("empty secret_ref invalid", !isValidSecretRef(""));
  check(">120 char ref invalid", !isValidSecretRef("x".repeat(121)));
});

await section("crypto state + hashing (§9)", async () => {
  check("sha256 known vector", (await sha256Hex("abc")) === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  check("sha256 is 64 hex", /^[0-9a-f]{64}$/.test(await sha256Hex("x")));
  const s1 = generateOAuthState(), s2 = generateOAuthState();
  check("state is base64url", /^[A-Za-z0-9_-]+$/.test(s1));
  check("state has entropy length >= 43", s1.length >= 43);
  check("states are unique", s1 !== s2);
});

await section("redaction never leaks secrets", async () => {
  const out = redact("app_secret=SUPERSECRET and access_token=ABC123 body", ["SUPERSECRET"]);
  check("named secret stripped", !out.includes("SUPERSECRET"));
  check("access_token pattern stripped", !out.includes("ABC123"));
});

// ---- Callback logic: deterministic branches (§10) ---------------------------
const baseCallbackDeps = (over = {}) => ({
  code: "AUTH_CODE",
  state: "RAWSTATE",
  metaError: null,
  appId: "APP",
  appSecret: "SECRET",
  appBaseUrl: "https://app.example.com/connections",
  graph: mockGraph(),
  consumeState: async () => ({ ok: true, connection_id: "CONN_1", tenant_id: "TENANT_1", redirect_uri: "https://cb" }),
  putUserSecret: async () => "social:CONN_1:user",
  setDiscovered: async () => ({ ok: true, page_count: 1 }),
  ...over,
});
const reasonOf = (res) => new URL(res.redirectTo).searchParams.get("reason");
const statusOf = (res) => new URL(res.redirectTo).searchParams.get("status");

await section("callback: valid state → page selection", async () => {
  const res = await processCallback(baseCallbackDeps());
  check("redirects to select_page", statusOf(res) === "select_page");
  check("carries connection_id", new URL(res.redirectTo).searchParams.get("connection_id") === "CONN_1");
});

await section("callback: state failures all surface generically (§10)", async () => {
  check("missing state", reasonOf(await processCallback(baseCallbackDeps({ state: null }))) === "missing_state");
  check("missing code", reasonOf(await processCallback(baseCallbackDeps({ code: null }))) === "missing_code");
  check("meta error", reasonOf(await processCallback(baseCallbackDeps({ metaError: "access_denied" }))) === "meta_denied");
  check("invalid state (consume ok:false)", reasonOf(await processCallback(baseCallbackDeps({ consumeState: async () => ({ ok: false, reason: "unknown_state" }) }))) === "invalid_state");
  check("expired state → generic invalid_state", reasonOf(await processCallback(baseCallbackDeps({ consumeState: async () => ({ ok: false, reason: "expired" }) }))) === "invalid_state");
  check("reused state → generic invalid_state", reasonOf(await processCallback(baseCallbackDeps({ consumeState: async () => ({ ok: false, reason: "already_consumed" }) }))) === "invalid_state");
});

await section("callback: provider error paths (§10 mocks)", async () => {
  check("code exchange failure", reasonOf(await processCallback(baseCallbackDeps({
    graph: mockGraph({ exchangeCode: async () => ({ ok: false, status: 400, error: { message: "bad_code" } }) }),
  }))) === "code_exchange_failed");
  check("discovery failure", reasonOf(await processCallback(baseCallbackDeps({
    graph: mockGraph({ discoverPages: async () => ({ ok: false, status: 500, error: { message: "graph_down" } }) }),
  }))) === "page_discovery_failed");
  check("no manageable pages", reasonOf(await processCallback(baseCallbackDeps({
    graph: mockGraph({ discoverPages: async () => ({ ok: true, status: 200, data: [] }) }),
  }))) === "no_manageable_pages");
});

// ---- Select-page logic: deterministic branches (§10) ------------------------
const baseSelectDeps = (over = {}) => {
  let finalizeArgs = null;
  const deps = {
    connectionId: "CONN_1",
    pageId: "PAGE_1",
    callerTenant: "TENANT_1",
    appId: "APP",
    appSecret: "SECRET",
    graph: mockGraph(),
    loadPending: async () => ({ tenant_id: "TENANT_1", authorization_status: "PENDING_OAUTH", secret_ref: "social:CONN_1:user", discovered_ids: ["PAGE_1", "PAGE_2"] }),
    readUserSecret: async () => "LL_USER_TOKEN",
    putPageSecret: async () => "social:CONN_1:page",
    finalize: async (args) => { finalizeArgs = args; return { ok: true, connection_id: "CONN_1", capabilities: capabilitiesFromMetaTasks(args.pageTasks) }; },
    ...over,
  };
  return { deps, getFinalizeArgs: () => finalizeArgs };
};

await section("select-page: happy path connects with real capabilities", async () => {
  const { deps, getFinalizeArgs } = baseSelectDeps();
  const res = await processSelectPage(deps);
  check("200 ok", res.status === 200 && res.body.ok === true);
  check("capabilities include PUBLISH_IMAGE", res.body.capabilities.includes("PUBLISH_IMAGE"));
  check("finalize received verified=true", getFinalizeArgs()?.verified === true);
  check("granted scopes surfaced", Array.isArray(res.body.granted_scopes) && res.body.granted_scopes.includes("pages_manage_posts"));
});

await section("select-page: authorization + integrity guards (§10)", async () => {
  check("tenant mismatch → 403", (await processSelectPage(baseSelectDeps({ callerTenant: "OTHER" }).deps)).status === 403);
  check("unresolved tenant → 403", (await processSelectPage(baseSelectDeps({ callerTenant: null }).deps)).status === 403);
  const notDiscovered = await processSelectPage(baseSelectDeps({ pageId: "PAGE_UNKNOWN" }).deps);
  check("page not discovered → 400", notDiscovered.status === 400 && notDiscovered.body.error === "page_not_in_discovered_set");
  const notPending = await processSelectPage(baseSelectDeps({ loadPending: async () => ({ tenant_id: "TENANT_1", authorization_status: "CONNECTED", secret_ref: "r", discovered_ids: ["PAGE_1"] }) }).deps);
  check("already connected → 409", notPending.status === 409);
});

await section("select-page: scope + verification enforcement (§10)", async () => {
  const insufficient = await processSelectPage(baseSelectDeps({
    graph: mockGraph({ grantedScopes: async () => ({ ok: true, status: 200, data: ["pages_show_list", "public_profile"] }) }),
  }).deps);
  check("missing required scope → 403 insufficient_scopes", insufficient.status === 403 && insufficient.body.error === "insufficient_scopes");
  const notVerified = await processSelectPage(baseSelectDeps({
    graph: mockGraph({ verifyPageReadOnly: async () => ({ ok: false, status: 400, error: { message: "no_access" } }) }),
  }).deps);
  check("verification failure → 502", notVerified.status === 502 && notVerified.body.error === "verification_failed");
});

console.log(`\n================  ${passed} passed, ${failed} failed  ================`);
if (failed > 0) process.exit(1);
