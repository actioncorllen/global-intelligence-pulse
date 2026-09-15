// ============================================================================
// Pulse — Tasks 2–3 · Production Dependency / Supabase Client Factory (U9B)
// ----------------------------------------------------------------------------
// Server-side composition ONLY. This unit constructs two distinct Supabase
// clients and adapts them to the narrow injected interfaces the domain units
// already own:
//   * an ANON-key client → U6's `SupabaseAuthVerificationClient` (auth.getUser);
//   * a SERVICE-ROLE client → U8's `AtomicAcceptanceRpcClient` and U9A's
//     `InvitationValidationRpcClient` (RPC only).
//
// It returns ONLY those narrow adapters — never a broad/raw Supabase client. It
// performs NO transport (no serverless entrypoint, no HTTP request/response
// handling, no CORS/origin policy, no HTTP status), NO authentication logic, NO
// token parsing/hashing, NO validation or acceptance orchestration, NO response
// mapping, and NO database schema logic. Provider-failure mapping stays with
// U6/U8/U9A; this factory does not catch or reinterpret RPC/auth errors, and it
// logs nothing.
//
// SECURITY (Round-4 T23-D33): the caller bearer is NEVER installed on either
// client (U6 passes it per-call to auth.getUser); the service-role client never
// receives the bearer; both clients disable session persistence, auto-refresh and
// URL detection; no global caller-authorization header is added. Configuration is passed
// explicitly — this module reads NO environment variables (the Round-4 env names
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are owned by the
// later U9C entrypoint). Invalid configuration fails closed with a generic error
// that never echoes a URL or key value.
// ============================================================================

import { createClient } from "@supabase/supabase-js";
import type {
  SupabaseAuthGetUserResult,
  SupabaseAuthVerificationClient,
} from "./supabase-acceptance-auth.ts";
import type { AtomicAcceptanceRpcClient } from "./supabase-atomic-invitation-acceptance.ts";
import type { InvitationValidationRpcClient } from "./supabase-invitation-validation.ts";

// ── Configuration ───────────────────────────────────────────────────────────

/** Explicit, server-supplied configuration. No values are read from the env here. */
export interface ProductionDependencyConfig {
  readonly supabaseUrl: string;
  readonly supabaseAnonKey: string;
  readonly supabaseServiceRoleKey: string;
}

/** The narrow adapter bundle returned to production composition (no raw client). */
export interface SupabaseProductionDependencies {
  readonly authenticationVerifier: SupabaseAuthVerificationClient;
  readonly atomicAcceptanceRpcClient: AtomicAcceptanceRpcClient;
  readonly invitationValidationRpcClient: InvitationValidationRpcClient;
}

// ── Minimal constructed-client contracts (kept out of the public surface) ────

/** The frozen server-side client auth options (persistence/refresh/URL off). */
interface ServerClientAuthOptions {
  readonly auth: {
    readonly persistSession: false;
    readonly autoRefreshToken: false;
    readonly detectSessionInUrl: false;
  };
}

/** The smallest slice of a constructed Supabase client this factory consumes. */
interface MinimalSupabaseClient {
  readonly auth: {
    getUser(accessToken: string): Promise<SupabaseAuthGetUserResult>;
  };
  rpc(
    functionName: string,
    parameters: object,
  ): PromiseLike<{ readonly data: unknown; readonly error: unknown }>;
}

/**
 * Injected client-construction factory (defaults to the real SDK). Isolating
 * construction behind this seam keeps the module testable without any network or
 * live SDK behaviour.
 */
export type SupabaseClientFactory = (
  supabaseUrl: string,
  supabaseKey: string,
  options: ServerClientAuthOptions,
) => MinimalSupabaseClient;

const SERVER_CLIENT_AUTH_OPTIONS: ServerClientAuthOptions = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
};

/**
 * Default factory: constructs a real Supabase client and narrows it to the slice
 * this module uses. The single boundary cast adapts the broad SDK type to the
 * minimal contract (the standard "adapt the real client" seam U6/U8/U9A document);
 * it is not an `any` escape.
 */
const defaultSupabaseClientFactory: SupabaseClientFactory = (supabaseUrl, supabaseKey, options) =>
  createClient(supabaseUrl, supabaseKey, options) as unknown as MinimalSupabaseClient;

// ── Configuration validation (fail-closed, no value echo) ────────────────────

/** True only for a non-empty, non-whitespace-only string. */
function isNonBlankString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

/** True only for a non-blank http/https URL. */
function isHttpUrl(value: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  return parsed.protocol === "https:" || parsed.protocol === "http:";
}

/**
 * Validate configuration fail-closed. Throws a generic error that NEVER contains
 * the URL or either key value. (Round-4: no secret appears in errors or logs.)
 */
function assertValidConfig(config: ProductionDependencyConfig): void {
  const urlOk = isNonBlankString(config.supabaseUrl) && isHttpUrl(config.supabaseUrl);
  const anonOk = isNonBlankString(config.supabaseAnonKey);
  const serviceOk = isNonBlankString(config.supabaseServiceRoleKey);
  if (!urlOk || !anonOk || !serviceOk) {
    throw new Error("invalid Supabase production configuration");
  }
}

// ── Narrow RPC adaptation ────────────────────────────────────────────────────

/**
 * Build a single privileged RPC caller that awaits the SDK builder and returns
 * only `{ data, error }`. Two separately-typed adapter objects (U8, U9A) share
 * it; neither interface is altered.
 */
function makePrivilegedRpcCaller(
  client: MinimalSupabaseClient,
): (functionName: string, parameters: object) => Promise<{ data: unknown; error: unknown }> {
  return async (functionName: string, parameters: object) => {
    const { data, error } = await client.rpc(functionName, parameters);
    return { data, error };
  };
}

// ── Factory ───────────────────────────────────────────────────────────────

/**
 * Construct the production dependency bundle. Builds exactly two clients — an
 * anon-key client used ONLY for `auth.getUser`, and a service-role client used
 * ONLY for RPC — and returns the three narrow adapters. The caller bearer is
 * never installed on either client; no environment is read; nothing is logged.
 */
export function createSupabaseProductionDependencies(
  config: ProductionDependencyConfig,
  createSupabaseClient: SupabaseClientFactory = defaultSupabaseClientFactory,
): SupabaseProductionDependencies {
  assertValidConfig(config);

  const authClient = createSupabaseClient(
    config.supabaseUrl,
    config.supabaseAnonKey,
    SERVER_CLIENT_AUTH_OPTIONS,
  );
  const privilegedClient = createSupabaseClient(
    config.supabaseUrl,
    config.supabaseServiceRoleKey,
    SERVER_CLIENT_AUTH_OPTIONS,
  );

  const authenticationVerifier: SupabaseAuthVerificationClient = {
    auth: {
      getUser: (accessToken: string): Promise<SupabaseAuthGetUserResult> =>
        authClient.auth.getUser(accessToken),
    },
  };

  const callPrivilegedRpc = makePrivilegedRpcCaller(privilegedClient);

  const atomicAcceptanceRpcClient: AtomicAcceptanceRpcClient = {
    rpc: (functionName, parameters) => callPrivilegedRpc(functionName, parameters),
  };
  const invitationValidationRpcClient: InvitationValidationRpcClient = {
    rpc: (functionName, parameters) => callPrivilegedRpc(functionName, parameters),
  };

  return {
    authenticationVerifier,
    atomicAcceptanceRpcClient,
    invitationValidationRpcClient,
  };
}
