// ============================================================================
// Pulse — Tasks 2–3 · Internal Backend Domain Contracts (U1)
// ----------------------------------------------------------------------------
// INTERNAL, server-side domain vocabulary shared by later Tasks 2–3 units. This
// module is NOT a public API, NOT frontend-facing, and contains NO business
// logic, NO SQL, NO HTTP/JSON shapes, NO public error codes, NO validation or
// transformation functions, and NO runtime side effects.
//
// Runtime footprint: the module emits a small set of side-effect-free `as const`
// category objects (the enums in Sections 2–8) that later SERVER units require
// for runtime membership/comparison; everything else is type-only. There are no
// top-level calls, no Object.freeze, and no imports.
//
// Frozen authority (do not reinterpret here):
//   * docs/backend/tasks-2-3/tasks-2-3-founder-decision-register-round-1.md
//   * docs/backend/tasks-2-3/tasks-2-3-founder-decision-register-round-2.md
// Schema authority: MIG-001 public.member · MIG-002 public.invitation ·
//   MIG-003 public.discovery_state · MIG-004 public.auth_event ·
//   MIG-007 RLS/privilege lockdown · MIG-008 guards + fn_log_auth_event.
//
// Explicitly OPEN founder decisions are NOT resolved here (D05-A/B, D07 provider
// & n8n config & verification, D08-a cross-application same-email, D11 public
// payload/error schema, D12 communication_logs, later member editability). Where
// D08 leaves duplicate-command handling to the implementation (idempotent replay
// vs safe reject), no such behaviour is decided in these contracts.
// ============================================================================

// ── Section 1 · Branded value-object types (nominal, type-level only) ────────
// Nominal branding prevents accidental interchange of same-primitive ids at the
// type level. Construction/validation belongs to later units (e.g. the token
// utility in U2); this module declares the contract only, with no runtime brand.

declare const __brand: unique symbol;

/** Nominal brand helper. `T` is the underlying primitive; `B` the brand tag. */
type Brand<T, B extends string> = T & { readonly [__brand]: B };

/** public.invitation.id (uuid). */
export type InvitationId = Brand<string, "InvitationId">;

/**
 * public.invitation.application_ref (uuid), NON-NULL. The authoritative
 * invitation lifecycle identity for Task-2-managed invitations (Round-2 D08).
 * Every invitation inside the approved Tasks 2–3 lifecycle MUST carry a non-null
 * value; issuance and provisioning inputs REQUIRE this type. Absence is not a
 * valid lifecycle value — see `ObservedApplicationRef`.
 */
export type ApplicationRef = Brand<string, "ApplicationRef">;

/**
 * An `application_ref` slot as it may appear in STORED data, where the MIG-002
 * column remains nullable. `null` is an INVALID lifecycle state; this type exists
 * ONLY to classify legacy/inconsistent stored rows during integrity inspection.
 * It MUST NOT be used as an issuance or provisioning input — those require a
 * non-null `ApplicationRef`. A null observed here is rejected by the lifecycle
 * (validation failure `InvitationValidationFailure.NullApplicationRef`).
 */
export type ObservedApplicationRef = ApplicationRef | null;

/** public.member.id (uuid). */
export type MemberId = Brand<string, "MemberId">;

/** public.member.auth_user_id → auth.users.id (uuid). Identity binding (MIG-001). */
export type AuthUserId = Brand<string, "AuthUserId">;

/** public.discovery_state.id (uuid). */
export type DiscoveryStateId = Brand<string, "DiscoveryStateId">;

/**
 * public.invitation.token_hash. Round-2 D04: the SHA-256 digest of the presented
 * raw token, encoded as lowercase hexadecimal, exactly 64 characters. The raw
 * token is NEVER represented in this module and MUST never be persisted/logged.
 */
export type TokenHash = Brand<string, "TokenHash">;

/**
 * A server-side normalized email value. The single normalization rule is applied
 * at issuance and re-applied at consumption for deterministic matching (the rule
 * itself lives in a later server unit; this is the type contract only).
 */
export type NormalizedEmail = Brand<string, "NormalizedEmail">;

/**
 * public.invitation.bound_email (normalized). The immutable security binding used
 * for token validation, invitation/email matching, and Auth-identity matching
 * (Round-2 D07/D08). Modelled as a `NormalizedEmail` to enforce the shared rule.
 */
export type BoundEmail = NormalizedEmail;

// ── Section 2 · Invitation lifecycle states ─────────────────────────────────
// MIG-002 invitation_status_check: issued | consumed | expired | revoked.
// Transitions are server-side only (Round-2 D08); values are application-governed
// but constrained by the frozen CHECK. Runtime const: server units compare state.

