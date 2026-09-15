// ============================================================================
// Pulse — Tasks 2–3 · Supabase Atomic Invitation Acceptance Adapter (U8)
// ----------------------------------------------------------------------------
// The concrete persistence-side adapter for U7's `AtomicInvitationAcceptancePort`.
// It bridges the domain orchestrator to EXACTLY ONE injected atomic database
// operation (a single RPC representing the future MIG-009 function). Atomicity —
// final revalidation, invitation consumption, member + discovery_state creation,
// idempotency, and integrity enforcement — belongs to that one database function,
// NOT to this TypeScript adapter.
//
// This module performs NO multi-step transaction, NO table SELECT/INSERT/UPDATE/
// UPSERT/DELETE, NO second persistence operation, NO client-side rollback, NO
// retries, NO HTTP/Edge/Deno, NO auth/getUser, NO environment access, NO
// service-role secret construction, and NO top-level client creation. It reuses
// U2 as the sole hashing authority and returns only the U5 `AcceptanceOutcome`.
//
// TOKEN HANDLING (grounded in committed architecture, not invented): Round-2 D04
// makes the SHA-256 hash the canonical stored/lookup representation and forbids
// persisting the raw token; U2 is the committed hashing authority; U4 already
// hashes-then-looks-up. Therefore U8 derives the hash via U2 ONCE and passes only
// the hash to the RPC — the raw token never enters the database/statement logs and
// is never logged or returned here.
//
// STRUCTURAL RPC CONTRACT (proposed, must be satisfied by the future MIG-009): the
// function name and parameter/result shapes below are the TypeScript-side contract
// MIG-009 will implement. They are structural, not a resolution of any open
// founder decision. U8 resolves NO policy: D05 identity/email matching, D07, D08-a,
// D11 remediation, and D12 are owned by the atomic function / founder register; U8
// forwards trusted facts (auth user id + verified-email fact) and decodes the
// function's authoritative result.
// ============================================================================

import { InvitationValidationFailure, IntegrityStateFailure } from "./domain-contracts.ts";
import { hashInvitationToken } from "./token-crypto.ts";
import type { AcceptanceOutcome } from "./invitation-acceptance-contract.ts";
import type {
  AtomicInvitationAcceptanceInput,
  AtomicInvitationAcceptancePort,
} from "./invitation-acceptance-orchestrator.ts";

// ── Proposed RPC contract (future MIG-009) ──────────────────────────────────

/** The proposed atomic acceptance RPC name (MIG-009 must implement this). */
const ATOMIC_ACCEPTANCE_RPC = "accept_invitation";

/**
 * The exact RPC parameters. Only trusted, server-derived persistence data crosses
 * this boundary: the SHA-256 token hash (never the raw token), the authenticated
 * auth-user id, and the trusted email-verification fact. No caller email, ids,
 * roles, session, or provider data.
 */
export interface AtomicAcceptanceRpcParams {
  readonly p_token_hash: string;
  readonly p_auth_user_id: string;
  readonly p_email_verified: boolean;
}

/** The minimal `{ data, error }` RPC response; `data` is decoded defensively. */
export interface AtomicAcceptanceRpcResponse {
  readonly data: unknown;
  readonly error: unknown;
}

/**
 * The smallest injected client slice: exactly one RPC method. No table-query API,
 * no auth API, no SDK types, no environment. Production composition adapts the
 * real Supabase client to this interface.
 */
export interface AtomicAcceptanceRpcClient {
  rpc(
    functionName: string,
    parameters: AtomicAcceptanceRpcParams,
  ): Promise<AtomicAcceptanceRpcResponse>;
}

// ── Defensive decoding helpers ──────────────────────────────────────────────

/** True only for a non-null, non-array plain object. */
function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** True only if `value` is one of the frozen U1 invitation-validation reasons. */
function isInvitationValidationFailure(value: string): value is InvitationValidationFailure {
  return Object.values(InvitationValidationFailure).some((allowed) => allowed === value);
}

/** True only if `value` is one of the frozen U1 integrity-state reasons. */
function isIntegrityStateFailure(value: string): value is IntegrityStateFailure {
  return Object.values(IntegrityStateFailure).some((allowed) => allowed === value);
}

const INFRASTRUCTURE_FAILURE: AcceptanceOutcome = { kind: "infrastructure_failure" };

/**
 * Decode the RPC `data` into an `AcceptanceOutcome`, failing closed. Unknown,
 * malformed, null, ambiguous, or unsupported responses — and any reason string
 * not in the frozen U1 sets — map to `infrastructure_failure`. Arbitrary database
 * strings can never become a domain conflict/validation reason.
 */
function decodeAcceptanceResult(data: unknown): AcceptanceOutcome {
  if (!isPlainRecord(data)) {
    return INFRASTRUCTURE_FAILURE;
  }
  const status = data.status;
  if (typeof status !== "string") {
    return INFRASTRUCTURE_FAILURE;
  }
  switch (status) {
    case "accepted": {
      const provisioning = data.provisioning;
      if (provisioning === "provisioned") {
        return { kind: "provisioned", outcome: "provisioned" };
      }
      if (provisioning === "already_provisioned") {
        return { kind: "provisioned", outcome: "already_provisioned" };
      }
      return INFRASTRUCTURE_FAILURE;
    }
    case "invalid_invitation": {
      const reason = data.reason;
      if (typeof reason === "string" && isInvitationValidationFailure(reason)) {
        return { kind: "invalid_invitation", reason };
      }
      return INFRASTRUCTURE_FAILURE;
    }
    case "integrity_conflict": {
      const reason = data.reason;
      if (typeof reason === "string" && isIntegrityStateFailure(reason)) {
        return { kind: "integrity_conflict", reason };
      }
      return INFRASTRUCTURE_FAILURE;
    }
    case "authentication_failed":
      return { kind: "authentication_failed" };
    default:
      return INFRASTRUCTURE_FAILURE;
  }
}

// ── Adapter factory ─────────────────────────────────────────────────────────

/**
 * Create the concrete `AtomicInvitationAcceptancePort` backed by one injected RPC.
 * Per invocation it derives the token hash via U2 (once), performs EXACTLY ONE RPC
 * call, and decodes the result fail-closed. A rejected RPC promise or a non-null
 * RPC error maps to `infrastructure_failure` with no provider detail. No retries.
 * Neither the raw token, the hash, provider errors, nor any input is logged.
 */
export function createSupabaseAtomicInvitationAcceptancePort(
  client: AtomicAcceptanceRpcClient,
): AtomicInvitationAcceptancePort {
  return {
    accept: async (input: AtomicInvitationAcceptanceInput): Promise<AcceptanceOutcome> => {
      const tokenHash = await hashInvitationToken(input.presentedToken);

      let response: AtomicAcceptanceRpcResponse;
      try {
        response = await client.rpc(ATOMIC_ACCEPTANCE_RPC, {
          p_token_hash: tokenHash,
          p_auth_user_id: input.auth.authUserId,
          p_email_verified: input.auth.emailVerified,
        });
      } catch {
        return INFRASTRUCTURE_FAILURE;
      }

      if (response.error != null) {
        return INFRASTRUCTURE_FAILURE;
      }
      return decodeAcceptanceResult(response.data);
    },
  };
}
