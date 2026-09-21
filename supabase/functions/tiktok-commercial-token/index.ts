// STRATELOQ-TIKTOK-SECURE-TOKEN-BROKER-014E
// Server-side TikTok Commercial Content token broker (014D Option B).
//
// Mirrors the established trusted-server pattern (meta-insights-reader): Deno.serve,
// gateway verify_jwt=true, provider secrets read ONLY from Edge Function env, never
// logged, never returned. Adds an explicit service_role claim check so a normal
// anon/browser JWT can NOT obtain a TikTok token (fail closed).
//
// Responsibility (only): authenticate the trusted server caller, read the two TikTok
// secrets from env, POST the form-urlencoded client_credentials request to TikTok, and
// return the minimum token result. It does not touch the database and does not persist
// the access token.
//
// Secrets (names only; values live solely as Edge Function secrets):
//   TIKTOK_COMMERCIAL_CLIENT_KEY
//   TIKTOK_COMMERCIAL_CLIENT_SECRET

const TIKTOK_TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/";
const CLIENT_KEY_ENV = "TIKTOK_COMMERCIAL_CLIENT_KEY";
const CLIENT_SECRET_ENV = "TIKTOK_COMMERCIAL_CLIENT_SECRET";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

// Scrub any secret material from anything we return. Never let client_key/client_secret/
// access_token leak into an error body.
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  for (const name of [CLIENT_KEY_ENV, CLIENT_SECRET_ENV]) {
    const v = Deno.env.get(name);
    if (v && v.length > 0) s = s.split(v).join("[REDACTED]");
  }
  s = s.replace(/("?(?:client_secret|client_key|access_token)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
}

// The gateway (verify_jwt=true) has already validated the JWT signature before this code
// runs; we only read the already-trusted `role` claim to require service_role.
function callerRole(req: Request): string | null {
  const auth = req.headers.get("authorization") || "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const parts = m[1].split(".");
  if (parts.length < 2) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    const payload = JSON.parse(atob(pad));
    return typeof payload?.role === "string" ? payload.role : null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  }

  // Trusted-server gate: only service_role may broker a TikTok token.
  if (callerRole(req) !== "service_role") {
    return jsonResponse(403, { ok: false, error: "forbidden_requires_service_role" });
  }

  // Reject a malformed request body when one is provided (broker needs no input).
  let probe = new URL(req.url).searchParams.get("probe") === "1";
  const raw = await req.text();
  if (raw && raw.trim().length > 0) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && parsed.probe === true) probe = true;
    } catch {
      return jsonResponse(400, { ok: false, error: "invalid_json" });
    }
  }

  const clientKey = Deno.env.get(CLIENT_KEY_ENV);
  const clientSecret = Deno.env.get(CLIENT_SECRET_ENV);

  // Presence probe: report only whether both secrets exist. Never reads/returns values,
  // never contacts TikTok. Lets an operator confirm installation safely.
  if (probe) {
    return jsonResponse(200, {
      ok: true,
      mode: "probe",
      secrets_present: Boolean(clientKey) && Boolean(clientSecret),
    });
  }

  // Fail closed if the server secrets are not installed.
  if (!clientKey || !clientSecret) {
    return jsonResponse(424, { ok: false, error: "server_secret_unavailable" });
  }

  const form = new URLSearchParams();
  form.set("client_key", clientKey);
  form.set("client_secret", clientSecret);
  form.set("grant_type", "client_credentials");

  try {
    const r = await fetch(TIKTOK_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const j = await r.json().catch(() => ({}));
    const accessToken = j?.access_token ?? null;

    if (!r.ok || !accessToken) {
      return jsonResponse(r.ok ? 502 : r.status, {
        ok: false,
        http_status: r.status,
        error: redact(j?.error_description ?? j?.error ?? j?.message ?? "token_request_failed"),
        error_code: typeof j?.error === "string" ? j.error : null,
      });
    }

    // Minimum token result the n8n executor needs. access_token is short-lived (~7200s).
    return jsonResponse(200, {
      ok: true,
      access_token: accessToken,
      token_type: j?.token_type ?? "Bearer",
      expires_in: j?.expires_in ?? null,
    });
  } catch (e) {
    return jsonResponse(502, { ok: false, error: redact((e as Error).message) });
  }
});
