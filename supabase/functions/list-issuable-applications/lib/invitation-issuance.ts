// ============================================================================
// Pulse — Tasks 2–3 · Trusted Invitation Issuance Orchestration (U3)
// ----------------------------------------------------------------------------
// INTERNAL trusted-server orchestration for invitation issuance. It sits behind
// a future trusted server endpoint (U4) but is itself TRANSPORT-INDEPENDENT: it
// coordinates authorization, secure token generation/hashing (U2), and a future
// atomic persistence operation, then maps the result so a raw token can never be
// read on an unsuccessful outcome.
//
// This module performs NO transport, NO SQL, NO migrations, NO PostgreSQL/RPC
// wiring, NO Supabase/database/HTTP/fetch, NO Edge Function, NO email/n8n, NO
// invitation validation/acceptance/provisioning, NO expiry policy, and NO
// environment/config loading. All external effects are reached only through
// injected internal ports.
//
// Authority: Round-2 D03 (gated server-side issuance), D04 (token/hash, via U2),
// D08 (atomic issuance/reissue, non-null application_ref), D10-C (atomicity owned
// by the future PostgreSQL function). Lifecycle outcome vocabulary is the frozen
// U1 `IssuanceOutcome`; identifiers/hash are the frozen U1 brands.
//
// SECURITY INVARIANTS (preserved and documented):
//   * Authorization precedes token generation; an unauthorized request never
//     generates a token and never calls persistence.
//   * Raw tokens are generated only by U2; the raw token never crosses the
//     persistence boundary — only its hash is eligible for storage.
//   * Successful persistence is required before the raw token is returned for
//     one-time delivery; rejected/failed issuance never leaks a generated token.
//   * No token or hash is logged or attached to a failure result/error.
//   * Atomicity and concurrency-sensitive, application-scoped uniqueness are
//     delegated to the persistence port's future PostgreSQL implementation; this
//     TypeScript orchestration performs NO read-then-write duplicate checks and
//     does NOT itself guarantee database atomicity.
//   * D08-a (cross-application same-email policy) and reissue lifecycle policy are
//     NOT resolved here; issuance/reissue outcomes come from the persistence port.
// ============================================================================

import type {
  ApplicationRef,
  InvitationId,
  IssuanceOutcome,
  TokenHash,
} from "./domain-contracts.ts";
import {
  generateInvitationToken,
  hashInvitationToken,
  type InvitationToken,
} from "./token-crypto.ts";

// ── Internal references ─────────────────────────────────────────────────────

declare const __actorBrand: unique symbol;

/**
 * An opaque, server-resolved reference to the trusted actor authorizing issuance
 * (e.g. an authenticated operator identity resolved server-side). It is NOT a
 * user-controlled field and carries no client-supplied claims; its concrete shape
 * is defined by the trusted server that constructs it.
 */
export type TrustedActorRef = string & { readonly [__actorBrand]: "TrustedActorRef" };

// ── Internal issuance command ───────────────────────────────────────────────

/**
 * The minimal internal facts required to request application-scoped issuance.
 * `applicationRef` is the non-null lifecycle identity (U1 D08); `actor` is the
 * trusted actor reference used for authorization. No arbitrary user-controlled
 * fields, no transport concerns, no public DTO.
 */
export interface InvitationIssuanceCommand {
  readonly applicationRef: ApplicationRef;
  readonly actor: TrustedActorRef;
}

// ── Injected ports ──────────────────────────────────────────────────────────

/**
 * Authorization port: decides whether the trusted actor may issue for the given
 * application. Must not rely on frontend claims alone. Implementation is provided
 * by a later unit; U3 only consumes the decision.
 */
export interface IssuanceAuthorizationPort {
  authorize(command: InvitationIssuanceCommand): Promise<boolean>;
}

/**
 * The server-derived values sent to the atomic persistence operation. Carries the
 * token HASH only — never the raw token. No timestamps are supplied: `issued_at`
 * and the expiry relationship are owned by the database (D08/D10-C), keeping them
 * atomic and server-authoritative.
 */
export interface IssuancePersistenceInput {
  readonly applicationRef: ApplicationRef;
  readonly tokenHash: TokenHash;
  readonly actor: TrustedActorRef;
}

