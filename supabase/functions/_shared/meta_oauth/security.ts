// STRATELOQ-016C — Meta Facebook ORGANIC OAuth · security primitives (PURE)
// ----------------------------------------------------------------------------
// Cryptographic OAuth-state generation/hashing, token-shape detection, and
// output redaction. Uses ONLY the Web Crypto API (globalThis.crypto.subtle),
// which is available in both Deno (edge) and Node (tests) — no third-party libs.
//
// STATE MODEL (016C §9):
//   * The RAW state is 256 bits of CSPRNG entropy, base64url-encoded, and is the
//     only value placed on the Meta authorize URL / returned to the browser.
//   * Only the SHA-256 hash of the raw state is ever persisted server-side
//     (social_oauth_states.state_hash). A DB read cannot recover a usable state.
//   * Single-use + short-lived + tenant/user-bound is enforced in SQL by the
//     consume RPC; this module only produces/derives the values.

/** Generate a raw OAuth state: 32 bytes CSPRNG entropy, base64url (no padding). */
export function generateOAuthState(): string {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return base64urlEncode(bytes);
}

export function base64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** SHA-256 of a UTF-8 string as lowercase hex (64 chars). */
export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
  return hex;
}

/**
 * Mirror of the DB CHECK spc_secret_ref_not_token_chk: reject anything that
 * looks like a real bearer/JWT/long opaque token so a token value can never be
 * stored where only a NON-secret reference belongs.
 */
export function looksLikeToken(s: unknown): boolean {
  const v = String(s ?? "");
  if (v.length > 120) return true;
  if (/^eyJ/.test(v)) return true; // JWT
  if (/^Bearer\s/i.test(v)) return true;
  if (/^[A-Za-z0-9_-]{200,}$/.test(v)) return true; // long opaque token
  return false;
}

/** A valid NON-SECRET secret_ref is short and does not look like a token. */
export function isValidSecretRef(s: unknown): boolean {
  const v = String(s ?? "");
  return v.length > 0 && v.length <= 120 && !looksLikeToken(v);
}

/**
 * Redact known secret material from any string we might return or log. Pass the
 * concrete secret values (app secret, any access tokens seen this request) so
 * they are stripped verbatim, plus a structural pass for token-shaped fields.
 */
export function redact(input: unknown, secrets: (string | null | undefined)[] = []): string {
  let s = typeof input === "string" ? input : safeStringify(input);
  for (const sec of secrets) {
    if (sec && sec.length >= 6) {
      s = s.split(sec).join("[REDACTED]");
      const t = sec.trim();
      if (t.length >= 6 && t !== sec) s = s.split(t).join("[REDACTED]");
    }
  }
  s = s.replace(
    /("?(?:access_token|client_secret|app_secret|fb_exchange_token|code)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi,
    "$1[REDACTED]",
  );
  s = s.replace(/access_token=[^&"\s]+/gi, "access_token=[REDACTED]");
  return s.slice(0, 800);
}

function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v ?? "");
  } catch {
    return String(v);
  }
}
