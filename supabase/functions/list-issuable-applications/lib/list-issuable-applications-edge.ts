// ============================================================================
// Pulse — Tasks 2–3 · Founder-only Issuable-Applications Read Transport (U-LIST-EDGE)
// ----------------------------------------------------------------------------
// The platform/transport boundary for the READ-ONLY, founder-only list of
// issuable founding applications, as a TESTABLE handler factory. It owns only
// transport + authorization wiring: CORS/origin policy, HTTP method policy,
// caller authentication (reusing the frozen Supabase auth port), FOUNDER/ADMIN
// authorization via the SAME server-held allowlist as issuance
// (`createFounderAuthorization`), and a single injected read-only query.
//
// It performs NO SQL, NO Supabase client construction, NO mutation, NO
// `Deno`/environment access, and NO service-role handling — the service-role
// query is injected by the production composition root. There are no top-level
// side effects.
//
// AUTHORITY: this list is INFORMATIONAL/SELECTIVE ONLY and NEVER becomes
// authorization. `issue_invitation` remains the final authority and independently
// re-validates eligibility atomically at issuance; a listed candidate can become
// stale (TOCTOU) and issuance may still reject it. Eligibility mirrors the frozen
// `issue_invitation` success gates (exactly one UNOWNED business profile + no
// member) — it is not a new definition and is applied by the injected query port.
//
// SECURITY INVARIANTS (documented + preserved):
//   * ORDER: CORS/origin → OPTIONS → method → authenticate → AUTHORIZE (founder
//     allowlist) → read-only query → sanitized response.
//   * Authorization is server-held ONLY (verified auth-user id in the configured
//     allowlist); ordinary authenticated users receive a single non-enumerating
//     `unauthorized`. An empty eligible list is a SUCCESS, not an error.
//   * No provider/database/SQLSTATE/service-role/bearer/JWT detail is ever
//     returned or logged; every failure is a restrained, generic outcome. Only the
//     minimal founder-facing projection is returned (no PII beyond what identifies
//     the intended invitee and builds the frozen issuance request).
// ============================================================================

import type {
  AcceptanceAuthenticationPort,
  AcceptanceAuthenticationResult,
  OriginPolicy,
} from "./invitation-acceptance-edge.ts";
import type { FounderAuthorization } from "./invitation-issuance-edge.ts";

/**
 * The minimal founder-facing projection of an issuable founding application:
 * exactly what the issuance screen needs to identify the intended invitee and
 * construct the frozen `issue_invitation` request (`work_email` is the intended
 * `bound_email`). No phone, no full answers, no auth id, no internal/profile data.
 */
export interface IssuableApplication {
  readonly application_ref: string;
  readonly first_name: string;
  readonly last_name: string;
  readonly company: string | null;
  readonly work_email: string;
  /** Application submission time (ISO 8601), from the SAME founding_applications row. */
  readonly created_at: string;
}

/**
 * Read-only issuable-applications query port. Its production implementation uses
 * the SERVICE-ROLE client server-side to apply the frozen relational eligibility
 * rules and returns ONLY the minimal projection. It performs no mutation and no
 * lock; a `false` result is a fail-closed operational error (never provider detail).
 */
export interface IssuableApplicationsQueryPort {
  list(): Promise<
    | { readonly ok: true; readonly applications: readonly IssuableApplication[] }
    | { readonly ok: false }
  >;
}

/** Stable, non-enumerating response codes for the list transport. */
export const ListResponseCode = {
  Ok: "ok",
  Unauthorized: "unauthorized",
  AuthenticationRequired: "authentication_required",
  ForbiddenOrigin: "forbidden_origin",
  MethodNotAllowed: "method_not_allowed",
  TemporaryFailure: "temporary_failure",
} as const;

export type ListResponseCode = (typeof ListResponseCode)[keyof typeof ListResponseCode];

