// ============================================================================
// Pulse — Tasks 2–3 · Production Exact-Origin Policy (U9D)
// ----------------------------------------------------------------------------
// The production implementation of U6's `OriginPolicy` (T23-D31). It parses an
// explicitly-supplied comma-separated allowlist ONCE at construction, then
// decides each request Origin by EXACT string membership. It is config-driven —
// no production origin is hard-coded here; the frozen allowlist and the
// missing-Origin decision are supplied by the future U9C entrypoint.
//
// SECURITY (T23-D31): exact-origin equality only — no wildcard, no suffix match,
// no subdomain match, no scheme/host/port inference, no normalization of a
// request value into acceptance. A request Origin is allowed only if it is a
// canonical origin AND textually identical to a validated allowlist entry. A
// MISSING Origin (`null`) is rejected (the frozen `allowMissingOrigin = false`);
// because U6's allowed-result must carry an origin to echo, this policy cannot
// represent an allowed missing Origin, so `allowMissingOrigin = true` fails
// construction rather than inventing a synthetic origin or widening the contract.
//
// This module performs NO transport (no HTTP request/response handling, no
// serverless entrypoint), NO environment reads, NO Supabase/database access, NO
// authentication, NO orchestration, and NO logging. It never returns the
// allowlist, alternative origins, a rejected value, a reason string, or
// configuration detail. Invalid configuration fails closed with one generic
// error that echoes no supplied value. U6 owns the 403 and CORS response.
// ============================================================================

import type { OriginPolicy, OriginPolicyResult } from "./invitation-acceptance-edge.ts";

// ── Configuration ───────────────────────────────────────────────────────────

/** Explicit configuration (U9C owns the environment source; U9D reads no env). */
export interface InvitationAcceptanceOriginPolicyConfig {
  /** Comma-separated exact origins (each an absolute http/https origin). */
  readonly allowedOrigins: string;
  /** Whether a missing Origin is permitted. Frozen `false` (T23-D31). */
  readonly allowMissingOrigin: boolean;
}

/** Single generic configuration error — echoes no supplied origin/allowlist value. */
const ORIGIN_CONFIG_ERROR = "invalid invitation acceptance origin configuration";

const REJECTED: OriginPolicyResult = { status: "rejected" };

// ── Canonical-origin validation ──────────────────────────────────────────────

/**
 * True only for a canonical, exact origin string: an absolute http/https URL with
 * an explicit host, no credentials/path/query/fragment/wildcard, whose text
 * exactly equals the URL parser's canonical `.origin` (which strips default
 * ports and trailing slashes). A wildcard is rejected explicitly because the URL
 * parser would otherwise treat `*` as an ordinary host character.
 */
function isCanonicalOrigin(value: string): boolean {
  if (value.includes("*")) {
    return false;
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    return false;
  }
  return value === url.origin;
}

/**
 * Parse and validate the allowlist once, fail-closed. Splits on commas, trims
 * each entry, and requires every entry to be a canonical origin with no empty or
 * duplicate entries. `allowMissingOrigin = true` is unsupported under U6's
 * allowed-result contract and fails construction. Throws only the generic error;
 * no supplied value is included.
 */
function buildAllowedOriginSet(
  config: InvitationAcceptanceOriginPolicyConfig,
): ReadonlySet<string> {
  if (typeof config.allowedOrigins !== "string") {
    throw new Error(ORIGIN_CONFIG_ERROR);
  }
  if (config.allowMissingOrigin) {
    throw new Error(ORIGIN_CONFIG_ERROR);
  }
  const allowed = new Set<string>();
  for (const segment of config.allowedOrigins.split(",")) {
    const origin = segment.trim();
    if (origin.length === 0) {
      throw new Error(ORIGIN_CONFIG_ERROR);
    }
    if (!isCanonicalOrigin(origin)) {
      throw new Error(ORIGIN_CONFIG_ERROR);
    }
    if (allowed.has(origin)) {
      throw new Error(ORIGIN_CONFIG_ERROR);
    }
    allowed.add(origin);
  }
  if (allowed.size === 0) {
    throw new Error(ORIGIN_CONFIG_ERROR);
  }
  return allowed;
}

// ── Factory ───────────────────────────────────────────────────────────────

/**
 * Create the production `OriginPolicy`. The allowlist is validated once here; the
 * per-request decision is a pure, deterministic EXACT membership test — a missing
 * Origin (`null`) and any origin not textually identical to a validated allowlist
 * entry are rejected, and an allowed request echoes only its exact matching
 * origin. No allowlist, alternative origin, rejected value, or reason is exposed;
 * ordinary request rejection never throws.
 */
export function createInvitationAcceptanceOriginPolicy(
  config: InvitationAcceptanceOriginPolicyConfig,
): OriginPolicy {
  const allowedOrigins = buildAllowedOriginSet(config);
  return {
    resolveOrigin: (origin: string | null): OriginPolicyResult => {
      if (origin === null) {
        return REJECTED;
      }
      if (allowedOrigins.has(origin)) {
        return { status: "allowed", allowedOrigin: origin };
      }
      return REJECTED;
    },
  };
}
