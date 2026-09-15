// ============================================================================
// Pulse — Tasks 2–3 · Founder-only Issuable-Applications Read Edge Function
// ----------------------------------------------------------------------------
// Production entrypoint for the READ-ONLY, founder-only list of issuable founding
// applications. COMPOSITION ROOT ONLY: loads server-side configuration from the
// Deno environment, constructs the anon (auth verifier) and service-role (read)
// clients, wires the frozen auth port + the SAME server-held founder authorization
// used by issue-invitation + the reviewed origin policy into the reviewed list
// transport handler, and registers it with Deno.serve. It contains NO business
// logic beyond the read-only eligibility projection.
//
// SECURITY: verify_jwt is disabled at the platform gate because the handler
// authenticates itself (Supabase getUser) and authorizes via the server-held
// FOUNDER_ISSUER_AUTH_USER_IDS allowlist. The service-role key is used ONLY to
// construct the server-side read client here; it is never installed on the auth
// client, never returned, never logged. This function performs NO mutation. The
// list is informational only — issue_invitation remains the atomic authority.
// ============================================================================

import { createClient } from "@supabase/supabase-js";
import { createInvitationAcceptanceOriginPolicy } from "./lib/invitation-acceptance-origin-policy.ts";
import {
  createSupabaseAcceptanceAuthenticationPort,
  type SupabaseAuthVerificationClient,
} from "./lib/supabase-acceptance-auth.ts";
import { createFounderAuthorization } from "./lib/invitation-issuance-edge.ts";
import {
  createListIssuableApplicationsHandler,
  type IssuableApplication,
  type IssuableApplicationsQueryPort,
} from "./lib/list-issuable-applications-edge.ts";

// ── Environment loading (owned only by this entrypoint) ─────────────────────

const ENVIRONMENT_CONFIG_ERROR = "invalid issuable-applications environment configuration";

function readRequiredEnv(rawValue: string | undefined): string {
  if (typeof rawValue !== "string" || rawValue.trim().length === 0) {
    throw new Error(ENVIRONMENT_CONFIG_ERROR);
  }
  return rawValue;
}

const supabaseUrl = readRequiredEnv(Deno.env.get("SUPABASE_URL"));
const supabaseAnonKey = readRequiredEnv(Deno.env.get("SUPABASE_ANON_KEY"));
const supabaseServiceRoleKey = readRequiredEnv(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
// Reuse the issuance origin authority (same founder browser origin as issue-invitation).
const allowedOrigins = readRequiredEnv(Deno.env.get("ISSUANCE_ALLOWED_ORIGINS"));
// Reuse the SAME server-held founder allowlist as issue-invitation.
const founderAuthUserIds = readRequiredEnv(Deno.env.get("FOUNDER_ISSUER_AUTH_USER_IDS"));

// ── Composition (constructed once at module startup) ────────────────────────

const SERVER_CLIENT_OPTIONS = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
} as const;

// Anon client used ONLY to verify the caller bearer via auth.getUser.
const anonClient = createClient(supabaseUrl, supabaseAnonKey, SERVER_CLIENT_OPTIONS);
// Service-role client used ONLY server-side for the read-only eligibility query.
const serviceClient = createClient(supabaseUrl, supabaseServiceRoleKey, SERVER_CLIENT_OPTIONS);

const originPolicy = createInvitationAcceptanceOriginPolicy({
  allowedOrigins,
  allowMissingOrigin: false,
});

// Adapt the real anon client's getUser to the narrow verifier contract (the
// documented "adapt the real client" boundary cast — not an `any` escape).
const authenticationVerifier = {
  auth: { getUser: (accessToken: string) => anonClient.auth.getUser(accessToken) },
} as unknown as SupabaseAuthVerificationClient;
const authenticationPort = createSupabaseAcceptanceAuthenticationPort(authenticationVerifier);

const founderAuthorization = createFounderAuthorization({ founderAuthUserIds });

// Read-only eligibility query (service-role). Eligibility MIRRORS the frozen
// issue_invitation success gates: an application with EXACTLY ONE business profile,
// that profile UNOWNED (user_id IS NULL), and NO member bound to it. Only the
// minimal founder projection is returned; no mutation, no lock. Any read error
// collapses to a fail-closed operational result (no provider detail surfaced).
const query: IssuableApplicationsQueryPort = {
  list: async () => {
    try {
      const [apps, profiles, members] = await Promise.all([
        serviceClient
          .from("founding_applications")
          .select("id, first_name, last_name, company, work_email, created_at"),
        serviceClient.from("business_profiles").select("application_id, user_id"),
        serviceClient.from("member").select("application_ref"),
      ]);
      if (apps.error || profiles.error || members.error) return { ok: false };

      const profileCount = new Map<string, number>();
      const unowned = new Set<string>();
      for (const p of (profiles.data ?? []) as Array<{
        application_id: string;
        user_id: string | null;
      }>) {
        profileCount.set(p.application_id, (profileCount.get(p.application_id) ?? 0) + 1);
        if (p.user_id === null) unowned.add(p.application_id);
      }
      const memberApps = new Set<string>();
      for (const m of (members.data ?? []) as Array<{ application_ref: string }>) {
        memberApps.add(m.application_ref);
      }

      const applications: IssuableApplication[] = [];
      for (const a of (apps.data ?? []) as Array<{
        id: string;
        first_name: string;
        last_name: string;
        company: string | null;
        work_email: string;
        created_at: string;
      }>) {
        if (profileCount.get(a.id) === 1 && unowned.has(a.id) && !memberApps.has(a.id)) {
          applications.push({
            application_ref: a.id,
            first_name: a.first_name,
            last_name: a.last_name,
            company: a.company,
            work_email: a.work_email,
            created_at: a.created_at,
          });
        }
      }
      // Deterministic presentation order (created_at DESC, then application_ref ASC as a
      // stable tie-breaker). Ordering is presentation ONLY — it confers no authority and
      // never drives selection; the founder must still explicitly choose a candidate.
      applications.sort((x, y) =>
        x.created_at !== y.created_at
          ? x.created_at < y.created_at
            ? 1
            : -1
          : x.application_ref < y.application_ref
            ? -1
            : x.application_ref > y.application_ref
              ? 1
              : 0,
      );
      return { ok: true, applications };
    } catch {
      return { ok: false };
    }
  },
};

const handler = createListIssuableApplicationsHandler({
  auth: authenticationPort,
  authorization: founderAuthorization,
  query,
  originPolicy,
});

// ── Server registration ─────────────────────────────────────────────────────

Deno.serve((request) => handler(request));
