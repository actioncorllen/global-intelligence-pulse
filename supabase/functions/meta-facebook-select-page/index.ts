// STRATELOQ-016C — meta-facebook-select-page (edge wrapper)
// ----------------------------------------------------------------------------
// Finalizes a Meta Facebook ORGANIC connection after the user explicitly selects
// which discovered Page to connect. verify_jwt=true. Core logic in ./logic.ts.
// No post is created/edited/deleted. Tokens never reach the browser or logs.

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
import { processSelectPage } from "./logic.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  const userClient = userClientFromRequest(req);
  if (!userClient) return jsonResponse(401, { ok: false, error: "authentication_required" });
  const userId = await verifyUser(userClient);
  if (!userId) return jsonResponse(401, { ok: false, error: "authentication_required" });

  let connectionId = "", pageId = "";
  try {
    const body = await req.json();
    connectionId = String(body?.connection_id || "");
    pageId = String(body?.page_id || "");
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }

  try {
    const appId = requireEnv("META_APP_ID");
    const appSecret = requireEnv("META_APP_SECRET");
    const graphVersion = optionalEnv("META_GRAPH_VERSION", "v21.0");
    const svc = serviceClient();
    const graph = new MetaGraph({ version: graphVersion });

    // resolve the caller's own tenant server-side (never trust the client)
    const { data: tenantData } = await userClient.rpc("fn__own_tenant");
    const callerTenant = tenantData ? String(tenantData) : null;

    const result = await processSelectPage({
      connectionId,
      pageId,
      callerTenant,
      appId,
      appSecret,
      graph,
      loadPending: async (id) => {
        const { data, error } = await svc
          .from("social_platform_connections")
          .select("tenant_id,authorization_status,secret_ref,display_metadata")
          .eq("id", id)
          .eq("connection_type", "ORGANIC")
          .maybeSingle();
        if (error || !data) return null;
        const dp = (data.display_metadata as { discovered_pages?: { id?: string }[] } | null)?.discovered_pages;
        const discovered = Array.isArray(dp) ? dp.map((p) => String(p?.id)) : [];
        return {
          tenant_id: String(data.tenant_id),
          authorization_status: String(data.authorization_status),
          secret_ref: data.secret_ref ? String(data.secret_ref) : null,
          discovered_ids: discovered,
        };
      },
      readUserSecret: async (ref) => {
        const { data, error } = await svc.rpc("fn_social_secret_read", { p_name: ref });
        if (error || !data) return null;
        return String(data);
      },
      putPageSecret: async (id, token) => {
        const name = `social:${id}:page`;
        const { data, error } = await svc.rpc("fn_social_secret_put", { p_name: name, p_value: token });
        if (error) throw new Error("secret_put_failed");
        return String(data);
      },
      finalize: async (args) => {
        const { data, error } = await svc.rpc("fn_social_meta_finalize", {
          p_connection_id: args.connectionId,
          p_tenant_id: args.tenantId,
          p_user_id: userId,
          p_page_id: args.pageId,
          p_page_name: args.pageName,
          p_granted_scopes: args.grantedScopes,
          p_page_tasks: args.pageTasks,
          p_page_secret_ref: args.pageSecretRef,
          p_expires_at: args.expiresAt,
          p_verified: args.verified,
        });
        if (error) return { ok: false, error: "finalize_rpc_error" };
        return data as Record<string, unknown>;
      },
    });

    return jsonResponse(result.status, result.body);
  } catch (e) {
    const reason = redact((e as Error).message, [Deno.env.get("META_APP_SECRET")]);
    return jsonResponse(500, { ok: false, error: "server_error", detail: reason });
  }
});
