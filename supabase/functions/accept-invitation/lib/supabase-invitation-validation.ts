// ============================================================================
// Pulse — Tasks 2–3 · Supabase Invitation-Validation RPC Adapter (U9A)
// ----------------------------------------------------------------------------
// The concrete production implementation of U4's `InvitationLookupPort`. It
// bridges U4's read-only validation orchestration to EXACTLY ONE injected atomic
// database operation — the live read-only RPC `public.validate_invitation`
// (MIG-010, version 20260802161629, CLOSED). It performs ONE RPC call and decodes
// the response defensively into U4's existing `InvitationLookupResult`.
//
// This module performs NO second lookup, NO table read/write, NO hashing (U2/U4
// already derived the hash), NO transport, NO authentication, NO environment
// access, NO client construction, NO origin policy, NO logging, and NO retries.
// It reuses U4's `InvitationLookupPort` / `InvitationLookupResult` / `FoundInvitation`
// and the U1 branded types; it defines NO new domain contract and emits NO extra
// RPC field to U4.
//
// TOKEN-HASH BOUNDARY: the argument is U4's already-derived `TokenHash`. It is
// passed once, unchanged, as the sole RPC parameter `p_token_hash`; it is never
// re-derived, trimmed, normalized, logged, or returned. The raw invitation token
// never reaches this module.
//
// RESULT BOUNDARY (grounded in the frozen MIG-010 T23-D35 contract): the RPC
// returns only { result: "not_found" } or { result: "found", invitation_id,
// application_ref, effective_status }. MIG-010 raises a fixed internal exception
// on impossible duplicate cardinality — surfaced here as an RPC error and mapped,
// like every other fault, to U4's `failed`. There is NO ordinary "ambiguous" RPC
// result, so this production adapter never emits U4's `ambiguous` variant (which
// remains in U4 for possible alternate implementations and is left unchanged).
// Unknown, malformed, or fail-closed responses map to `failed`; no provider
// detail crosses the U4 boundary.
// ============================================================================

import { InvitationStatus } from "./domain-contracts.ts";
import type {
  ApplicationRef,
  InvitationId,
  ObservedApplicationRef,
  TokenHash,
} from "./domain-contracts.ts";
import type {
  FoundInvitation,
  InvitationLookupPort,
  InvitationLookupResult,
} from "./invitation-validation.ts";

// ── Injected RPC contract (MIG-010) ─────────────────────────────────────────

/** The MIG-010 read-only validation RPC name. */
const VALIDATE_INVITATION_RPC = "validate_invitation";

/**
 * The exact RPC parameters. Only the already-derived token hash crosses this
 * boundary — never the raw token, and never any caller email, id, or state.
 */
export interface InvitationValidationRpcParams {
  readonly p_token_hash: string;
}

/** The minimal `{ data, error }` RPC response; `data` is decoded defensively. */
export interface InvitationValidationRpcResponse {
  readonly data: unknown;
  readonly error: unknown;
}

/**
 * The smallest injected client slice: exactly one RPC method. No table-query API,
 * no authentication API, no SDK types, no environment. Production composition (a
 * later U9 unit) adapts the real service-role client to this interface.
 */
export interface InvitationValidationRpcClient {
  rpc(
    functionName: string,
    parameters: InvitationValidationRpcParams,
  ): Promise<InvitationValidationRpcResponse>;
}

// ── Defensive decoding helpers ──────────────────────────────────────────────

/** True only for a non-null, non-array plain object. */
function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Canonical lowercase hyphenated UUID (the form PostgreSQL emits). No braces, no
 * surrounding whitespace, no prefix/suffix, no uppercase, non-empty.
 */
const CANONICAL_UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** True only if `value` is a canonical UUID string. */
function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" && CANONICAL_UUID_PATTERN.test(value);
}

/** True only if `value` is one of the frozen U1 invitation lifecycle statuses. */
function isInvitationStatus(value: unknown): value is InvitationStatus {
  return (
    typeof value === "string" &&
    Object.values(InvitationStatus).some((allowed) => allowed === value)
  );
}

const LOOKUP_FAILED: InvitationLookupResult = { status: "failed" };
const LOOKUP_NOT_FOUND: InvitationLookupResult = { status: "not_found" };

/**
 * Decode the RPC `data` into an `InvitationLookupResult`, failing closed. Only the
 * two frozen MIG-010 success shapes are accepted; every other value — null,
 * primitive, array, unknown discriminant, missing/typed-wrong field, malformed
 * UUID, or unknown lifecycle status — maps to `failed`. No RPC field other than
 * the validated projection reaches U4, and the branded U1 types are constructed
 * only after validation.
 */
function decodeLookupResult(data: unknown): InvitationLookupResult {
  if (!isPlainRecord(data)) {
    return LOOKUP_FAILED;
  }
  const result = data.result;
  if (result === "not_found") {
    return LOOKUP_NOT_FOUND;
  }
  if (result !== "found") {
    return LOOKUP_FAILED;
  }

  const invitationId = data.invitation_id;
  const applicationRef = data.application_ref;
  const effectiveStatus = data.effective_status;

  if (!isCanonicalUuid(invitationId)) {
    return LOOKUP_FAILED;
  }
  if (applicationRef !== null && !isCanonicalUuid(applicationRef)) {
    return LOOKUP_FAILED;
  }
  if (!isInvitationStatus(effectiveStatus)) {
    return LOOKUP_FAILED;
  }

  // Construct the branded U1 values only at this validated boundary. The observed
  // application reference is preserved exactly (a canonical UUID or null); U4 owns
  // the null-application-ref lifecycle classification.
  const observedApplicationRef: ObservedApplicationRef =
    applicationRef === null ? null : (applicationRef as ApplicationRef);

  const invitation: FoundInvitation = {
    invitationId: invitationId as InvitationId,
    applicationRef: observedApplicationRef,
    lifecycleStatus: effectiveStatus,
  };
  return { status: "found", invitation };
}

// ── Adapter factory ─────────────────────────────────────────────────────────

/**
 * Create the concrete `InvitationLookupPort` backed by one injected RPC. Per
 * invocation it performs EXACTLY ONE `validate_invitation` RPC call with only the
 * U4-supplied `TokenHash` and decodes the result fail-closed. A rejected RPC
 * promise or a non-null RPC error maps to `failed` with no provider detail. No
 * retries; the token hash is neither logged nor returned; input is not mutated.
 */
export function createSupabaseInvitationLookupPort(
  client: InvitationValidationRpcClient,
): InvitationLookupPort {
  return {
    lookupByTokenHash: async (tokenHash: TokenHash): Promise<InvitationLookupResult> => {
      let response: InvitationValidationRpcResponse;
      try {
        response = await client.rpc(VALIDATE_INVITATION_RPC, { p_token_hash: tokenHash });
      } catch {
        return LOOKUP_FAILED;
      }

      if (response.error != null) {
        return LOOKUP_FAILED;
      }
      return decodeLookupResult(response.data);
    },
  };
}