export const InvitationStatus = {
  Issued: "issued",
  Consumed: "consumed",
  Expired: "expired",
  Revoked: "revoked",
} as const;

export type InvitationStatus = (typeof InvitationStatus)[keyof typeof InvitationStatus];

// ── Section 3 · Discovery bootstrap state identifiers ───────────────────────
// MIG-003 discovery_state.status: application-governed text; Sprint 1 uses
// not_started | started (no DB enum/CHECK). Provisioning invariant (Round-2 D02):
// exactly one discovery_state row per member, initialized to `not_started`,
// must exist before provisioning reports success.

export const DiscoveryStateStatus = {
  NotStarted: "not_started",
  Started: "started",
} as const;

export type DiscoveryStateStatus = (typeof DiscoveryStateStatus)[keyof typeof DiscoveryStateStatus];

/** The frozen initial discovery_state status set at provisioning (Round-2 D02). */
export type DiscoveryBootstrapStatus = typeof DiscoveryStateStatus.NotStarted;

// ── Section 4 · Member account status ───────────────────────────────────────
// MIG-001 member_account_status_check: active | disabled. Server-owned only
// (Round-2 D06 + MIG-007/MIG-008). No disable/suspend workflow is designed here.

export const AccountStatus = {
  Active: "active",
  Disabled: "disabled",
} as const;

export type AccountStatus = (typeof AccountStatus)[keyof typeof AccountStatus];

/** The frozen initial account_status set at provisioning (Round-2 D06). */
export type InitialAccountStatus = typeof AccountStatus.Active;

// ── Section 5 · Invitation validation failure classifications (internal) ────
// Internal category discriminants for why a presented token is not currently
// acceptable. Reused by the provisioning function's final revalidation (the DB
// function is the final authority). NOT HTTP status codes, NOT public error
// codes, NOT messages — the public payload/error schema remains blocked by D11.

export const InvitationValidationFailure = {
  /** No invitation matches the presented token digest. */
  NotFound: "not_found",
  /** token_hash mismatch for the located lifecycle. */
  HashMismatch: "hash_mismatch",
  /** Invitation exists but status is not `issued`. */
  NotIssued: "not_issued",
  /** now() > expires_at, validated server-side (never a client clock). */
  Expired: "expired",
  /** Invitation has been revoked (incl. superseded predecessors). */
  Revoked: "revoked",
  /** Invitation has already been consumed. */
  Consumed: "consumed",
  /** application_ref IS NULL — outside the approved Tasks 2–3 lifecycle (D08). */
  NullApplicationRef: "null_application_ref",
  /** Presented email does not match the immutable bound_email binding. */
  BoundEmailMismatch: "bound_email_mismatch",
} as const;

export type InvitationValidationFailure =
  (typeof InvitationValidationFailure)[keyof typeof InvitationValidationFailure];

// ── Section 6 · Issuance / reissue positive outcomes (internal) ─────────────
// Frozen positive outcomes of the atomic issuance/reissue operation (Round-2
// D08). Only the two founder-frozen outcomes are enumerated. D08 leaves the
// handling of a repeated logical command to the implementation ("deterministic
// idempotent outcome OR safely reject the duplicate"); that behaviour is
// intentionally NOT decided here and is deferred to the issuance-function design.

export const IssuanceOutcome = {
  /** A first invitation was issued for the application lifecycle. */
  Issued: "issued",
  /** A successor was issued; the predecessor was revoked and superseded (D08). */
  Reissued: "reissued",
} as const;

export type IssuanceOutcome = (typeof IssuanceOutcome)[keyof typeof IssuanceOutcome];

// ── Section 7 · Provisioning / acceptance result categories (internal) ──────
// Internal outcome categories for the atomic acceptance/provisioning operation
// (Round-2 D10-C/D11). Each member has a precise role. Pre-provision revalidation
// failures are classified by `InvitationValidationFailure` (Section 5), NOT here,
// so there is no generic "rejected" category.

export const ProvisioningOutcome = {
  /** Fresh atomic provisioning committed: invitation consumed, member created,
   *  and exactly one discovery_state (`not_started`) created, all-or-nothing. */
  Provisioned: "provisioned",
  /** Idempotent success — produced ONLY when ALL D11 reconciliation conditions
   *  (Section 8 mapping) are satisfied for an already-consumed invitation. */
  AlreadyProvisioned: "already_provisioned",
  /** Invitation is consumed but the completed state is incomplete or
   *  contradictory (some D11 condition fails). Deterministic failure; MUST NOT
   *  create a second member or discovery_state. See `IntegrityStateFailure`. */
  IntegrityState: "integrity_state",
} as const;

