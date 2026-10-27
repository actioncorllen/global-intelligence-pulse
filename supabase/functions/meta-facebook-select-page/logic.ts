// STRATELOQ-016C — meta-facebook-select-page · core logic (dependency-injected)
// ----------------------------------------------------------------------------
// Imports only shared helpers (no Deno.serve, no http.ts, no npm client) so it
// is unit-testable under both Deno and Node with mocked dependencies.

import { MetaGraph, expiryToIso } from "../_shared/meta_oauth/graph.ts";
import { metaFacebookOrganicScopesOk } from "../_shared/meta_oauth/scopes.ts";

export interface DiscoveredPageRef {
  id: string;
  tasks: string[];
}

export interface PendingConnection {
  tenant_id: string;
  authorization_status: string;
  secret_ref: string | null;
  // Pages discovered at OAuth-callback time (from the /me/accounts edge), each with
  // its granted tasks. `tasks` cannot be re-queried on a Page node (Graph #100), so
  // the capabilities are derived from this stored discovery data.
  discovered_pages: DiscoveredPageRef[];
}

export interface SelectDeps {
  connectionId: string;
  pageId: string;
  callerTenant: string | null;
  appId: string;
  appSecret: string;
  graph: MetaGraph;
  loadPending: (connectionId: string) => Promise<PendingConnection | null>;
  readUserSecret: (secretRef: string) => Promise<string | null>;
  putPageSecret: (connectionId: string, pageToken: string) => Promise<string>;
  finalize: (args: {
    connectionId: string;
    tenantId: string;
    pageId: string;
    pageName: string;
    grantedScopes: string[];
    pageTasks: string[];
    pageSecretRef: string;
    expiresAt: string | null;
    verified: boolean;
  }) => Promise<Record<string, unknown>>;
}

export async function processSelectPage(
  deps: SelectDeps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (!deps.connectionId || !deps.pageId) {
    return { status: 400, body: { ok: false, error: "connection_id_and_page_id_required" } };
  }
  if (!deps.callerTenant) {
    return { status: 403, body: { ok: false, error: "tenant_unresolved" } };
  }

  const pending = await deps.loadPending(deps.connectionId);
  if (!pending) return { status: 404, body: { ok: false, error: "pending_connection_not_found" } };
  if (pending.tenant_id !== deps.callerTenant) {
    return { status: 403, body: { ok: false, error: "tenant_mismatch" } };
  }
  if (pending.authorization_status !== "PENDING_OAUTH") {
    return { status: 409, body: { ok: false, error: "connection_not_pending" } };
  }
  const selectedDiscovered = pending.discovered_pages.find((p) => p.id === deps.pageId);
  if (!selectedDiscovered) {
    return { status: 400, body: { ok: false, error: "page_not_in_discovered_set" } };
  }
  if (!pending.secret_ref) {
    return { status: 409, body: { ok: false, error: "no_user_token_on_record" } };
  }

  const userToken = await deps.readUserSecret(pending.secret_ref);
  if (!userToken) return { status: 409, body: { ok: false, error: "user_token_unavailable" } };

  // Derive the chosen Page's access token (Page node cannot be queried for `tasks`).
  const pat = await deps.graph.pageAccessToken(userToken, deps.pageId);
  if (!pat.ok || !pat.data?.access_token) {
    return { status: 502, body: { ok: false, error: "page_token_unavailable" } };
  }
  const pageToken = pat.data.access_token;
  const pageName = String(pat.data.name || "");
  // Tasks come from the discovery metadata (the /me/accounts edge captured at callback).
  const pageTasks = selectedDiscovered.tasks.map(String);

  // granted scopes (from Meta, not from what we requested)
  const scopeRes = await deps.graph.grantedScopes(userToken);
  const grantedScopes = scopeRes.ok ? (scopeRes.data || []) : [];
  const subset = metaFacebookOrganicScopesOk(grantedScopes);
  if (!subset.ok) {
    return { status: 403, body: { ok: false, error: "insufficient_scopes", missing: subset.missing } };
  }

  // NON-PUBLISHING verification: read-only GET on the Page with the Page token
  const verify = await deps.graph.verifyPageReadOnly(pageToken, deps.pageId);
  const verified = verify.ok && String(verify.data?.id || "") === deps.pageId;
  if (!verified) {
    return { status: 502, body: { ok: false, error: "verification_failed" } };
  }

  // determine expiry (Page tokens are frequently non-expiring => null)
  let expiresAt: string | null = null;
  const dbg = await deps.graph.debugToken(deps.appId, deps.appSecret, pageToken);
  if (dbg.ok) expiresAt = expiryToIso(dbg.data?.data?.expires_at);

  const pageSecretRef = await deps.putPageSecret(deps.connectionId, pageToken);

  const fin = await deps.finalize({
    connectionId: deps.connectionId,
    tenantId: deps.callerTenant,
    pageId: deps.pageId,
    pageName,
    grantedScopes,
    pageTasks,
    pageSecretRef,
    expiresAt,
    verified: true,
  });
  if (!fin || fin.ok !== true) {
    return { status: 500, body: { ok: false, error: String(fin?.error || "finalize_failed") } };
  }

  return {
    status: 200,
    body: {
      ok: true,
      connection_id: fin.connection_id,
      page_id: deps.pageId,
      display_name: pageName,
      capabilities: fin.capabilities,
      granted_scopes: grantedScopes,
      expires_at: expiresAt,
    },
  };
}
