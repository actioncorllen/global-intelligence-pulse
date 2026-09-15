// ============================================================================
// Pulse — Tasks 2–3 · Founder-only Invitation Issuance Edge Function (entrypoint)
// ----------------------------------------------------------------------------
// The production Supabase Edge Function entrypoint for FOUNDER-ONLY invitation
// issuance. It is a COMPOSITION ROOT ONLY: it loads server-side configuration
// from the Deno environment, constructs the reviewed production dependencies
// (U9B) and the origin policy (U9D), wires the frozen auth port, the server-held
// founder authorization, and the service-role issue_invitation persistence port
// into the reviewed issuance transport handler, and registers it with Deno.serve.
// It contains NO business logic of its own.
//
// It performs NO token generation/hashing (U3/U2), NO validation/orchestration
// beyond composition, NO Supabase client construction of its own (U9B owns the
// two clients), and never calls `.rpc(`/`.from(` a table directly. NO authorization
// logic lives here beyond supplying the server-held founder allowlist to the
// reviewed authorization authority.
//
// SECURITY: the founder allowlist and the RPC/service-role client come only from
// server configuration; no founder id or origin is hard-coded. The caller bearer
// is never installed on either client (the auth port passes it per-call to
// auth.getUser; the service-role client never receives it). Environment values are
// read once, validated non-blank, and passed UNCHANGED to their owning modules —
// never trimmed, rewritten, printed, logged, or returned. Invalid configuration
// fails startup with a single generic error that identifies no variable and echoes
// no value. There is no request/response logging.
// ============================================================================

import { createSupabaseProductionDependencies } from "./lib/supabase-production-dependencies.ts";
import { createInvitationAcceptanceOriginPolicy } from "./lib/invitation-acceptance-origin-policy.ts";
import { createSupabaseAcceptanceAuthenticationPort } from "./lib/supabase-acceptance-auth.ts";
import {
  createFounderAuthorization,
  createInvitationIssuanceHandler,
  createSupabaseIssuanceRpcPersistencePort,
  type IssuanceRpcClient,
} from "./lib/invitation-issuance-edge.ts";

// ── Environment loading (owned only by this entrypoint) ─────────────────────

/** Single generic startup error — identifies no variable and echoes no value. */
const ENVIRONMENT_CONFIG_ERROR = "invalid invitation issuance environment configuration";

/**
 * Require a raw environment value to be a present, non-whitespace-only string and
 * return it UNCHANGED (no trimming/rewriting). Failure throws only the generic
 * startup error; the variable name and value never appear in the error.
 */
function readRequiredEnv(rawValue: string | undefined): string {
  if (typeof rawValue !== "string" || rawValue.trim().length === 0) {
    throw new Error(ENVIRONMENT_CONFIG_ERROR);
  }
  return rawValue;
}

const supabaseUrl = readRequiredEnv(Deno.env.get("SUPABASE_URL"));
const supabaseAnonKey = readRequiredEnv(Deno.env.get("SUPABASE_ANON_KEY"));
const supabaseServiceRoleKey = readRequiredEnv(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
const allowedOrigins = readRequiredEnv(Deno.env.get("ISSUANCE_ALLOWED_ORIGINS"));
// Server-held founder/admin allowlist: comma-separated auth.users.id UUIDs. Required
// (fail closed): without it the function cannot start, so no issuance is possible.
const founderAuthUserIds = readRequiredEnv(Deno.env.get("FOUNDER_ISSUER_AUTH_USER_IDS"));

// ── Composition (constructed once at module startup) ────────────────────────

// U9B: the two narrow production clients (anon → auth verifier; service-role → RPC).
const dependencies = createSupabaseProductionDependencies({
  supabaseUrl,
  supabaseAnonKey,
  supabaseServiceRoleKey,
});

// U9D: exact-origin policy from the configured allowlist; missing Origin rejected.
const originPolicy = createInvitationAcceptanceOriginPolicy({
  allowedOrigins,
  allowMissingOrigin: false,
});

// Auth port ← U9B anon-key verifier (auth.getUser is the sole authority; the
// caller bearer is verified server-side, never decoded/trusted locally).
const authenticationPort = createSupabaseAcceptanceAuthenticationPort(
  dependencies.authenticationVerifier,
);

// Server-held founder/admin authorization (allowlist by verified auth-user id).
const founderAuthorization = createFounderAuthorization({ founderAuthUserIds });

// Reuse the single service-role RPC caller U9B already constructed. Its nominal
// TS type is acceptance-specific, but the underlying caller is a generic
// `rpc(functionName, params)`; this composition-root boundary cast adapts it to
// the issuance RPC client contract (the same "adapt the real client" seam U9B
// documents) — it is not an `any` escape and adds no second client.
const issuanceRpcClient =
  dependencies.invitationValidationRpcClient as unknown as IssuanceRpcClient;

// Reviewed issuance transport handler ← origin policy + auth port + founder
// authorization + a per-request service-role issue_invitation persistence port.
const handler = createInvitationIssuanceHandler({
  auth: authenticationPort,
  authorization: founderAuthorization,
  createPersistencePort: (boundEmail: string) =>
    createSupabaseIssuanceRpcPersistencePort(issuanceRpcClient, boundEmail),
  originPolicy,
});

// ── Server registration ─────────────────────────────────────────────────────

Deno.serve((request) => handler(request));
