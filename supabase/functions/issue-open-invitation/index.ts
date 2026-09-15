import { createClient } from "@supabase/supabase-js";

function reqEnv(v: string | undefined, name: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new Error(`invalid issue-open-invitation environment configuration: ${name}`);
  }
  return v;
}
const SUPABASE_URL = reqEnv(Deno.env.get("SUPABASE_URL"), "SUPABASE_URL");
const SUPABASE_ANON_KEY = reqEnv(Deno.env.get("SUPABASE_ANON_KEY"), "SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = reqEnv(
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  "SUPABASE_SERVICE_ROLE_KEY",
);
const ALLOWED_ORIGINS = reqEnv(Deno.env.get("ISSUANCE_ALLOWED_ORIGINS"), "ISSUANCE_ALLOWED_ORIGINS");
const FOUNDER_AUTH_USER_IDS = reqEnv(
  Deno.env.get("FOUNDER_ISSUER_AUTH_USER_IDS"),
  "FOUNDER_ISSUER_AUTH_USER_IDS",
);

const CLIENT_OPTIONS = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
} as const;
const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, CLIENT_OPTIONS);
const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CLIENT_OPTIONS);

const allowedOrigins = new Set(
  ALLOWED_ORIGINS.split(",").map((s) => s.trim()).filter((s) => s.length > 0),
);
const founderIds = new Set(
  FOUNDER_AUTH_USER_IDS.split(",").map((s) => s.trim()).filter((s) => s.length > 0),
);

const BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
function bytesToBase64Url(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const triple = (b0 << 16) | (b1 << 8) | b2;
    out += BASE64URL_ALPHABET[(triple >> 18) & 0x3f];
    out += BASE64URL_ALPHABET[(triple >> 12) & 0x3f];
    if (i + 1 < bytes.length) out += BASE64URL_ALPHABET[(triple >> 6) & 0x3f];
    if (i + 2 < bytes.length) out += BASE64URL_ALPHABET[triple & 0x3f];
  }
  return out;
}
function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, "0");
  return out;
}
function generateInvitationToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return bytesToBase64Url(bytes);
}
async function hashInvitationToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return bytesToHex(new Uint8Array(digest));
}

function buildCorsHeaders(allowedOrigin: string | null): Headers {
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (allowedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", allowedOrigin);
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, apikey, x-client-info");
  }
  return headers;
}
function jsonResponse(body: object, status: number, cors: Headers): Response {
  const headers = new Headers(cors);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

function validEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const e = raw.trim().toLowerCase();
  if (e.length === 0 || e.length > 254) return null;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) return null;
  return e;
}

Deno.serve(async (request: Request): Promise<Response> => {
  const origin = request.headers.get("Origin");
  const allowedOrigin = origin !== null && allowedOrigins.has(origin) ? origin : null;
  const cors = buildCorsHeaders(allowedOrigin);
  if (allowedOrigin === null) {
    return jsonResponse({ ok: false, code: "forbidden_origin" }, 403, cors);
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    const headers = new Headers(cors);
    headers.set("Allow", "POST, OPTIONS");
    headers.set("Content-Type", "application/json");
    return new Response(JSON.stringify({ ok: false, code: "method_not_allowed" }), {
      status: 405,
      headers,
    });
  }

  const authHeader = request.headers.get("Authorization") ?? "";
  const bearer = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  let uid: string | null = null;
  try {
    const { data, error } = await anonClient.auth.getUser(bearer);
    if (!error && data.user) uid = data.user.id;
  } catch {
    /* fall through to 401 */
  }
  if (uid === null) {
    return jsonResponse({ ok: false, code: "authentication_required" }, 401, cors);
  }

  if (!founderIds.has(uid)) {
    return jsonResponse({ ok: false, code: "unauthorized" }, 403, cors);
  }

  let body: { bound_email?: unknown };
  try {
    body = (await request.json()) as { bound_email?: unknown };
  } catch {
    return jsonResponse({ ok: false, code: "invalid_request" }, 400, cors);
  }
  const email = validEmail(body?.bound_email);
  if (email === null) {
    return jsonResponse({ ok: false, code: "invalid_email" }, 400, cors);
  }

  const token = generateInvitationToken();
  const tokenHash = await hashInvitationToken(token);

  const result = await serviceClient.rpc("issue_open_invitation", {
    p_bound_email: email,
    p_token_hash: tokenHash,
  });
  if (result.error) {
    return jsonResponse({ ok: false, code: "temporary_failure" }, 503, cors);
  }
  const data = (result.data ?? {}) as { status?: unknown; invitation_ref?: unknown };
  if (data.status === "issued") {
    return jsonResponse(
      {
        ok: true,
        status: "issued",
        token,
        invitation_ref: typeof data.invitation_ref === "string" ? data.invitation_ref : null,
      },
      200,
      cors,
    );
  }
  return jsonResponse({ ok: false, code: "rejected" }, 422, cors);
});
