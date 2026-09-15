// ============================================================================
// Pulse — Tasks 2–3 · Invitation Acceptance Transport Contract (U5)
// ----------------------------------------------------------------------------
// PURE boundary module for invitation acceptance. It defines how a future
// Supabase Edge Function (U6) will translate an UNTRUSTED external request into a
// validated internal acceptance command, and an internal acceptance outcome into
// a SANITIZED transport response. It contains only type contracts and pure
// parsing/mapping functions.
//
// This module performs NO transport, NO HTTP/Request/Response, NO Edge/Supabase/
// database/RPC/SQL, NO auth verification, NO session/cookie/JWT handling, NO
// invitation validation lookup (U4), NO consumption/provisioning (U7/U8/MIG-009),
// NO mutation, NO email/n8n, NO environment loading, and NO logging. No top-level
// side effects; no runtime/platform dependency.
//
// Authority reused: U1 `TrustedAuthIdentityFacts`, `InvitationValidationFailure`,
// `IntegrityStateFailure`, `ProvisioningOutcome`. Structural token validation and
// lifecycle classification remain owned by U4; hashing remains owned by U2.
//
// SECURITY INVARIANTS (documented and preserved):
//   * Request bodies are UNTRUSTED; body-supplied auth identity is NEVER
//     authoritative. Trusted authentication facts are supplied separately by U6.
//   * The invitation token stays an untrusted, unbranded, un-hashed string until
//     U4 validates it. No token or token hash ever appears in any contract here.
//   * Invitation/application identifiers are NOT trusted from the caller; the body
//     accepts only the token — server-owned and lifecycle fields are rejected.
//   * Parser failures never echo caller values; response mapping never leaks
//     infrastructure detail. Successful parsing does NOT mean the invitation is
//     valid, and successful mapping does NOT itself provision or authenticate.
//
// OPEN DECISIONS (not resolved here): D05 identity-matching, D07 auth/session
// transition, D08-a cross-application policy, D11 remediation, D12 recovery.
// Where a transport outcome must represent an unresolved condition it uses a
// generic category; policy resolution belongs to U7/U8 or the founder register.
// ============================================================================

import type {
  IntegrityStateFailure,
  InvitationValidationFailure,
  ProvisioningOutcome,
  TrustedAuthIdentityFacts,
} from "./domain-contracts.ts";

// ── A. Untrusted external request ───────────────────────────────────────────
// The narrowest acceptance body: ONLY the presented token. No caller-supplied
// identity, ids, or profile fields are accepted (U1 approves no member-editable
// acceptance-body field; D06 profile facts are sourced server-side, and later
// member-field editability remains deferred).

/**
 * The normalized internal transport command produced by a successful parse. The
 * token is an ordinary UNTRUSTED string — not branded as a U2 `InvitationToken`,
 * not hashed, not lifecycle-validated (all of which U4 owns downstream).
 */
export interface AcceptanceRequest {
  readonly token: string;
}

/** Stable internal parser-failure categories (no caller values, no prose model). */
export const AcceptanceRequestFailure = {
  InvalidBody: "invalid_body",
  MissingToken: "missing_token",
  InvalidTokenType: "invalid_token_type",
  EmptyToken: "empty_token",
  UnexpectedField: "unexpected_field",
} as const;

export type AcceptanceRequestFailure =
  (typeof AcceptanceRequestFailure)[keyof typeof AcceptanceRequestFailure];

/** Discriminated parse result: a partially-valid command can never be a success. */
export type AcceptanceRequestParseResult =
  | { readonly ok: true; readonly request: AcceptanceRequest }
  | { readonly ok: false; readonly failure: AcceptanceRequestFailure };

// ── B. Pure parser (unknown -> parse result) ────────────────────────────────

/** True only for a non-null, non-array plain object. */
function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Parse an UNKNOWN external body into a normalized acceptance request. Fails
 * closed with a stable category and never throws. Accepts only a `token` string:
 * any additional field (e.g. a body-supplied `userId`, `role`, `applicationId`,
 * `invitationId`, or server-owned state) is rejected as `UnexpectedField`. The
 * token is neither trimmed, normalized, branded, nor hashed here.
 */
export function parseAcceptanceRequest(input: unknown): AcceptanceRequestParseResult {
  if (!isPlainRecord(input)) {
    return { ok: false, failure: AcceptanceRequestFailure.InvalidBody };
  }
  if (!("token" in input)) {
    return { ok: false, failure: AcceptanceRequestFailure.MissingToken };
  }
  const token = input.token;
  if (typeof token !== "string") {
    return { ok: false, failure: AcceptanceRequestFailure.InvalidTokenType };
  }
  if (token.length === 0) {
    return { ok: false, failure: AcceptanceRequestFailure.EmptyToken };
  }
  const hasUnexpectedField = Object.keys(input).some((key) => key !== "token");
  if (hasUnexpectedField) {
    return { ok: false, failure: AcceptanceRequestFailure.UnexpectedField };
  }
  return { ok: true, request: { token } };
}

