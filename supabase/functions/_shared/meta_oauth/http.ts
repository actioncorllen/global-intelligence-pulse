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
