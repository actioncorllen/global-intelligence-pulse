// ============================================================================
// Pulse — Tasks 2–3 · Transport-Independent Invitation Validation (U4)
// ----------------------------------------------------------------------------
// INTERNAL, transport-independent, READ-ONLY assessment of a presented invitation
// token before any acceptance attempt. It coordinates structural token validation,
// SHA-256 hashing (U2), a single injected read-only lookup, and canonical mapping
// of invitation state to an internal validation result.
//
// This module performs NO transport, NO HTTP/Edge/fetch, NO SQL/migrations/RPC,
// NO Supabase/database code, NO acceptance/consumption/provisioning, NO mutation,
// NO email/n8n, and NO environment/config loading. All external effects are
// reached only through the injected lookup port. Validation NEVER mutates
// invitation state and NEVER consumes or reserves an invitation.
//
// Authority: MIG-002 invitation schema (token_hash UNIQUE; status ∈ issued |
// consumed | expired | revoked; nullable application_ref), Round-2 D04 (token/
// hash via U2) and D08 (non-null application_ref lifecycle identity; expiry
// determined server-side from expires_at, never a client clock). Lifecycle and
// failure vocabulary are the frozen U1 authorities.
//
// TIME BOUNDARY (decision): NO clock port. Per D08 the database is the expiry
// authority; the future DB-backed lookup evaluates `now() > expires_at`
// server-side and returns an ALREADY-CLASSIFIED effective lifecycle state. This
// is the smallest boundary consistent with the architecture and avoids trusting
// any client clock inside this orchestration.
//
// SECURITY INVARIANTS (preserved and documented):
//   * Malformed tokens are rejected BEFORE hashing and never reach the lookup.
//   * The raw token never crosses the lookup boundary; only its hash does.
//   * U2 is the sole hashing authority; no second token representation is created.
//   * The token hash is never returned to the caller and never logged.
//   * Validation is read-only; ambiguous/inconsistent data FAILS CLOSED.
//   * Lookup failures are mapped internally and never expose infrastructure detail.
//   * A `valid` result does NOT authorize provisioning — acceptance (a later unit
//     and the future atomic PostgreSQL operation) must re-establish guarantees.
//   * This TypeScript validation makes no claim of database atomicity.
// ============================================================================

import type {
  InvitationId,
  InvitationStatus,
  ObservedApplicationRef,
  TokenHash,
} from "./domain-contracts.ts";
import { InvitationValidationFailure } from "./domain-contracts.ts";
import { hashInvitationToken, type InvitationToken } from "./token-crypto.ts";

// ── Presented-token command (untrusted input) ──────────────────────────────

/**
 * The internal validation command. `presentedToken` originates from an UNTRUSTED
 * caller and is a plain string — it is not treated as a canonical U2
 * `InvitationToken` until it passes the frozen structural check.
 */
export interface InvitationValidationCommand {
  readonly presentedToken: string;
}

// ── Structural token validation ─────────────────────────────────────────────

/**
 * Frozen structural shape of a U2 token: exactly 43 characters drawn only from
 * the URL-safe base64 alphabet (A-Z a-z 0-9 `-` `_`) — no padding, no whitespace,
 * non-empty. (43 chars is the unpadded base64url length of 32 random bytes.)
 */
const CANONICAL_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/**
 * Returns true only if `value` is structurally a canonical invitation token. No
 * trimming, lowercasing, padding repair, or alternate encoding is performed:
 * malformed input fails closed.
 */
function isCanonicalInvitationToken(value: string): boolean {
  return CANONICAL_TOKEN_PATTERN.test(value);
}

// ── Injected read-only lookup port ──────────────────────────────────────────

/**
 * The minimum non-secret facts about a found invitation. `applicationRef` is
 * `ObservedApplicationRef` (may be null) so a null lifecycle linkage can be
 * detected and rejected; `lifecycleStatus` is the effective state with expiry
 * already folded server-side (see TIME BOUNDARY).
 */
export interface FoundInvitation {
  readonly invitationId: InvitationId;
  readonly applicationRef: ObservedApplicationRef;
  readonly lifecycleStatus: InvitationStatus;
}

/**
 * Read-only lookup result. `ambiguous` covers a structural impossibility (more
 * than one row for a UNIQUE token_hash); `failed` covers an infrastructure/read
 * error. Neither carries secrets or infrastructure detail.
 */
export type InvitationLookupResult =
  | { readonly status: "not_found" }
  | { readonly status: "found"; readonly invitation: FoundInvitation }
  | { readonly status: "ambiguous" }
  | { readonly status: "failed" };