// ── C. Trusted auth context + internal acceptance command ───────────────────

/**
 * The trusted authenticated identity for acceptance. Reuses U1
 * `TrustedAuthIdentityFacts` (authUserId + emailVerified). This context MUST be
 * constructed by the future U6 Edge Function ONLY after it verifies the
 * authenticated user through the trusted Supabase auth boundary — never from the
 * request body. It intentionally excludes bearer tokens, Authorization headers,
 * service-role keys, JWTs, refresh tokens, cookies, and arbitrary claims.
 */
export type AcceptanceAuthContext = TrustedAuthIdentityFacts;

/**
 * The command U6 passes to U7 after (1) parsing the untrusted body and (2)
 * obtaining trusted auth facts from the platform boundary. Provenance is explicit:
 * `presentedToken` is untrusted caller input; `auth` is trusted server-derived
 * identity. It carries NO token hash, invitation id, or application ref — those
 * are derived/re-established via validation (U4) and atomic acceptance (U7/U8).
 * Identity-matching policy (D05) is not resolved here.
 */
export interface InvitationAcceptanceCommand {
  readonly presentedToken: string;
  readonly auth: AcceptanceAuthContext;
}

// ── D. Internal acceptance outcome (mapper input) ───────────────────────────
// A minimal transport-boundary INPUT union for the response mapper. It is NOT the
// definitive U7 domain result (U7 owns that); it exists so U5 can sanitize
// outcomes without resolving policy. It reuses U1 authorities where they apply.

/** The two U1 provisioning success outcomes eligible for an `accepted` response. */
export type AcceptanceSuccessOutcome =
  | typeof ProvisioningOutcome.Provisioned
  | typeof ProvisioningOutcome.AlreadyProvisioned;

/**
 * Transport-boundary acceptance outcome (mapper input). Distinct internal cases
 * are retained here; the public mapper may collapse some of them (see below).
 */
export type AcceptanceOutcome =
  | { readonly kind: "provisioned"; readonly outcome: AcceptanceSuccessOutcome }
  | { readonly kind: "invalid_invitation"; readonly reason: InvitationValidationFailure }
  | { readonly kind: "integrity_conflict"; readonly reason: IntegrityStateFailure }
  | { readonly kind: "authentication_failed" }
  | { readonly kind: "infrastructure_failure" };

// ── E. Sanitized transport response + response mapper ───────────────────────

/**
 * Stable machine-readable response codes for U6 to serialize. No HTTP status is
 * defined here (U6 selects status). `InvitationNotAcceptable` deliberately
 * COLLAPSES all invitation-invalidity and integrity outcomes so external callers
 * cannot enumerate whether an invitation exists or infer internal diagnostics.
 *
 * NOTE (non-authoritative): the public collapsing policy is a CONSERVATIVE
 * default because the enumeration/response policy is not yet frozen. It must be
 * reviewed against U6/U7 and the founder register; richer distinctions remain
 * available internally in `AcceptanceOutcome`.
 */
export const AcceptanceResponseCode = {
  Accepted: "accepted",
  InvitationNotAcceptable: "invitation_not_acceptable",
  AuthenticationRequired: "authentication_required",
  TemporaryFailure: "temporary_failure",
} as const;

export type AcceptanceResponseCode =
  (typeof AcceptanceResponseCode)[keyof typeof AcceptanceResponseCode];

/**
 * The sanitized, transport-neutral response. Carries only a success flag and a
 * stable code — no token, token hash, ids, profile data, SQL/exception detail, or
 * internal integrity diagnostics. U6 serializes this (and may attach a generic
 * non-enumerating message and select an HTTP status).
 */
export interface AcceptanceResponse {
  readonly ok: boolean;
  readonly code: AcceptanceResponseCode;
}

/**
 * Pure, deterministic, exhaustive mapping of an internal acceptance outcome to a
 * sanitized response. Performs no I/O, no logging, no mutation, and leaks no
 * secret or infrastructure detail. Invalid-invitation and integrity outcomes are
 * collapsed to a single non-enumerable code; authentication and infrastructure
 * failures map to their own generic codes.
 */
export function mapAcceptanceOutcome(outcome: AcceptanceOutcome): AcceptanceResponse {
  switch (outcome.kind) {
    case "provisioned":
      return { ok: true, code: AcceptanceResponseCode.Accepted };
    case "invalid_invitation":
    case "integrity_conflict":
      return { ok: false, code: AcceptanceResponseCode.InvitationNotAcceptable };
    case "authentication_failed":
      return { ok: false, code: AcceptanceResponseCode.AuthenticationRequired };
    case "infrastructure_failure":
      return { ok: false, code: AcceptanceResponseCode.TemporaryFailure };
  }
}
