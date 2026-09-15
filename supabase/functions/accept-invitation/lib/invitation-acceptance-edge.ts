// ============================================================================
// Pulse — Tasks 2–3 · Invitation Acceptance Edge Transport Adapter (U6)
// ----------------------------------------------------------------------------
// The platform/transport boundary for invitation acceptance, implemented as a
// TESTABLE handler factory around U5 and an injected future-U7 acceptance
// service. It owns only transport mechanics: CORS/origin policy, HTTP method
// policy, single JSON parse, trusted-authentication delegation, U5 parsing,
// command assembly, one service call, U5 response mapping, and HTTP status
// selection. It uses only Web-standard `Request`/`Response`/`Headers`.
//
// This module is NOT a domain authority. It performs NO invitation validation,
// NO token hashing, NO invitation/member/application queries, NO consumption/
// provisioning, NO SQL, NO Supabase client construction, NO service-role access,
// NO identity-matching (D05) or session (D07) policy, and NO `Deno.serve`. All
// infrastructure is injected; there are no top-level side effects.
//
// AUTHENTICATION ADAPTER: the concrete Supabase authentication adapter (reads the
// Authorization bearer, verifies via Supabase Auth `getUser`, derives authUserId +
// trusted emailVerified) is provided by the sibling module
// `supabase-acceptance-auth.ts` and satisfies `AcceptanceAuthenticationPort`.
// PRODUCTION COMPOSITION (deferred): only the `Deno.serve` entrypoint, the real
// Supabase client + environment construction, the approved-origin configuration,
// and the real U7 acceptance service remain deferred (Deno is unavailable here to
// verify a Deno entrypoint). U6 is TRANSPORT + AUTH COMPLETE but NOT
// DEPLOYMENT-READY until that production composition exists.
//
// Reuses U5: parseAcceptanceRequest, mapAcceptanceOutcome, AcceptanceResponseCode,
// AcceptanceResponse, AcceptanceOutcome, InvitationAcceptanceCommand,
// AcceptanceAuthContext. U5 owns body allowlisting, response sanitization, and
// the enumeration collapse; U6 does not reimplement them.
//
// SECURITY INVARIANTS (documented and preserved):
//   * Only POST performs acceptance; OPTIONS never authenticates or invokes the
//     service; other methods never parse/authenticate/invoke.
//   * Arbitrary origins are never reflected; unapproved origins fail closed.
//   * Trusted auth facts come only from the injected auth port (never the body);
//     body-supplied identity is rejected by U5.
//   * The token stays untrusted here (never hashed, never queried); the future
//     U7 service is called at most once with { presentedToken, auth }.
//   * Response mapping preserves U5's enumeration collapse; auth/service/JSON
//     failures are sanitized (no messages, stacks, provider errors, tokens, or
//     hashes); bearer tokens are never logged or returned; transport success does
//     not itself establish database atomicity.
// ============================================================================

import type {
  AcceptanceAuthContext,
  AcceptanceOutcome,
  AcceptanceResponse,
  InvitationAcceptanceCommand,
} from "./invitation-acceptance-contract.ts";
import {
  AcceptanceResponseCode,
  mapAcceptanceOutcome,
  parseAcceptanceRequest,
} from "./invitation-acceptance-contract.ts";

// ── Injected ports ──────────────────────────────────────────────────────────

/** Result of the trusted authentication boundary (never exposes provider detail). */
export type AcceptanceAuthenticationResult =
  | { readonly status: "authenticated"; readonly auth: AcceptanceAuthContext }
  | { readonly status: "unauthenticated" }
  | { readonly status: "failed" };

/**
 * Trusted authentication port. Its concrete implementation lives in
 * `supabase-acceptance-auth.ts`: it reads the Authorization bearer, verifies it
 * through Supabase Auth `getUser`, and derives `AcceptanceAuthContext`
 * (authUserId + trusted emailVerified) — never from the body, never by trusting
 * unverified JWT claims. It must not expose provider errors or log bearer tokens.
 */
export interface AcceptanceAuthenticationPort {
  authenticate(request: Request): Promise<AcceptanceAuthenticationResult>;
}

/**
 * The future-U7 acceptance service port. Receives only the U5 internal command
 * and returns only a U5 acceptance outcome — no Request/Response, Supabase client,
 * Authorization header, service-role key, JWT, or HTTP status.
 */
export interface InvitationAcceptanceService {
  accept(command: InvitationAcceptanceCommand): Promise<AcceptanceOutcome>;
}

/**
 * Approved-origin policy result: either an approved origin to echo in
 * `Access-Control-Allow-Origin`, or an explicit rejection. A missing Origin is a
 * value the policy evaluates (and may reject) — it is NOT implicitly allowed.
 */
export type OriginPolicyResult =
  | { readonly status: "allowed"; readonly allowedOrigin: string }
  | { readonly status: "rejected" };

/**
 * Approved-origin policy. Given the raw request `Origin` header value (which may
 * be absent, i.e. `null`), returns an `OriginPolicyResult`. Production
 * composition supplies the approved origins and the missing-Origin decision; no
 * production origin is hard-coded here.
 */
export interface OriginPolicy {
  resolveOrigin(origin: string | null): OriginPolicyResult;
}

/** Injected dependencies for the acceptance handler. */
export interface InvitationAcceptanceHandlerDeps {
  readonly auth: AcceptanceAuthenticationPort;
  readonly acceptanceService: InvitationAcceptanceService;
  readonly originPolicy: OriginPolicy;
}

// ── Transport-level (non-outcome) response codes ────────────────────────────