export type ProvisioningOutcome = (typeof ProvisioningOutcome)[keyof typeof ProvisioningOutcome];

// ── Section 8 · Internal integrity-state failure categories (D11) ───────────
// Sub-classification for `ProvisioningOutcome.IntegrityState`. Each member maps
// to a frozen Round-2 D11 reconciliation condition (see the mapping in the U1
// review notes). Internal only; not a public error taxonomy (blocked by D11).
// D11 conditions C1 (status = consumed) and C3 (resolved auth_user_id exists) are
// entry gates to reconciliation, not integrity categories, so they have no member
// here. No D11 condition is invented.

export const IntegrityStateFailure = {
  /** D11 C4: no member exists for the resolved auth identity. */
  MissingMember: "missing_member",
  /** D11 C4: more than one member matches the resolved auth identity. */
  DuplicateMember: "duplicate_member",
  /** D11 C7: a different member conflicts on the Auth identity or bound email. */
  ConflictingMember: "conflicting_member",
  /** D11 C4/C5/C7 cross-check: a located member's auth_user_id does not match the
   *  resolved auth identity. */
  AuthUserMismatch: "auth_user_mismatch",
  /** D11 C5: member.email does not correspond to invitation.bound_email. */
  BoundEmailMismatch: "bound_email_mismatch",
  /** D11 C2: the consumed invitation's application_ref does not match the
   *  expected non-null lifecycle identity. */
  ApplicationRefMismatch: "application_ref_mismatch",
  /** D11 C6: no discovery_state exists for the member. */
  MissingDiscoveryState: "missing_discovery_state",
  /** D11 C6: more than one discovery_state exists for the member. */
  DuplicateDiscoveryState: "duplicate_discovery_state",
  /** D11 C8: invitation successor/revocation linkage is contradictory. */
  SuccessorRevocationConflict: "successor_revocation_conflict",
} as const;

export type IntegrityStateFailure =
  (typeof IntegrityStateFailure)[keyof typeof IntegrityStateFailure];

// ── Section 9 · Server-side domain value objects (internal, type-only) ──────
// Internal, server-owned representations. NOT request/response payloads and NOT
// frontend DTOs. Trusted-input facts, security bindings, and server-owned
// constants are modelled SEPARATELY so no single caller-provided object can carry
// server-owned defaults or fabricate trusted Auth state. All type-only.

/**
 * Profile facts SOURCED from the accepted founding application (Round-2 D06).
 * These originate from trusted server-side data, not from the browser.
 * `displayName`/`businessName` are nullable exactly where MIG-001 permits.
 */
export interface SourcedMemberProfileFacts {
  readonly email: NormalizedEmail;
  readonly displayName: string | null;
  readonly businessName: string | null;
}

/**
 * Identity facts derived from TRUSTED Supabase Auth state (Round-2 D05/D06).
 * `emailVerified` REFLECTS Auth confirmation and must never be fabricated true.
 */
export interface TrustedAuthIdentityFacts {
  readonly authUserId: AuthUserId;
  readonly emailVerified: boolean;
}

/**
 * Server-OWNED initial member state constants set by the provisioning unit
 * (Round-2 D06 + D02). These are not caller-provided: `accountStatus` is `active`
 * and `welcomeSeen` is `false` by frozen decision; the member's journey begins at
 * the discovery bootstrap status. Type-only — the concrete literals are applied
 * server-side by the provisioning unit, not injected as runtime data here.
 */
export interface ServerOwnedInitialMemberState {
  readonly accountStatus: InitialAccountStatus;
  readonly welcomeSeen: false;
  readonly discoveryStatus: DiscoveryBootstrapStatus;
}

/**
 * The immutable invitation security binding carried through validation →
 * auth-resolution → provisioning (Round-2 D04/D07/D08). Server-side only.
 * `applicationRef` is non-null: only lifecycle-valid invitations are represented.
 */
export interface InvitationSecurityBinding {
  readonly invitationId: InvitationId;
  readonly applicationRef: ApplicationRef;
  readonly boundEmail: BoundEmail;
  readonly tokenHash: TokenHash;
  readonly status: InvitationStatus;
}

/**
 * The provisioning identity linkage proven during acceptance reconciliation
 * (Round-2 D11). Server-side only.
 */
export interface ProvisioningIdentity {
  readonly authUserId: AuthUserId;
  readonly memberId: MemberId;
  readonly discoveryStateId: DiscoveryStateId;
}
