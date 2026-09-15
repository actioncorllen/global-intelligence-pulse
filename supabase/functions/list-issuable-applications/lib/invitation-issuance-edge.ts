// ============================================================================
// Pulse — Tasks 2–3 · Founder-only Invitation Issuance Edge Transport (U-ISSUE-EDGE)
// ----------------------------------------------------------------------------
// The platform/transport boundary for founder-only invitation ISSUANCE, as a
// TESTABLE handler factory that composes the FROZEN U3 orchestrator
// (`orchestrateInvitationIssuance`). It owns only transport + authorization
// wiring: CORS/origin policy, HTTP method policy, caller authentication (reusing
// the frozen Supabase auth port), FOUNDER/ADMIN authorization via a SERVER-HELD
// allowlist, a single strict request decode, one orchestration call, and
// sanitized response mapping.
//
// It performs NO token generation or hashing of its own (U3/U2 own that), NO SQL,
// NO Supabase client construction, NO direct table writes, and NO `Deno`/
// `Deno.serve`/environment access. All infrastructure is injected; there are no
// top-level side effects. Production composition (real clients + env + Deno.serve)
// is the sibling `supabase/functions/issue-invitation/index.ts` entrypoint.
//
// SECURITY INVARIANTS (documented + preserved):
//   * ORDER: CORS/origin → OPTIONS → POST-only → authenticate → AUTHORIZE
//     (founder allowlist) → strict body decode → orchestrate (U3: authorize →
//     generate token → hash → persist once → return token only on success).
//   * Authorization is server-held ONLY: the caller's VERIFIED auth-user id
//     (from Supabase `getUser`, never a decoded/unverified JWT, never the body,
//     never an email) must be in the configured founder allowlist. Missing/empty
//     allowlist ⇒ nobody is authorized (fail closed). Ordinary authenticated
//     users are rejected with a single non-enumerating `unauthorized`.
//   * The raw one-time token is returned to the authorized founder EXACTLY once,
//     only on a successful issuance. It is never logged, never persisted here, and
//     never present on any failure path. Only its hash reaches the RPC (inside U3).
//   * The service-role RPC client calls ONLY `issue_invitation(p_application_ref,
//     p_bound_email, p_token_hash)`; no direct table INSERT/UPDATE/DELETE.
//   * No provider/database/SQLSTATE/constraint/service-role/bearer/JWT detail is
//     ever returned or logged; every failure is a restrained, generic outcome.
// ============================================================================

import type { ApplicationRef, InvitationId, IssuanceOutcome } from "./domain-contracts.ts";
import {
  IssuanceFailure,
  orchestrateInvitationIssuance,
  type AtomicIssuancePersistencePort,
  type InvitationIssuanceCommand,
  type IssuanceAuthorizationPort,
  type IssuancePersistenceInput,
  type IssuancePersistenceResult,
  type TrustedActorRef,
} from "./invitation-issuance.ts";
// Reuse the FROZEN, generic transport ports/types from the acceptance edge (their
// shapes are transport-generic despite the "Acceptance" name): the authentication
// port, its result, and the approved-origin policy. No re-implementation.
import type {
  AcceptanceAuthenticationPort,
  AcceptanceAuthenticationResult,
  OriginPolicy,
} from "./invitation-acceptance-edge.ts";

// ── Founder/admin authorization (server-held allowlist) ─────────────────────

/**
 * Server-held configuration: a comma-separated list of founder/admin Auth-user
 * ids (auth.users.id UUIDs) authorized to issue invitations. Provided ONLY by the
 * server entrypoint from a server-only environment variable — never from a caller.
 */
export interface FounderAuthorizationConfig {
  readonly founderAuthUserIds: string;
}

/** Canonicalize a comma-separated allowlist into a set of lower-cased, trimmed ids. */
function parseFounderAllowlist(raw: string): ReadonlySet<string> {
  const set = new Set<string>();
  if (typeof raw !== "string") return set;
  for (const segment of raw.split(",")) {
    const id = segment.trim().toLowerCase();
    if (id.length > 0) set.add(id);
  }
  return set;
}

/**
 * The founder-allowlist authorization authority. `isFounder` is the single
 * authoritative predicate (server-held allowlist membership by verified auth-user
 * id); `authorizationPort` adapts it to the frozen U3 `IssuanceAuthorizationPort`
 * so the orchestrator itself refuses to generate a token for a non-founder.
 */
export interface FounderAuthorization {
  isFounder(authUserId: string): boolean;
  readonly authorizationPort: IssuanceAuthorizationPort;
}

/**
 * Build the server-held founder authorization from configuration. An empty or
 * blank allowlist authorizes NOBODY (fail closed). Membership is by exact
 * (lower-cased, trimmed) auth-user id; no email, body, claim, or wildcard is used.
 */
export function createFounderAuthorization(
  config: FounderAuthorizationConfig,
): FounderAuthorization {
  const allow = parseFounderAllowlist(config.founderAuthUserIds);
  const isFounder = (authUserId: string): boolean =>
    typeof authUserId === "string" && allow.has(authUserId.trim().toLowerCase());
  return {
    isFounder,
    authorizationPort: {
      // U3 calls this BEFORE any token generation; the actor is the verified
      // auth-user id the entrypoint placed on the command.
      authorize: (command: InvitationIssuanceCommand): Promise<boolean> =>
        Promise.resolve(isFounder(command.actor as unknown as string)),
    },
  };
}

