// ============================================================================
// Pulse — Tasks 2–3 · Supabase Acceptance Authentication Adapter (U6)
// ----------------------------------------------------------------------------
// The concrete trusted-authentication boundary for invitation acceptance. It
// OWNS: reading the Authorization header, validating Bearer syntax, sending the
// bearer credential to VERIFIED Supabase Auth (`auth.getUser`), deriving the
// authenticated auth-user id and trusted email-verification status, mapping
// invalid credentials, and sanitizing provider failures. It satisfies the U6
// `AcceptanceAuthenticationPort`; the handler depends only on that port and never
// imports a Supabase client or knows how authentication is performed.
//
// U7 receives only `AcceptanceAuthContext`. It NEVER receives the Request, the
// Authorization header, the bearer token, a JWT, a Supabase client, a provider
// error, a session, or arbitrary JWT claims.
//
// This module is platform-neutral TypeScript: no Deno, no concrete Supabase SDK
// import, no `supabase/functions/`, no `Deno.serve`, no top-level environment
// access. It models only the smallest structural slice of a Supabase client it
// needs. Production composition (real client + env construction) is deferred to a
// Deno-verifiable entrypoint unit and is NOT created here.
//
// SECURITY INVARIANTS: the JWT is never decoded or trusted locally (verification
// is delegated to Supabase `getUser`); `getSession` is not used as authority; no
// table query or RPC occurs; the credential is never trimmed/normalized (beyond
// scheme separation), logged, returned, or placed in an exception; provider error
// text/metadata is never propagated; the user email is never exposed; malformed
// verified-user data fails closed.
// ============================================================================

import type { AuthUserId } from "./domain-contracts.ts";
import type { AcceptanceAuthContext } from "./invitation-acceptance-contract.ts";
import type {
  AcceptanceAuthenticationPort,
  AcceptanceAuthenticationResult,
} from "./invitation-acceptance-edge.ts";

// ── Minimal structural Supabase auth-verification client contract ───────────
// Only the fields the adapter reads are modelled. No access/refresh token,
// session, provider token, JWT payload, arbitrary metadata, or email is modelled.

/** The verified-user slice the adapter reads from a Supabase `getUser` result. */
export interface VerifiedSupabaseUser {
  readonly id: string;
  /** Canonical email-confirmation timestamp; null/absent means unconfirmed. */
  readonly email_confirmed_at: string | null;
}

/**
 * The structural result of `auth.getUser(accessToken)`. `error` is typed
 * `unknown`: only its PRESENCE is inspected (a returned error means the credential
 * did not verify); its content is never read or propagated.
 */
export interface SupabaseAuthGetUserResult {
  readonly data: { readonly user: VerifiedSupabaseUser | null };
  readonly error: unknown;
}

/** The smallest Supabase client slice required for verified authentication. */
export interface SupabaseAuthVerificationClient {
  readonly auth: {
    getUser(accessToken: string): Promise<SupabaseAuthGetUserResult>;
  };
}

// ── Authorization header parsing ────────────────────────────────────────────

/**
 * Extract the Bearer credential from an Authorization header, or null if the
 * header is missing/empty, uses the wrong scheme, omits the credential, is
 * whitespace-only, combines multiple credentials (comma), or carries multiple
 * whitespace-separated tokens. The scheme is matched case-insensitively; the
 * credential is returned unchanged (no trimming/normalization beyond scheme
 * separation). The JWT is never decoded or inspected here.
 */
function parseBearerCredential(header: string | null): string | null {
  if (header === null) return null;
  if (header.includes(",")) return null; // reject comma-combined credentials
  const parts = header.split(/\s+/).filter((part) => part.length > 0);
  if (parts.length !== 2) return null; // reject missing credential / multiple tokens / empty
  const [scheme, credential] = parts;
  if (scheme.toLowerCase() !== "bearer") return null;
  if (credential.length === 0) return null;
  return credential;
}

// ── Adapter factory ─────────────────────────────────────────────────────────

/**
 * Create the concrete Supabase-backed `AcceptanceAuthenticationPort`. The client
 * is injected (the smallest testable boundary): `auth.getUser(accessToken)`
 * verifies any presented credential server-side, so no per-request client is
 * required here. Production composition supplies the real client.
 *
 * Result mapping: valid verified user → `authenticated`; no user or a returned
 * provider error (invalid/expired credential) → `unauthenticated`; a thrown
 * provider/infrastructure exception → `failed`. Distinctions are never leaked.
 */
export function createSupabaseAcceptanceAuthenticationPort(
  client: SupabaseAuthVerificationClient,
): AcceptanceAuthenticationPort {
  return {
    authenticate: async (request: Request): Promise<AcceptanceAuthenticationResult> => {
      const credential = parseBearerCredential(request.headers.get("Authorization"));
      if (credential === null) {
        return { status: "unauthenticated" };
      }

      let result: SupabaseAuthGetUserResult;
      try {
        result = await client.auth.getUser(credential);
      } catch {
        // Provider/infrastructure exception: fail closed without any detail.
        return { status: "failed" };
      }

      // A returned error means the credential did not verify (invalid/expired).
      if (result.error != null) {
        return { status: "unauthenticated" };
      }
      const user = result.data.user;
      if (user === null) {
        return { status: "unauthenticated" };
      }
      // Malformed verified-user data fails closed.
      if (typeof user.id !== "string" || user.id.length === 0) {
        return { status: "unauthenticated" };
      }

      // emailVerified is derived ONLY from the trusted confirmation timestamp.
      const emailVerified =
        typeof user.email_confirmed_at === "string" && user.email_confirmed_at.length > 0;
      const auth: AcceptanceAuthContext = {
        authUserId: user.id as AuthUserId,
        emailVerified,
      };
      return { status: "authenticated", auth };
    },
  };
}
