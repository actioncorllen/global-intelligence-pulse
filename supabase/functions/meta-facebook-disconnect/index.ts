// STRATELOQ-016C — meta-facebook-disconnect
// ----------------------------------------------------------------------------
// Minimum safe server-side disconnect/revoke path (016C §7). verify_jwt=true.
//   1. authenticates the user (fn_social_connection_disconnect re-checks tenant
//      ownership via fn__own_tenant inside the RPC)
//   2. optionally attempts Meta-side permission revocation — success is only
//      CLAIMED when the provider call actually confirms it
//   3. marks the connection REVOKED, clears the Vault secret (inside the RPC),
//      records revoked_at, so publishing preflight can never treat it as usable
//
// Never fabricates Meta-side revocation. Never returns or logs a token.

import {
  jsonResponse,
  requireEnv,
  optionalEnv,
  serviceClient,
  userClientFromRequest,
  verifyUser,
} from "../_shared/meta_oauth/http.ts";
import { MetaGraph } from "../_shared/meta_oauth/graph.ts";
import { redact } from "../_shared/meta_oauth/security.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  const userClient = userClientFromRequest(req);
  if (!userClient) return jsonResponse(401, { ok: false, error: "authentication_required" });
  const userId = await verifyUser(userClient);
  if (!userId) return jsonResponse(401, { ok: false, error: "authentication_required" });

  let connectionId = "", attemptMetaRevoke = false;
  try {
    const body = await req.json();
    connectionId = String(body?.connection_id || "");
    attemptMetaRevoke = body?.attempt_meta_revoke === true;
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }
  if (!connectionId) return jsonResponse(400, { ok: false, error: "connection_id_required" });

  try {
    const svc = serviceClient();

    // Resolve the caller's tenant and confirm ownership before touching the token.
    const { data: tenantData } = await userClient.rpc("fn__own_tenant");
    const callerTenant = tenantData ? String(tenantData) : null;
    if (!callerTenant) return jsonResponse(403, { ok: false, error: "tenant_unresolved" });

    const { data: conn } = await svc
      .from("social_platform_connections")
      .select("tenant_id,secret_ref")
      .eq("id", connectionId)
      .eq("connection_type", "ORGANIC")
      .maybeSingle();
    if (!conn || String(conn.tenant_id) !== callerTenant) {
      return jsonResponse(404, { ok: false, error: "connection_not_found" });
    }

    // Best-effort Meta-side revocation BEFORE the token is cleared. Only claim
    // success when Meta confirms it.
    let metaRevoked = false;
    if (attemptMetaRevoke && conn.secret_ref) {
      const { data: token } = await svc.rpc("fn_social_secret_read", { p_name: String(conn.secret_ref) });
      if (token) {
        requireEnv("META_APP_ID");
        const graph = new MetaGraph({ version: optionalEnv("META_GRAPH_VERSION", "v21.0") });
        const rev = await graph.revokePermissions(String(token));
        metaRevoked = rev.ok === true;
      }
    }

    // fn_social_connection_disconnect (user-context) re-verifies tenant ownership,
    // clears the Vault secret, sets REVOKED + revoked_at.
    const { data, error } = await userClient.rpc("fn_social_connection_disconnect", {
      p_connection_id: connectionId,
      p_meta_revoked: metaRevoked,
    });
    if (error) return jsonResponse(500, { ok: false, error: "disconnect_failed" });
    if (!data || data.ok !== true) {
      return jsonResponse(400, { ok: false, error: String(data?.error || "disconnect_rejected") });
    }

    return jsonResponse(200, {
      ok: true,
      connection_id: connectionId,
      meta_side_revoked: metaRevoked,
      note: attemptMetaRevoke && !metaRevoked
        ? "local connection revoked; Meta-side revocation not confirmed"
        : undefined,
    });
  } catch (e) {
    const reason = redact((e as Error).message, [Deno.env.get("META_APP_SECRET")]);
    return jsonResponse(500, { ok: false, error: "server_error", detail: reason });
  }
});