/** Stable U6 transport codes for responses produced before/around the service. */
export const EdgeTransportCode = {
  InvalidRequest: "invalid_request",
  MethodNotAllowed: "method_not_allowed",
  ForbiddenOrigin: "forbidden_origin",
} as const;

export type EdgeTransportCode = (typeof EdgeTransportCode)[keyof typeof EdgeTransportCode];

interface EdgeResponseBody {
  readonly ok: boolean;
  readonly code: string;
}

// ── Internal helpers ────────────────────────────────────────────────────────

/**
 * Map a stable U5 response code to an HTTP status. Centralized so status
 * selection is not scattered. `InvitationNotAcceptable` is a single conservative
 * non-enumerating client status shared by all invalidity/integrity outcomes.
 */
function httpStatusForCode(code: AcceptanceResponse["code"]): number {
  switch (code) {
    case AcceptanceResponseCode.Accepted:
      return 200;
    case AcceptanceResponseCode.InvitationNotAcceptable:
      return 400;
    case AcceptanceResponseCode.AuthenticationRequired:
      return 401;
    case AcceptanceResponseCode.TemporaryFailure:
      return 503;
  }
}

/**
 * Build CORS headers. When `allowedOrigin` is null no `Access-Control-Allow-Origin`
 * is emitted (arbitrary origins are never reflected). `Vary: Origin` is always set.
 */
function buildCorsHeaders(allowedOrigin: string | null): Headers {
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (allowedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", allowedOrigin);
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    // supabase-js functions.invoke always sends `apikey` and `x-client-info` in
    // addition to Authorization/Content-Type; the preflight must allow them or the
    // browser blocks the POST (preflight 204 with no subsequent request).
    headers.set(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type, apikey, x-client-info",
    );
  }
  return headers;
}

/** Build a sanitized JSON response with the given status and CORS headers. */
function jsonResponse(body: EdgeResponseBody, status: number, corsHeaders: Headers): Response {
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

// ── Handler factory ─────────────────────────────────────────────────────────

/**
 * Create the invitation-acceptance request handler from injected dependencies.
 * Execution order (deliberate): resolve CORS/origin → short-circuit OPTIONS →
 * reject non-POST → authenticate (before any body work, so unauthenticated
 * callers trigger no parsing) → parse JSON once → U5-parse the body → assemble
 * the command from the untrusted token + trusted auth → call the service at most
 * once → map the outcome via U5 → return sanitized JSON. All failures are
 * sanitized; nothing is logged; no retries.
 */
export function createInvitationAcceptanceHandler(
  deps: InvitationAcceptanceHandlerDeps,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    // 1. Resolve CORS/origin through the injected policy exactly once. The raw
    //    Origin header (which may be absent) is evaluated by the policy; a
    //    rejected result — including a missing Origin — fails closed with 403 and
    //    no reflected origin. An arbitrary origin is never reflected.
    const origin = request.headers.get("Origin");
    const originResult = deps.originPolicy.resolveOrigin(origin);
    const allowedOrigin = originResult.status === "allowed" ? originResult.allowedOrigin : null;
    const corsHeaders = buildCorsHeaders(allowedOrigin);
    if (originResult.status === "rejected") {
      return jsonResponse({ ok: false, code: EdgeTransportCode.ForbiddenOrigin }, 403, corsHeaders);
    }

    // 2. OPTIONS preflight: no authentication, no business invocation.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // 3. Only POST performs acceptance.
    if (request.method !== "POST") {
      const headers = new Headers(corsHeaders);
      headers.set("Allow", "POST, OPTIONS");
      headers.set("Content-Type", "application/json");
      const body: EdgeResponseBody = { ok: false, code: EdgeTransportCode.MethodNotAllowed };
      return new Response(JSON.stringify(body), { status: 405, headers });
    }

    // 4. Authenticate through the trusted boundary (before any body processing).
    let authResult: AcceptanceAuthenticationResult;
    try {
      authResult = await deps.auth.authenticate(request);
    } catch {
      return jsonResponse(
        { ok: false, code: AcceptanceResponseCode.TemporaryFailure },
        503,
        corsHeaders,
      );
    }
    if (authResult.status === "unauthenticated") {
      return jsonResponse(
        { ok: false, code: AcceptanceResponseCode.AuthenticationRequired },
        401,
        corsHeaders,
      );
    }
    if (authResult.status === "failed") {
      return jsonResponse(
        { ok: false, code: AcceptanceResponseCode.TemporaryFailure },
        503,
        corsHeaders,
      );
    }

    // 5. Parse the JSON body exactly once; malformed JSON is a sanitized 400.
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return jsonResponse({ ok: false, code: EdgeTransportCode.InvalidRequest }, 400, corsHeaders);
    }

    // 6. Parse through U5 (owns allowlisting). Field distinctions are collapsed
    //    externally to a single invalid-request code.
    const parsed = parseAcceptanceRequest(body);
    if (!parsed.ok) {
      return jsonResponse({ ok: false, code: EdgeTransportCode.InvalidRequest }, 400, corsHeaders);
    }

    // 7. Assemble the command: untrusted token + trusted auth context.
    const command: InvitationAcceptanceCommand = {
      presentedToken: parsed.request.token,
      auth: authResult.auth,
    };

    // 8. Invoke the future-U7 service at most once; exceptions fail closed.
    let outcome: AcceptanceOutcome;
    try {
      outcome = await deps.acceptanceService.accept(command);
    } catch {
      outcome = { kind: "infrastructure_failure" };
    }

    // 9. Map via U5 and select the HTTP status centrally.
    const response = mapAcceptanceOutcome(outcome);
    return jsonResponse(response, httpStatusForCode(response.code), corsHeaders);
  };
}
