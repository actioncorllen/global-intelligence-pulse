// STRATELOQ-016C — Meta Facebook ORGANIC OAuth · scope helpers (PURE)
// ----------------------------------------------------------------------------
// Pure, side-effect-free helpers for Meta organic-publishing scope handling.
// No Deno APIs, no fetch, no I/O — importable and unit-testable under Node too.
//
// SECURITY / CORRECTNESS RULE (016C §"validate required scopes as a SUBSET"):
//   The connection is authorized when EVERY required scope is present in the
//   granted set. Additional legitimate Meta scopes (e.g. pages_manage_metadata,
//   public_profile, email) MUST NOT cause a false failure. We therefore check a
//   SUBSET relationship (required ⊆ granted), never an exact-set equality.

/** Minimum scopes required to connect a Meta Facebook Page for ORGANIC publishing. */
export const META_FACEBOOK_ORGANIC_REQUIRED_SCOPES: readonly string[] = [
  "pages_show_list",
  "pages_read_engagement",
  "pages_manage_posts",
  "business_management",
] as const;

/** Optional scopes we will request when available; never required for success. */
export const META_FACEBOOK_ORGANIC_OPTIONAL_SCOPES: readonly string[] = [
  "pages_manage_metadata",
  "public_profile",
] as const;

/** Normalise a scope token: trim + lowercase (Meta scopes are case-insensitive). */
export function normalizeScope(s: unknown): string {
  return String(s ?? "").trim().toLowerCase();
}

/** Normalise a granted-scope collection into a de-duplicated, lowercased array. */
export function normalizeScopes(scopes: unknown): string[] {
  const arr = Array.isArray(scopes)
    ? scopes
    : typeof scopes === "string"
    ? scopes.split(/[,\s]+/)
    : [];
  const seen = new Set<string>();
  for (const s of arr) {
    const n = normalizeScope(s);
    if (n.length > 0) seen.add(n);
  }
  return [...seen];
}

/**
 * SUBSET validation: returns { ok, missing } where ok === (required ⊆ granted).
 * Extra granted scopes are always accepted.
 */
export function scopeSubsetOk(
  required: readonly string[],
  granted: unknown,
): { ok: boolean; missing: string[] } {
  const grantedSet = new Set(normalizeScopes(granted));
  const missing = required
    .map(normalizeScope)
    .filter((r) => r.length > 0 && !grantedSet.has(r));
  return { ok: missing.length === 0, missing };
}

/** Convenience for the Meta Facebook ORGANIC case. */
export function metaFacebookOrganicScopesOk(
  granted: unknown,
): { ok: boolean; missing: string[] } {
  return scopeSubsetOk(META_FACEBOOK_ORGANIC_REQUIRED_SCOPES, granted);
}

/** The scope string we send on the authorize URL (required ∪ optional). */
export function metaFacebookOrganicRequestedScopeParam(): string {
  return [
    ...META_FACEBOOK_ORGANIC_REQUIRED_SCOPES,
    ...META_FACEBOOK_ORGANIC_OPTIONAL_SCOPES,
  ].join(",");
}
