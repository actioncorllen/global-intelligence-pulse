// STRATELOQ-016C — meta-facebook-oauth-begin
// ----------------------------------------------------------------------------
// Secure server-side entrypoint that STARTS a Meta Facebook ORGANIC connection.
// verify_jwt=true (an authenticated Strateloq user is required). It:
//   1. verifies the caller is authenticated
//   2. resolves the tenant + authorization SERVER-SIDE via fn__own_tenant()
//      (inside fn_social_oauth_begin; the client cannot assert a tenant)
//   3. mints a cryptographically strong single-use OAuth state (raw returned
//      only on the authorize URL; only its SHA-256 hash is stored)
//   4. writes a PENDING_OAUTH / ORGANIC / META_FACEBOOK connection row
//   5. builds the Meta authorize URL server-side with the MINIMUM Page scopes
//   6. returns ONLY the safe authorize URL
//
// Never exposes the Meta App Secret or any token.

import {
  jsonResponse,
  requireEnv,
  optionalEnv,
  userClientFromRequest,
  verifyUser,
  callbackRedirectUri,
} from "../_shared/meta_oauth/http.ts";
import { generateOAuthState, sha256Hex } from "../_shared/meta_oauth/security.ts";
import { metaFacebookOrganicRequestedScopeParam } from "../_shared/meta_oauth/scopes.ts";

const PLATFORM = "META_FACEBOOK";

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });

  const userClient = userClientFromRequest(req);
  if (!userClient) return jsonResponse(401, { ok: false, error: "authentication_required" });
  const userId = await verifyUser(userClient);
  if (!userId) return jsonResponse(401, { ok: false, error: "authentication_required" });

  let appId: string, graphVersion: string, redirectUri: string;
  try {
    appId = requireEnv("META_APP_ID");
    graphVersion = optionalEnv("META_GRAPH_VERSION", "v21.0");
    redirectUri = callbackRedirectUri();
    // App secret is required later (callback); assert it is installed so we fail
    // fast here rather than after the founder has authorized with Meta.
    requireEnv("META_APP_SECRET");
  } catch (e) {
    return jsonResponse(424, { ok: false, error: "server_not_configured", detail: (e as Error).message });
  }

  // Raw state -> hash (only the hash is persisted).
  const rawState = generateOAuthState();
  const stateHash = await sha256Hex(rawState);

  const { data, error } = await userClient.rpc("fn_social_oauth_begin", {
    p_platform: PLATFORM,
    p_state_hash: stateHash,
    p_redirect_uri: redirectUri,
    p_ttl_seconds: 600,
  });
  if (error) return jsonResponse(500, { ok: false, error: "begin_failed" });
  if (!data || data.ok !== true) {
    const code = String((data && data.error) || "begin_rejected");
    const status = code === "unauthenticated" ? 401 : code === "tenant_unresolved" ? 403 : 400;
    return jsonResponse(status, { ok: false, error: code });
  }

  // Build the Meta authorize URL. Facebook Login for Business uses a config_id;
  // fall back to explicit scopes when no configuration id is set.
  const configId = optionalEnv("META_FB_LOGIN_CONFIG_ID");
  const authorize = new URL(`https://www.facebook.com/${graphVersion}/dialog/oauth`);
  authorize.searchParams.set("client_id", appId);
  authorize.searchParams.set("redirect_uri", redirectUri);
  authorize.searchParams.set("state", rawState);
  authorize.searchParams.set("response_type", "code");
  if (configId) {
    authorize.searchParams.set("config_id", configId);
  } else {
    authorize.searchParams.set("scope", metaFacebookOrganicRequestedScopeParam());
  }

  return jsonResponse(200, {
    ok: true,
    authorize_url: authorize.toString(),
    connection_id: data.connection_id,
    // redirect_uri is echoed so an operator can confirm it matches Meta config.
    redirect_uri: redirectUri,
  });
});