/**
 * The internal result of the future atomic PostgreSQL issuance operation.
 *   * `issued`   — atomic issuance/reissue committed; `outcome` is the U1 lifecycle
 *                  outcome (Issued | Reissued) decided by the database.
 *   * `rejected` — the database atomically rejected the request (e.g. an
 *                  application-scoped/concurrency conflict). The specific reason is
 *                  intentionally abstract here — U3 does not enumerate or decide it.
 *   * `failed`   — the operation could not complete (operational error).
 */
export type IssuancePersistenceResult =
  | {
      readonly status: "issued";
      readonly outcome: IssuanceOutcome;
      readonly invitationId: InvitationId;
    }
  | { readonly status: "rejected" }
  | { readonly status: "failed" };

/**
 * Atomic issuance persistence port. Owns all concurrency-sensitive, application-
 * scoped uniqueness enforcement and atomicity in its future PostgreSQL
 * implementation. U3 calls it exactly once per authorized issuance.
 */
export interface AtomicIssuancePersistencePort {
  issue(input: IssuancePersistenceInput): Promise<IssuancePersistenceResult>;
}

/** The injected dependencies required by the issuance orchestration. */
export interface InvitationIssuancePorts {
  readonly authorization: IssuanceAuthorizationPort;
  readonly persistence: AtomicIssuancePersistencePort;
}

// ── Orchestration result ────────────────────────────────────────────────────

/**
 * Orchestration-level failure categories (control flow, NOT lifecycle policy).
 * `PersistenceRejected` abstracts any database-decided rejection; the concrete
 * reason is owned by the persistence port and not enumerated here.
 */
export const IssuanceFailure = {
  Unauthorized: "unauthorized",
  PersistenceRejected: "persistence_rejected",
  PersistenceFailed: "persistence_failed",
} as const;

export type IssuanceFailure = (typeof IssuanceFailure)[keyof typeof IssuanceFailure];

/**
 * The orchestration result. Discriminated on `ok` so the raw `token` is reachable
 * ONLY on success; unsuccessful results carry neither the raw token nor its hash.
 */
export type InvitationIssuanceResult =
  | {
      readonly ok: true;
      readonly outcome: IssuanceOutcome;
      readonly invitationId: InvitationId;
      readonly token: InvitationToken;
    }
  | { readonly ok: false; readonly failure: IssuanceFailure };

// ── Orchestration ───────────────────────────────────────────────────────────

/**
 * Orchestrate a single application-scoped invitation issuance. Order (fixed):
 *   1. Authorize the trusted actor (no token is generated before this succeeds).
 *   2. On denial, return `Unauthorized` without generating a token or persisting.
 *   3. Generate one secure raw token (U2) and hash it (U2).
 *   4. Send only the hash to the persistence port (called exactly once).
 *   5. Return the raw token only when persistence reports a successful issuance;
 *      otherwise return a failure with no token/hash.
 * The raw token exists only transiently in this call. Persistence errors are
 * mapped to `PersistenceFailed` without exposing the underlying error, the token,
 * or the hash. No retry is performed (no retry policy is frozen).
 */
export async function orchestrateInvitationIssuance(
  command: InvitationIssuanceCommand,
  ports: InvitationIssuancePorts,
): Promise<InvitationIssuanceResult> {
  const authorized = await ports.authorization.authorize(command);
  if (!authorized) {
    return { ok: false, failure: IssuanceFailure.Unauthorized };
  }

  const token = generateInvitationToken();
  const tokenHash = await hashInvitationToken(token);

  let result: IssuancePersistenceResult;
  try {
    result = await ports.persistence.issue({
      applicationRef: command.applicationRef,
      tokenHash,
      actor: command.actor,
    });
  } catch {
    // Fail closed: never surface the raw token, hash, or the underlying error.
    return { ok: false, failure: IssuanceFailure.PersistenceFailed };
  }

  if (result.status === "issued") {
    return { ok: true, outcome: result.outcome, invitationId: result.invitationId, token };
  }
  if (result.status === "rejected") {
    return { ok: false, failure: IssuanceFailure.PersistenceRejected };
  }
  return { ok: false, failure: IssuanceFailure.PersistenceFailed };
}