// ── Service-role issue_invitation persistence port ──────────────────────────

/** The smallest service-role RPC caller slice this adapter consumes. */
export interface IssuanceRpcClient {
  rpc(
    functionName: string,
    parameters: object,
  ): PromiseLike<{ readonly data: unknown; readonly error: unknown }>;
}

/** Runtime shape of the MIG-015 issue_invitation jsonb result (decoded fail-closed). */
interface RawIssuanceResult {
  readonly status?: unknown;
  readonly outcome?: unknown;
  readonly invitation_ref?: unknown;
}

function decodeIssuanceRpcResult(data: unknown): IssuancePersistenceResult {
  if (data === null || typeof data !== "object") {
    return { status: "failed" };
  }
  const r = data as RawIssuanceResult;
  if (r.status === "rejected") {
    return { status: "rejected" };
  }
  if (
    r.status === "issued" &&
    (r.outcome === "issued" || r.outcome === "reissued") &&
    typeof r.invitation_ref === "string" &&
    r.invitation_ref.length > 0
  ) {
    return {
      status: "issued",
      outcome: r.outcome as IssuanceOutcome,
      invitationId: r.invitation_ref as InvitationId,
    };
  }
  return { status: "failed" };
}

/**
 * Build the frozen `AtomicIssuancePersistencePort` bound to one request's bound
 * email. `issue({ applicationRef, tokenHash })` calls ONLY the service-role RPC
 * `issue_invitation(p_application_ref, p_bound_email, p_token_hash)` exactly once
 * and decodes its jsonb result fail-closed. It performs no direct table access,
 * stores/returns/logs no token, and surfaces no provider error (any transport
 * error or malformed/unknown shape collapses to `failed`).
 */
export function createSupabaseIssuanceRpcPersistencePort(
  client: IssuanceRpcClient,
  boundEmail: string,
): AtomicIssuancePersistencePort {
  return {
    issue: async (input: IssuancePersistenceInput): Promise<IssuancePersistenceResult> => {
      let data: unknown;
      let error: unknown;
      try {
        const res = await client.rpc("issue_invitation", {
          p_application_ref: input.applicationRef as unknown as string,
          p_bound_email: boundEmail,
          p_token_hash: input.tokenHash as unknown as string,
        });
        data = res.data;
        error = res.error;
      } catch {
        return { status: "failed" };
      }
      if (error != null) {
        return { status: "failed" };
      }
      return decodeIssuanceRpcResult(data);
    },
  };
}

// ── Strict request decode ───────────────────────────────────────────────────

/** Exactly the two founder-controlled inputs the frozen issuance flow needs. */
export interface IssuanceRequest {
  readonly applicationRef: string;
  readonly boundEmail: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_KEYS: ReadonlySet<string> = new Set(["application_ref", "bound_email"]);

/**
 * Strictly decode the request body. Accepts ONLY a plain object with exactly
 * `application_ref` (UUID string) and `bound_email` (non-blank string ≤ 254).
 * Any unknown top-level key, missing/extra field, wrong type, non-UUID
 * application_ref, or blank/over-long email is rejected (fail closed). The DB RPC
 * remains the authoritative semantic validator (eligibility, email canonical
 * form, hash format).
 */
export function parseIssuanceRequest(
  body: unknown,
): { ok: true; request: IssuanceRequest } | { ok: false } {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false };
  }
  const obj = body as Record<string, unknown>;
  for (const key of Object.keys(obj)) {
    if (!ALLOWED_KEYS.has(key)) return { ok: false }; // reject unknown keys
  }
  const applicationRef = obj.application_ref;
  const boundEmail = obj.bound_email;
  if (typeof applicationRef !== "string" || !UUID_RE.test(applicationRef)) {
    return { ok: false };
  }
  if (typeof boundEmail !== "string") {
    return { ok: false };
  }
  const trimmed = boundEmail.trim();
  if (trimmed.length === 0 || trimmed.length > 254) {
    return { ok: false };
  }
  return { ok: true, request: { applicationRef, boundEmail } };
}

// ── Response codes + helpers ────────────────────────────────────────────────

/** Stable, non-enumerating response codes for the issuance transport. */
export const IssuanceResponseCode = {
  Issued: "issued",
  Rejected: "rejected",
  Unauthorized: "unauthorized",
  AuthenticationRequired: "authentication_required",
  InvalidRequest: "invalid_request",
  MethodNotAllowed: "method_not_allowed",
  ForbiddenOrigin: "forbidden_origin",
  TemporaryFailure: "temporary_failure",
} as const;

export type IssuanceResponseCode = (typeof IssuanceResponseCode)[keyof typeof IssuanceResponseCode];

/** Build CORS headers; an unapproved origin is never reflected. `Vary: Origin` always set. */
function buildCorsHeaders(allowedOrigin: string | null): Headers {
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (allowedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", allowedOrigin);
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
  }
  return headers;
}

