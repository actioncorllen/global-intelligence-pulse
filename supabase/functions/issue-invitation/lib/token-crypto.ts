// ============================================================================
// Pulse — Tasks 2–3 · Invitation Token Cryptographic Utility (U2)
// ----------------------------------------------------------------------------
// INTERNAL cryptographic primitives for the invitation system: secure token
// generation, SHA-256 hashing, and constant-time hash comparison. Later consumed
// by invitation issuance, validation, and acceptance.
//
// This module ONLY creates and verifies cryptographic values. It performs NO
// persistence, NO SQL, NO database access, NO invitation lifecycle, NO HTTP, NO
// fetch, NO Edge Functions, and NO n8n. It uses only the platform Web Crypto API
// (globalThis.crypto / crypto.subtle) already available to the project — no
// third-party cryptographic libraries.
//
// Authority: Round-2 D04 (docs/backend/tasks-2-3/…-round-2.md). The stored hash
// contract (`TokenHash`) is the frozen U1 type (SHA-256, lowercase hexadecimal,
// exactly 64 characters); this module imports it rather than redefining it.
//
// SECURITY MODEL:
//   * Only `generateInvitationToken` uses randomness; hashing and comparison are
//     deterministic.
//   * The RAW token is never persisted or logged (D04). Only its SHA-256 digest
//     is ever stored. Storing the digest — not the token — means a database read
//     cannot reveal a usable token: an attacker with the stored hash still cannot
//     derive the pre-image needed to consume an invitation.
//   * Validation recomputes the digest of the presented token and compares it to
//     the stored digest with a best-effort fixed-work comparison over the decoded
//     32 digest bytes, reducing — not mathematically eliminating — timing
//     side-channel signal about how many characters matched. JavaScript runtimes
//     do not guarantee constant-time execution for handwritten loops; the helper
//     documents this limitation (see `timingSafeEqualHex`).
// ============================================================================

import type { TokenHash } from "./domain-contracts.ts";

// ── Branded internal types ──────────────────────────────────────────────────

declare const __tokenBrand: unique symbol;

/**
 * A raw invitation token: a URL-safe encoding of 256 bits of CSPRNG entropy
 * (Round-2 D04). Deliberately a different representation from the stored digest.
 * MUST be delivered only through the invitation channel and never persisted.
 */
export type InvitationToken = string & { readonly [__tokenBrand]: "InvitationToken" };

/**
 * The stored invitation token hash. Alias of the frozen U1 `TokenHash` contract
 * (SHA-256 digest, lowercase hexadecimal, exactly 64 characters). Provided as a
 * named alias for invitation-system call sites; the authority remains U1.
 */
export type InvitationTokenHash = TokenHash;

// ── Constants ───────────────────────────────────────────────────────────────

/** 256 bits of entropy for the raw token (Round-2 D04). */
const INVITATION_TOKEN_BYTES = 32;

/** URL-safe base64 alphabet (RFC 4648 §5): `+`/`/` replaced by `-`/`_`. */
const BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/** Canonical SHA-256 digest length in lowercase hexadecimal characters. */
const SHA256_HEX_LENGTH = 64;

// ── Internal encoders (pure, deterministic) ─────────────────────────────────

/** Encode bytes as unpadded URL-safe base64 (deterministic). */
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

/** Encode bytes as lowercase hexadecimal (deterministic). */
function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

/** Map a lowercase-hex character code to its nibble value, or -1 if not `0-9a-f`. */
function lowercaseHexNibble(code: number): number {
  if (code >= 48 && code <= 57) return code - 48; // '0'..'9'
  if (code >= 97 && code <= 102) return code - 87; // 'a'..'f'
  return -1; // uppercase and any non-hex character are rejected (canonical = lowercase)
}

/**
 * Decode a canonical SHA-256 digest — exactly 64 lowercase-hex characters — into
 * its 32 bytes. Returns null (fail closed) for any input that is not a canonical
 * lowercase-hex digest of the correct length.
 */
function decodeSha256Hex(hex: string): Uint8Array | null {
  if (hex.length !== SHA256_HEX_LENGTH) return null;
  const out = new Uint8Array(SHA256_HEX_LENGTH / 2);
  for (let i = 0; i < SHA256_HEX_LENGTH; i += 2) {
    const hi = lowercaseHexNibble(hex.charCodeAt(i));
    const lo = lowercaseHexNibble(hex.charCodeAt(i + 1));
    if (hi < 0 || lo < 0) return null;
    out[i / 2] = (hi << 4) | lo;
  }
  return out;
}

// ── Public primitives ───────────────────────────────────────────────────────

/**
 * Generate a fresh invitation token: 256 bits of cryptographically-secure random
 * entropy, URL-safe base64-encoded. This is the ONLY function that uses
 * randomness; it takes no input and embeds no timestamp or metadata. The returned
 * raw token must be delivered only through the invitation channel and never
 * persisted — only its hash (see `hashInvitationToken`) may be stored.
 */
export function generateInvitationToken(): InvitationToken {
  const bytes = new Uint8Array(INVITATION_TOKEN_BYTES);
  crypto.getRandomValues(bytes);
  return bytesToBase64Url(bytes) as InvitationToken;
}

/**
 * Hash an invitation token with SHA-256 and return the lowercase 64-character
 * hexadecimal digest (the `TokenHash` contract). Deterministic: the same UTF-8
 * input always yields the same digest. Used both to derive the value stored at
 * issuance and to recompute the digest of a presented token during validation.
 */
export async function hashInvitationToken(token: string): Promise<InvitationTokenHash> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return bytesToHex(new Uint8Array(digest)) as InvitationTokenHash;
}

/**
 * Best-effort fixed-work equality for two SHA-256 hash digests. Both operands are
 * first decoded from canonical lowercase-hex (exactly 64 chars) to 32 bytes; any
 * non-canonical input (wrong length, uppercase, non-hex, empty) FAILS CLOSED and
 * returns false. For two valid digests the comparison runs a fixed 32-byte XOR
 * accumulation with no early return, so it does not branch on how many bytes
 * matched — reducing partial-match timing signal about a secret digest.
 *
 * RUNTIME LIMITATION: this is NOT a mathematically guaranteed constant-time
 * operation. JavaScript engines provide no such guarantee for handwritten loops
 * (JIT, string handling, and branch prediction may introduce data-dependent
 * timing). The Web-Crypto-only constraint offers no native timing-safe primitive,
 * so this helper is a hardened best-effort comparison restricted to canonical
 * SHA-256 hex digests. It is symmetric and deterministic; normal `===` is
 * deliberately not used for the digest comparison.
 */
export function timingSafeEqualHex(a: InvitationTokenHash, b: InvitationTokenHash): boolean {
  const da = decodeSha256Hex(a);
  const db = decodeSha256Hex(b);
  if (da === null || db === null) return false; // fail closed on malformed input
  let diff = 0;
  for (let i = 0; i < da.length; i++) {
    diff |= da[i] ^ db[i];
  }
  return diff === 0;
}
