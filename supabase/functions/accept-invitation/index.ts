// ============================================================================
// Pulse — Tasks 2–3 · Invitation-Acceptance Edge Function Composition Root (U9C)
// ----------------------------------------------------------------------------
// The production Supabase Edge Function entrypoint for invitation acceptance. It
// is a COMPOSITION ROOT ONLY: it loads server-side configuration from the Deno
// environment, constructs the already-reviewed U9B production dependencies and
// the U9D origin policy exactly once at module startup, wires the committed
// U4/U6/U7/U8/U9A boundaries together, and registers the resulting U6 handler
// with `Deno.serve`. It contains NO business logic of its own.
//
// It performs NO transport mechanics (CORS, HTTP method/status, body parsing,
// bearer parsing, response mapping) — those belong to U6. NO validation, token
// hashing, or lifecycle classification — those belong to U4/U9A. NO acceptance
// orchestration — U7. NO atomic persistence — U8/MIG-009. NO Supabase client
// construction — U9B owns both clients; this file never imports `createClient`,
// never calls `.rpc(`/`.from(`, and never touches a table. NO origin parsing or
// allowlist membership — U9D. NO authentication logic — the U6 auth adapter.
//
// SECURITY (Round-4 T23-D31/D32/D33): the allowlist and the missing-Origin
// decision come only from configuration (`allowMissingOrigin: false`, frozen);
// no origin is hard-coded here. The caller bearer is never installed on either
// client (U6 passes it per-call to `auth.getUser`; the service-role client never
// receives it). Environment values are read once, validated non-blank, and passed
// UNCHANGED to their owning modules — never trimmed, rewritten, printed, logged,
// or returned. Invalid configuration fails startup with a single generic error
// that identifies no variable and echoes no value. There is no request/response
// logging and no catch that could expose provider or environment detail; request-
// time failure mapping stays entirely in U6/U7/U8/U9A.
// ============================================================================

import { createSupabaseProductionDependencies } from "./lib/supabase-production-dependencies.ts";
import { createInvitationAcceptanceOriginPolicy } from "./lib/invitation-acceptance-origin-policy.ts";
import { createSupabaseAcceptanceAuthenticationPort } from "./lib/supabase-acceptance-auth.ts";
import { createSupabaseInvitationLookupPort } from "./lib/supabase-invitation-validation.ts";
import { createSupabaseAtomicInvitationAcceptancePort } from "./lib/supabase-atomic-invitation-acceptance.ts";
import { validateInvitationToken } from "./lib/invitation-validation.ts";
import type { InvitationValidationPorts } from "./lib/invitation-validation.ts";
import { orchestrateInvitationAcceptance } from "./lib/invitation-acceptance-orchestrator.ts";
import type {
  InvitationAcceptancePorts,
  InvitationValidationPort,
} from "./lib/invitation-acceptance-orchestrator.ts";
import { createInvitationAcceptanceHandler } from "./lib/invitation-acceptance-edge.ts";
import type { InvitationAcceptanceService } from "./lib/invitation-acceptance-edge.ts";

// ── Environment loading (owned only by this entrypoint) ─────────────────────

/** Single generic startup error — identifies no variable and echoes no value. */
const ENVIRONMENT_CONFIG_ERROR = "invalid invitation acceptance environment configuration";

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
const allowedOrigins = readRequiredEnv(Deno.env.get("ACCEPTANCE_ALLOWED_ORIGINS"));

// ── Composition (constructed once at module startup) ────────────────────────

// U9B: the two narrow production clients (anon → auth verifier; service-role →
// RPC). The real default client factory is used; no caller bearer is injected.
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

// U6 authentication port ← U9B anon-key verifier (auth.getUser is the authority).
const authenticationPort = createSupabaseAcceptanceAuthenticationPort(
  dependencies.authenticationVerifier,
);

// U9A lookup port ← U9B service-role validation RPC client → U4 read-only validation.
const lookupPort = createSupabaseInvitationLookupPort(dependencies.invitationValidationRpcClient);
const validationPorts: InvitationValidationPorts = { lookup: lookupPort };
const validationPort: InvitationValidationPort = {
  validate: (command) => validateInvitationToken(command, validationPorts),
};

// U8 atomic acceptance port ← U9B service-role atomic RPC client (MIG-009).
const atomicPort = createSupabaseAtomicInvitationAcceptancePort(
  dependencies.atomicAcceptanceRpcClient,
);

// U7 orchestrator (validate-before-atomic) exposed as the U6 acceptance service.
const acceptancePorts: InvitationAcceptancePorts = {
  validation: validationPort,
  atomic: atomicPort,
};
const acceptanceService: InvitationAcceptanceService = {
  accept: (command) => orchestrateInvitationAcceptance(command, acceptancePorts),
};

// U6 transport handler ← origin policy + auth port + acceptance service.
const handler = createInvitationAcceptanceHandler({
  auth: authenticationPort,
  acceptanceService,
  originPolicy,
});

// ── Server registration ─────────────────────────────────────────────────────

Deno.serve((request) => handler(request));