function jsonResponse(body: object, status: number, corsHeaders: Headers): Response {
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

// ── Handler dependencies ────────────────────────────────────────────────────

export interface InvitationIssuanceHandlerDeps {
  readonly auth: AcceptanceAuthenticationPort;
  readonly authorization: FounderAuthorization;
  /** Per-request service-role persistence port bound to the request's bound email. */
  readonly createPersistencePort: (boundEmail: string) => AtomicIssuancePersistencePort;
  readonly originPolicy: OriginPolicy;
}

// ── Handler factory ─────────────────────────────────────────────────────────

/**
 * Create the founder-only issuance request handler. Deliberate order: resolve
 * CORS/origin → short-circuit OPTIONS → reject non-POST → authenticate → AUTHORIZE
 * (founder allowlist, before any body work or token generation) → strict body
 * decode → compose the frozen U3 orchestrator (which authorizes again, then
 * generates/hashes the token and calls the RPC exactly once) → return the raw
 * token exactly once on success, else a sanitized failure. Nothing is logged; no
 * retries; the raw token never leaves a success path.
 */
export function createInvitationIssuanceHandler(
  deps: InvitationIssuanceHandlerDeps,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    // 1. CORS/origin (fail closed; arbitrary origins never reflected).
    const origin = request.headers.get("Origin");
    const originResult = deps.originPolicy.resolveOrigin(origin);
    const allowedOrigin = originResult.status === "allowed" ? originResult.allowedOrigin : null;
    const corsHeaders = buildCorsHeaders(allowedOrigin);
    if (originResult.status === "rejected") {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.ForbiddenOrigin },
        403,
        corsHeaders,
      );
    }

    // 2. OPTIONS preflight: no auth, no authorization, no business.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // 3. Only POST issues.
    if (request.method !== "POST") {
      const headers = new Headers(corsHeaders);
      headers.set("Allow", "POST, OPTIONS");
      headers.set("Content-Type", "application/json");
      return new Response(
        JSON.stringify({ ok: false, code: IssuanceResponseCode.MethodNotAllowed }),
        { status: 405, headers },
      );
    }

    // 4. Authenticate the caller (before any body processing / authorization).
    let authResult: AcceptanceAuthenticationResult;
    try {
      authResult = await deps.auth.authenticate(request);
    } catch {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.TemporaryFailure },
        503,
        corsHeaders,
      );
    }
    if (authResult.status === "unauthenticated") {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.AuthenticationRequired },
        401,
        corsHeaders,
      );
    }
    if (authResult.status === "failed") {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.TemporaryFailure },
        503,
        corsHeaders,
      );
    }

    // 5. AUTHORIZE (founder allowlist) BEFORE any body work or token generation.
    //    Non-enumerating: an authenticated non-founder receives the same
    //    `unauthorized` as any other denial.
    const authUserId = authResult.auth.authUserId as unknown as string;
    if (!deps.authorization.isFounder(authUserId)) {
      return jsonResponse({ ok: false, code: IssuanceResponseCode.Unauthorized }, 403, corsHeaders);
    }

    // 6. Parse the JSON body exactly once; malformed JSON is a sanitized 400.
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.InvalidRequest },
        400,
        corsHeaders,
      );
    }

    // 7. Strict decode of the founder-controlled inputs.
    const parsed = parseIssuanceRequest(body);
    if (!parsed.ok) {
      return jsonResponse(
        { ok: false, code: IssuanceResponseCode.InvalidRequest },
        400,
        corsHeaders,
      );
    }

    // 8. Compose the frozen U3 orchestrator. The actor is the VERIFIED auth-user
    //    id (server-resolved); the persistence port is bound to this request's
    //    bound email and calls the service-role RPC exactly once.
    const command: InvitationIssuanceCommand = {
      applicationRef: parsed.request.applicationRef as unknown as ApplicationRef,
      actor: authUserId as unknown as TrustedActorRef,
    };
    const persistence = deps.createPersistencePort(parsed.request.boundEmail);

    const result = await orchestrateInvitationIssuance(command, {
      authorization: deps.authorization.authorizationPort,
      persistence,
    });

    // 9. Map to a sanitized response. The raw token is returned EXACTLY once,
    //    only on success.
    if (result.ok) {
      return jsonResponse(
        {
          status: IssuanceResponseCode.Issued,
          outcome: result.outcome,
          invitation_ref: result.invitationId as unknown as string,
          token: result.token as unknown as string,
        },
        200,
        corsHeaders,
      );
    }
    if (result.failure === IssuanceFailure.Unauthorized) {
      return jsonResponse({ ok: false, code: IssuanceResponseCode.Unauthorized }, 403, corsHeaders);
    }
    if (result.failure === IssuanceFailure.PersistenceRejected) {
      return jsonResponse({ ok: false, code: IssuanceResponseCode.Rejected }, 422, corsHeaders);
    }
    // PersistenceFailed (or any residual): restrained temporary failure.
    return jsonResponse(
      { ok: false, code: IssuanceResponseCode.TemporaryFailure },
      503,
      corsHeaders,
    );
  };
}