/**
 * Injected read-only invitation lookup (future DB-backed). Receives ONLY the
 * canonical token hash — never the raw token, HTTP context, frontend claims,
 * acceptance payload, or member data. Implementation is provided by a later unit.
 */
export interface InvitationLookupPort {
  lookupByTokenHash(tokenHash: TokenHash): Promise<InvitationLookupResult>;
}

/** The injected dependencies required by validation (read-only; no clock). */
export interface InvitationValidationPorts {
  readonly lookup: InvitationLookupPort;
}

// ── Validation result ───────────────────────────────────────────────────────

/**
 * Internal validation result, discriminated on `outcome` so that acceptance
 * context (invitationId/applicationRef) is reachable ONLY on `valid`, and no
 * result ever carries the raw token or its hash.
 *   * `valid`         — status `issued`, applicant-bound (non-null application_ref)
 *                       OR direct/open beta (application_ref IS NULL); carries the
 *                       minimum non-secret context a later acceptance needs.
 *   * `malformed`     — presented token failed the structural check (not hashed).
 *   * `invalid`       — a concrete lifecycle rejection (`InvitationValidationFailure`).
 *   * `ambiguous`     — fail-closed on inconsistent/ambiguous lookup data.
 *   * `lookup_failed` — the read could not complete (no infrastructure detail).
 */
export type InvitationValidationResult =
  | {
      readonly outcome: "valid";
      readonly invitationId: InvitationId;
      readonly applicationRef: ObservedApplicationRef;
    }
  | { readonly outcome: "malformed" }
  | { readonly outcome: "invalid"; readonly reason: InvitationValidationFailure }
  | { readonly outcome: "ambiguous" }
  | { readonly outcome: "lookup_failed" };

// ── Classification of a found invitation ────────────────────────────────────

/** Map a found invitation's effective lifecycle state to a validation result. */
function classifyFoundInvitation(found: FoundInvitation): InvitationValidationResult {
  switch (found.lifecycleStatus) {
    case "consumed":
      return { outcome: "invalid", reason: InvitationValidationFailure.Consumed };
    case "revoked":
      return { outcome: "invalid", reason: InvitationValidationFailure.Revoked };
    case "expired":
      return { outcome: "invalid", reason: InvitationValidationFailure.Expired };
    case "issued": {
      // Both applicant-bound (non-null application_ref) and direct/open beta
      // invitations (application_ref IS NULL — PULSE-BETA-OPEN-INVITE-001 / MIG-029)
      // are acceptable. This read-only classifier does NOT authorize provisioning:
      // the atomic accept_invitation operation remains the sole authority for email
      // binding, confirmed-email, single-use, expiry and successor integrity — for
      // BOTH shapes. Rejecting a null application_ref here made every direct beta
      // invitation permanently unacceptable (PULSE-BETA-INVITE-E2E-006).
      return {
        outcome: "valid",
        invitationId: found.invitationId,
        applicationRef: found.applicationRef,
      };
    }
  }
}

// ── Validation orchestration ────────────────────────────────────────────────

/**
 * Validate a presented invitation token (read-only). Order (fixed):
 *   1. Structural check; if malformed, return `malformed` WITHOUT hashing or
 *      calling the lookup port.
 *   2. Hash the canonical token via U2.
 *   3. Call the lookup port exactly once with the hash.
 *   4. Classify with the frozen U1 lifecycle vocabulary; fail closed on ambiguity.
 * The raw token and its hash are never returned or logged. Lookup exceptions are
 * caught and mapped to `lookup_failed` without exposing any detail. No mutation
 * occurs and no invitation is consumed or reserved.
 */
export async function validateInvitationToken(
  command: InvitationValidationCommand,
  ports: InvitationValidationPorts,
): Promise<InvitationValidationResult> {
  if (!isCanonicalInvitationToken(command.presentedToken)) {
    return { outcome: "malformed" };
  }

  // Structurally canonical: now treat as a U2 token and hash it.
  const canonicalToken = command.presentedToken as InvitationToken;
  const tokenHash = await hashInvitationToken(canonicalToken);

  let result: InvitationLookupResult;
  try {
    result = await ports.lookup.lookupByTokenHash(tokenHash);
  } catch {
    // Fail closed: never surface the token hash or the underlying error.
    return { outcome: "lookup_failed" };
  }

  switch (result.status) {
    case "not_found":
      return { outcome: "invalid", reason: InvitationValidationFailure.NotFound };
    case "found":
      return classifyFoundInvitation(result.invitation);
    case "ambiguous":
      return { outcome: "ambiguous" };
    case "failed":
      return { outcome: "lookup_failed" };
  }
}
