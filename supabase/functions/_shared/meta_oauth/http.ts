// STRATELOQ-016C — Meta Facebook ORGANIC OAuth · edge HTTP/env/auth helpers
// ----------------------------------------------------------------------------
// Small server-side helpers shared by the four edge functions. Deno runtime.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

/** Browser-facing redirect used by the callback (never carries a token). */
export function redirectResponse(location: string): Response {
  return new Response(null, { status: 302, headers: { location, "cache-control": "no-store" } });
}

export function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.trim().length === 0) throw new Error(`missing_env:${name}`);
  return v.trim();
}

export function optionalEnv(name: string, fallback = ""): string {
  return (Deno.env.get(name) ?? fallback).trim();
}

/** service_role client — privileged, server-side only. */
export function serviceClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * A client bound to the CALLER's JWT so SECURITY DEFINER RPCs that read
 * auth.uid()/fn__own_tenant() resolve the real user. Returns null when no
 * bearer token is present.
 */
export function userClientFromRequest(req: Request): SupabaseClient | null {
  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer\s+.+/i.test(auth)) return null;
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Verify the caller is an authenticated user; returns their id or null. */
export async function verifyUser(userClient: SupabaseClient): Promise<string | null> {
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user?.id) return null;
  return data.user.id;
}

/** The exact callback redirect URI this deployment expects Meta to use. */
export function callbackRedirectUri(): string {
  const override = optionalEnv("META_FACEBOOK_OAUTH_REDIRECT_URI");
  if (override) return override;
  return `${requireEnv("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/meta-facebook-oauth-callback`;
}

// ----------------------------------------------------------------------------
// CORS — the three user-initiated functions (begin/select-page/disconnect) are
// invoked from the Strateloq browser app via supabase.functions.invoke(), which
// sends non-simple headers (authorization, apikey, x-client-info) and therefore a
// CORS preflight OPTIONS. Without an Access-Control-Allow-Origin the browser
// blocks the request and the real POST never runs. We reflect ONLY origins on the
// project's existing allowlist (ISSUANCE_ALLOWED_ORIGINS) — never a wildcard — so
// this stays as strict as the rest of the app. The Meta redirect callback is a
// top-level navigation (no fetch, no preflight) and does not use these helpers.
// ----------------------------------------------------------------------------

// Known Strateloq browser origins that MUST always be allowed, independent of the
// shared ISSUANCE_ALLOWED_ORIGINS env (maintained for the invitation/discovery
// flows). 016C.7 proved via production logs that the OPTIONS 204 carried NO
// Access-Control-Allow-Origin — i.e. the app's current custom domain is not in
// that env list — so the preflight failed and the browser blocked the POST.
// This list closes that gap deterministically. Still an explicit allowlist —
// never a wildcard.
const STRATELOQ_APP_ORIGINS: readonly string[] = [
  "https://globalintelligenceactions.com",
];

/** Build CORS headers, reflecting the request Origin only when it is allowlisted. */
export function corsHeadersForRequest(req: Request): Headers {
  const rawOrigin = req.headers.get("Origin");
  const norm = (s: string) => s.trim().replace(/\/+$/, ""); // tolerate trailing slash / whitespace
  const origin = norm(rawOrigin ?? "");
  const allow = new Set(
    [...STRATELOQ_APP_ORIGINS, ...optionalEnv("ISSUANCE_ALLOWED_ORIGINS").split(",")]
      .map(norm)
      .filter((s) => s.length > 0),
  );
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (rawOrigin && allow.has(origin)) {
    // reflect the exact Origin the browser sent (match is normalized, echo is verbatim)
    headers.set("Access-Control-Allow-Origin", rawOrigin);
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, apikey, x-client-info");
  }
  return headers;
}

/** Merge CORS headers onto an existing Response (used to wrap every reply). */
export function withCorsHeaders(res: Response, cors: Headers): Response {
  const headers = new Headers(res.headers);
  cors.forEach((v, k) => headers.set(k, v));
  return new Response(res.body, { status: res.status, headers });
}

/** Standard 204 CORS preflight reply. */
export function corsPreflightResponse(cors: Headers): Response {
  return new Response(null, { status: 204, headers: cors });
}

/**
 * Wrap a browser-invoked handler with CORS: answer the OPTIONS preflight and
 * attach CORS headers to every response so the browser can read the result.
 */
export function serveWithCors(handler: (req: Request) => Promise<Response>): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const cors = corsHeadersForRequest(req);
    if (req.method === "OPTIONS") return corsPreflightResponse(cors);
    return withCorsHeaders(await handler(req), cors);
  };
}
