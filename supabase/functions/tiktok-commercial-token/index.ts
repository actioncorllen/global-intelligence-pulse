// STRATELOQ-TIKTOK-SECURE-TOKEN-BROKER-014E/014F
// Server-side TikTok Commercial Content token broker (014D Option B).
//
// Trusted-server pattern (like meta-insights-reader): gateway verify_jwt=true, provider
// secrets read ONLY from Edge Function env, never logged/returned. Trusted-server gate:
// the caller must present the project's service_role key (matched against the built-in
// SUPABASE_SERVICE_ROLE_KEY env) OR a service_role JWT claim -- so a normal anon/browser
// JWT (which passes verify_jwt) still cannot obtain a TikTok token. Fail closed.
//
// 014F.7 hardening: the two secrets are .trim()'d to strip surrounding whitespace/newlines
// introduced during secret storage/copy-paste (014F.6 proved both carried a trailing
// newline, which TikTok rejected as invalid_client "Client info is illegal or malformed").
// Only SURROUNDING whitespace is removed; internal characters are never altered.
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

// Scrub any secret material (raw or trimmed) from anything we return.
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  for (const name of [CLIENT_KEY_ENV, CLIENT_SECRET_ENV]) {
    const v = Deno.env.get(name);
    if (v && v.length > 0) {
      s = s.split(v).join("[REDACTED]");
      const t = v.trim();
      if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]");
    }
  }
  s = s.replace(/("?(?:client_secret|client_key|access_token)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

function callerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const parts = m[1].split(".");
  if (parts.length < 2) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    return JSON.parse(atob(pad)).role ?? null;
  } catch {
    return null;
  }
}

function isTrustedServer(req: Request): boolean {
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const apikey = req.headers.get("apikey") || "";
  const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  return callerRole(req) === "service_role" || timingSafeEqual(apikey, svc) || timingSafeEqual(bearer, svc);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });

  // Trusted-server gate first: only the service_role caller may reach the broker at all.
  if (!isTrustedServer(req)) return jsonResponse(403, { ok: false, error: "forbidden_requires_service_role" });

  // Optional presence probe (query ?probe=1, header x-broker-probe: 1, or body {"probe":true}).
  let probe = new URL(req.url).searchParams.get("probe") === "1" || req.headers.get("x-broker-probe") === "1";
  const raw = await req.text();
  if (!probe && raw && raw.trim().length > 0) {
    try {
      const p = JSON.parse(raw);
      if (p && p.probe === true) probe = true;
    } catch {
      return jsonResponse(400, { ok: false, error: "invalid_json" });
    }
  }

  // 014F.7: normalize ONLY surrounding whitespace/newlines; never alter internal characters.
  const clientKey = (Deno.env.get(CLIENT_KEY_ENV) ?? "").trim();
  const clientSecret = (Deno.env.get(CLIENT_SECRET_ENV) ?? "").trim();

  if (probe) {
    return jsonResponse(200, { ok: true, mode: "probe", secrets_present: Boolean(clientKey) && Boolean(clientSecret) });
  }

  // Fail closed if the server secrets are not installed (empty after trim).
  if (!clientKey || !clientSecret) return jsonResponse(424, { ok: false, error: "server_secret_unavailable" });

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
