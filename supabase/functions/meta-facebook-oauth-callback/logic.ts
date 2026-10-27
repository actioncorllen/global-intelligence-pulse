// STRATELOQ-016C — meta-facebook-oauth-callback · core logic (dependency-injected)
// ----------------------------------------------------------------------------
// Pure of runtime specifics: imports only shared helpers (no Deno.serve, no
// http.ts, no npm client) so it is unit-testable under both Deno and Node with
// fully mocked dependencies (016C §10 deterministic Meta paths).

import { sha256Hex } from "../_shared/meta_oauth/security.ts";
import { MetaGraph, type DiscoveredPage } from "../_shared/meta_oauth/graph.ts";

export interface CallbackDeps {
  code: string | null;
  state: string | null;
  metaError: string | null; // ?error / ?error_description passed by Meta
  appId: string;
  appSecret: string;
  appBaseUrl: string;
  graph: MetaGraph;
  consumeState: (stateHash: string) => Promise<Record<string, unknown>>;
  putUserSecret: (connectionId: string, userToken: string) => Promise<string>;
  setDiscovered: (
    connectionId: string,
    tenantId: string,
    userSecretRef: string,
    pages: DiscoveredPage[],
  ) => Promise<Record<string, unknown>>;
}

export function appRedirect(base: string, params: Record<string, string>): string {
  const u = new URL(base);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.toString();
}

/** Core callback logic. Returns a browser redirect location (never a token). */
export async function processCallback(
  deps: CallbackDeps,
): Promise<{ redirectTo: string } | { status: number; body: unknown }> {
  const connectScreen = deps.appBaseUrl;

  // 1. Meta returned an error (e.g. user denied) — truthful, no token involved.
  if (deps.metaError) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "meta_denied" }) };
  }
  if (!deps.state) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "missing_state" }) };
  }
  if (!deps.code) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "missing_code" }) };
  }

  // 2. validate + single-use consume the state
  const stateHash = await sha256Hex(deps.state);
  const consumed = await deps.consumeState(stateHash);
  if (!consumed || consumed.ok !== true) {
    // generic message to the browser; the DB classified the reason server-side
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "invalid_state" }) };
  }
  const connectionId = String(consumed.connection_id);
  const tenantId = String(consumed.tenant_id);
  const redirectUri = String(consumed.redirect_uri || "");

  // 3. exchange the code -> user token -> long-lived user token
  const ex = await deps.graph.exchangeCode({
    appId: deps.appId,
    appSecret: deps.appSecret,
    redirectUri,
    code: deps.code,
  });
  if (!ex.ok || !ex.data?.access_token) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "code_exchange_failed" }) };
  }
  const ll = await deps.graph.exchangeLongLived({
    appId: deps.appId,
    appSecret: deps.appSecret,
    shortToken: ex.data.access_token,
  });
  const userToken = ll.ok && ll.data?.access_token ? ll.data.access_token : ex.data.access_token;

  // 4. discover Pages (safe metadata only; per-Page tokens are NOT surfaced here)
  const disc = await deps.graph.discoverPages(userToken);
  if (!disc.ok) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "page_discovery_failed" }) };
  }
  const pages = disc.data || [];
  if (pages.length === 0) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "no_manageable_pages" }) };
  }

  // 5. store the long-lived USER token in Vault; record safe discovered pages
  const userSecretRef = await deps.putUserSecret(connectionId, userToken);
  const set = await deps.setDiscovered(connectionId, tenantId, userSecretRef, pages);
  if (!set || set.ok !== true) {
    return { redirectTo: appRedirect(connectScreen, { status: "error", reason: "persist_failed" }) };
  }

  // 6. hand back to the app for explicit Page selection (never auto-connect)
  return {
    redirectTo: appRedirect(connectScreen, {
      status: "select_page",
      connection_id: connectionId,
      pages: String(pages.length),
    }),
  };
}
