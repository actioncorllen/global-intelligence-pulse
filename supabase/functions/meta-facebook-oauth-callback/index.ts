// STRATELOQ-016C — meta-facebook-oauth-callback (edge wrapper)
// ----------------------------------------------------------------------------
// Meta redirects the browser here with ?code&state (or ?error...). There is NO
// Supabase user JWT on this redirect, so the request is authorized SOLELY by the
// single-use, tenant/user-bound OAuth state minted at begin.
//
// DEPLOYMENT REQUIREMENT: this function MUST be deployed with verify_jwt = false
// (Meta's browser redirect carries no Supabase JWT). All other 016C functions
// keep verify_jwt = true. Core logic lives in ./logic.ts (unit-tested).

import {
  jsonResponse,
  redirectResponse,
  requireEnv,
  optionalEnv,
  serviceClient,
} from "../_shared/meta_oauth/http.ts";
import { redact } from "../_shared/meta_oauth/security.ts";
import { MetaGraph } from "../_shared/meta_oauth/graph.ts";
import { appRedirect, processCallback } from "./logic.ts";

Deno.serve(async (req) => {
  let appBaseUrl = "";
  try {
    const url = new URL(req.url);
    const appId = requireEnv("META_APP_ID");
    const appSecret = requireEnv("META_APP_SECRET");
    appBaseUrl = optionalEnv("APP_BASE_URL") ||
      `${requireEnv("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/meta-facebook-oauth-callback`;
    const graphVersion = optionalEnv("META_GRAPH_VERSION", "v21.0");
    const svc = serviceClient();
    const graph = new MetaGraph({ version: graphVersion });

    const result = await processCallback({
      code: url.searchParams.get("code"),
      state: url.searchParams.get("state"),
      metaError: url.searchParams.get("error") || url.searchParams.get("error_description"),
      appId,
      appSecret,
      appBaseUrl,
      graph,
      consumeState: async (h) => {
        const { data, error } = await svc.rpc("fn_social_oauth_consume", { p_state_hash: h });
        if (error) return { ok: false };
        return data as Record<string, unknown>;
      },
      putUserSecret: async (connectionId, userToken) => {
        const name = `social:${connectionId}:user`;
        const { data, error } = await svc.rpc("fn_social_secret_put", { p_name: name, p_value: userToken });
        if (error) throw new Error("secret_put_failed");
        return String(data);
      },
      setDiscovered: async (connectionId, tenantId, userSecretRef, pages) => {
        const { data, error } = await svc.rpc("fn_social_meta_set_discovered", {
          p_connection_id: connectionId,
          p_tenant_id: tenantId,
          p_user_secret_ref: userSecretRef,
          p_pages: pages,
        });
        if (error) return { ok: false };
        return data as Record<string, unknown>;
      },
    });

    if ("redirectTo" in result) return redirectResponse(result.redirectTo);
    return jsonResponse(result.status, result.body);
  } catch (e) {
    // Never leak tokens/secrets in error output.
    const reason = redact((e as Error).message, [Deno.env.get("META_APP_SECRET")]);
    if (appBaseUrl) {
      try {
        return redirectResponse(appRedirect(appBaseUrl, { status: "error", reason: "server_error" }));
      } catch { /* fall through */ }
    }
    return jsonResponse(500, { ok: false, error: "server_error", detail: reason });
  }
});
