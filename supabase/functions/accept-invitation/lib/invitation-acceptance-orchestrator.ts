// ============================================================================
// Pulse — Tasks 2–3 · Invitation Acceptance Orchestrator (U7)
// ----------------------------------------------------------------------------
// The domain orchestration for invitation acceptance. It coordinates existing
// components through injected ports and performs NO persistence itself:
//
//   InvitationAcceptanceCommand (U5)
//         -> validation port (U4 contracts) : read-only fast-fail
//         -> [no additional D05 policy resolved here]
//         -> atomic acceptance port (future U8) : called at most once
//         -> AcceptanceOutcome (U5)
//
// This module contains NO SQL, NO migrations, NO Supabase, NO Edge Function, NO
// token hashing, NO invitation-lookup implementation, NO provisioning
// implementation, NO database transaction, NO HTTP/Request/Response, NO
// authentication, NO Deno. All effects are reached only through injected ports;
// no top-level side effects.
//
// Reuse: U5 `InvitationAcceptanceCommand`/`AcceptanceOutcome`/`AcceptanceAuthContext`;
// U4 `InvitationValidationCommand`/`InvitationValidationResult` (the validation
// port's production implementation wraps U4 `validateInvitationToken` with the
// real lookup); U1 `InvitationValidationFailure`. Validation, transport parsing,
// response mapping, authentication, and crypto are NOT reimplemented here.
//
// BUSINESS-POLICY BOUNDARY: on a valid invitation U7 applies no additional policy
// before delegating. Identity-matching (D05) is OPEN and is owned by the atomic
// operation / founder register; provisioning semantics (D06/D02) are owned by the
// atomic port. U7 does NOT resolve D05, D07, D08-a, D11, or D12.
//
// SECURITY INVARIANTS: the atomic port is invoked at most once and only after a
// `valid` validation; it is never invoked after a failed validation; there are no
// retries; the returned `AcceptanceOutcome` never carries the raw token or a hash;
// atomic exceptions fail closed to `infrastructure_failure` without exposing detail.
// The DB atomic operation remains the independent final authority (U4's read-only
// result is a fast-fail classification, not trusted as the final decision).
// ============================================================================

import { InvitationValidationFailure } from "./domain-contracts.ts";
import type {
  InvitationValidationCommand,
  InvitationValidationResult,
} from "./invitation-validation.ts";
import type {
  AcceptanceAuthContext,
  AcceptanceOutcome,
  InvitationAcceptanceCommand,
} from "./invitation-acceptance-contract.ts";

// ── Injected ports ──────────────────────────────────────────────────────────

/**
 * Read-only invitation validation port (U4 contracts). Its production
 * implementation wraps U4 `validateInvitationToken` with the real lookup; U7
 * consumes only the result and never performs validation itself.
 */
export interface InvitationValidationPort {
  validate(command: InvitationValidationCommand): Promise<InvitationValidationResult>;
}

/** Input to the atomic acceptance operation (future U8). */
export interface AtomicInvitationAcceptanceInput {
  readonly presentedToken: string;
  readonly auth: AcceptanceAuthContext;
}

/**
 * The future-U8 atomic acceptance port. Its PostgreSQL implementation
 * independently revalidates, consumes the invitation, and provisions the member +
 * discovery_state in one transaction, returning an `AcceptanceOutcome`. U7 does
 * not implement it and calls it at most once.
 */
export interface AtomicInvitationAcceptancePort {
  accept(input: AtomicInvitationAcceptanceInput): Promise<AcceptanceOutcome>;
}

/** The injected dependencies required by the acceptance orchestration. */
export interface InvitationAcceptancePorts {
  readonly validation: InvitationValidationPort;
  readonly atomic: AtomicInvitationAcceptancePort;
}

// ── Validation-result mapping (pre-atomic fast-fail) ────────────────────────

/**
 * Map a non-`valid` U4 validation result to a U5 `AcceptanceOutcome`. Returns null
 * for `valid` (the orchestration proceeds to the atomic port).
 *   * invalid(reason) -> invalid_invitation(reason)
 *   * malformed       -> invalid_invitation(NotFound): a structurally-invalid token
 *                        corresponds to no acceptable invitation (collapses to the
 *                        non-enumerating external code).
 *   * ambiguous       -> infrastructure_failure: a fail-closed server-side data
 *                        integrity fault (e.g. >1 row for a UNIQUE token_hash);
 *                        does not reveal invitation existence.
 *   * lookup_failed   -> infrastructure_failure.
 */
function mapNonValidResult(result: InvitationValidationResult): AcceptanceOutcome | null {
  switch (result.outcome) {
    case "valid":
      return null;
    case "invalid":
      return { kind: "invalid_invitation", reason: result.reason };
    case "malformed":
      return { kind: "invalid_invitation", reason: InvitationValidationFailure.NotFound };
    case "ambiguous":
      return { kind: "infrastructure_failure" };
    case "lookup_failed":
      return { kind: "infrastructure_failure" };
  }
}

// ── Orchestration ───────────────────────────────────────────────────────────

/**
 * Orchestrate a single invitation acceptance. Order (fixed):
 *   1. Validate the presented token via the validation port (U4).
 *   2. Stop immediately on any non-`valid` result, mapping to an outcome without
 *      calling the atomic port.
 *   3. On `valid`, apply no additional business policy (D05 is OPEN) and call the
 *      atomic acceptance port exactly once.
 *   4. Return the atomic outcome; a thrown atomic error fails closed to
 *      `infrastructure_failure`. No retries.
 */
export async function orchestrateInvitationAcceptance(
  command: InvitationAcceptanceCommand,
  ports: InvitationAcceptancePorts,
): Promise<AcceptanceOutcome> {
  const validation = await ports.validation.validate({ presentedToken: command.presentedToken });

  const nonValid = mapNonValidResult(validation);
  if (nonValid !== null) {
    return nonValid;
  }

  try {
    return await ports.atomic.accept({
      presentedToken: command.presentedToken,
      auth: command.auth,
    });
  } catch {
    // Fail closed: never surface the raw token, hash, or the underlying error.
    return { kind: "infrastructure_failure" };
  }
}