/** Build CORS headers; an unapproved origin is never reflected. `Vary: Origin` always set. */
function buildCorsHeaders(allowedOrigin: string | null): Headers {
  const headers = new Headers();
  headers.set("Vary", "Origin");
  if (allowedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", allowedOrigin);
    headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
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

function jsonResponse(body: object, status: number, corsHeaders: Headers): Response {
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(body), { status, headers });
}

/** Injected dependencies for the read-only founder list handler. */
export interface ListIssuableApplicationsHandlerDeps {
  readonly auth: AcceptanceAuthenticationPort;
  readonly authorization: FounderAuthorization;
  readonly query: IssuableApplicationsQueryPort;
  readonly originPolicy: OriginPolicy;
}

/**
 * Create the founder-only issuable-applications read handler. Deliberate order:
 * resolve CORS/origin → short-circuit OPTIONS → allow only safe read methods
 * (GET/POST) → authenticate → AUTHORIZE (founder allowlist) → run the injected
 * read-only query → return the minimal projection. An empty list is a 200 success;
 * nothing is logged; no mutation; failures are restrained generic outcomes.
 */
export function createListIssuableApplicationsHandler(
  deps: ListIssuableApplicationsHandlerDeps,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    // 1. CORS/origin (fail closed; arbitrary origins never reflected).
    const origin = request.headers.get("Origin");
    const originResult = deps.originPolicy.resolveOrigin(origin);
    const allowedOrigin = originResult.status === "allowed" ? originResult.allowedOrigin : null;
    const corsHeaders = buildCorsHeaders(allowedOrigin);
    if (originResult.status === "rejected") {
      return jsonResponse({ ok: false, code: ListResponseCode.ForbiddenOrigin }, 403, corsHeaders);
    }

    // 2. OPTIONS preflight: no auth, no authorization, no query.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // 3. Read-only endpoint: only safe methods (the browser SDK invoke uses POST).
    if (request.method !== "GET" && request.method !== "POST") {
      const headers = new Headers(corsHeaders);
      headers.set("Allow", "GET, POST, OPTIONS");
      headers.set("Content-Type", "application/json");
      return new Response(JSON.stringify({ ok: false, code: ListResponseCode.MethodNotAllowed }), {
        status: 405,
        headers,
      });
    }

    // 4. Authenticate the caller (before any authorization or query).
    let authResult: AcceptanceAuthenticationResult;
    try {
      authResult = await deps.auth.authenticate(request);
    } catch {
      return jsonResponse({ ok: false, code: ListResponseCode.TemporaryFailure }, 503, corsHeaders);
    }
    if (authResult.status === "unauthenticated") {
      return jsonResponse(
        { ok: false, code: ListResponseCode.AuthenticationRequired },
        401,
        corsHeaders,
      );
    }
    if (authResult.status === "failed") {
      return jsonResponse({ ok: false, code: ListResponseCode.TemporaryFailure }, 503, corsHeaders);
    }

    // 5. AUTHORIZE (founder allowlist) by the VERIFIED auth-user id. Non-founders
    //    receive the same non-enumerating `unauthorized` and no data.
    const authUserId = authResult.auth.authUserId as unknown as string;
    if (!deps.authorization.isFounder(authUserId)) {
      return jsonResponse({ ok: false, code: ListResponseCode.Unauthorized }, 403, corsHeaders);
    }

    // 6. Read-only query (service-role, server-side). An empty list is a success.
    let result: Awaited<ReturnType<IssuableApplicationsQueryPort["list"]>>;
    try {
      result = await deps.query.list();
    } catch {
      return jsonResponse({ ok: false, code: ListResponseCode.TemporaryFailure }, 503, corsHeaders);
    }
    if (!result.ok) {
      return jsonResponse({ ok: false, code: ListResponseCode.TemporaryFailure }, 503, corsHeaders);
    }
    return jsonResponse(
      { ok: true, code: ListResponseCode.Ok, applications: result.applications },
      200,
      corsHeaders,
    );
  };
}
