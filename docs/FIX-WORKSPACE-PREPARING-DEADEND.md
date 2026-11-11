# FIX — WORKSPACE_PREPARING dead-end (founding member blocked at Step 4/5)

Date: 2026-11-11. Reporter: founder (surpyjabu@gmail.com stuck on Android at
"Preparing your workspace / Check again").

## Root cause (traced, not guessed)
The member completed every onboarding INPUT — business profile (name "surpy holdings",
country South Africa), billing, membership confirmation, COMP entitlement — so the EDGE
gate (fn_edge_onboarding_allowed) returns true (this is why earlier reports said
"onboarding-complete"). But WORKSPACE readiness is a separate dependency:
fn_member_onboarding_state sets access_state='WORKSPACE_PREPARING' until
discovery_state.analysis_status='ready'. The member's analysis_status='not_started'
with ZERO discovery_runs, because:
- the discovery is website-first (start-discovery requires a valid website),
- the member has NO website anywhere (business_profiles.website=null; application is a
  direct_invite_backfill with no company/website), and
- the "Preparing / Check again" screen only polls fn_workspace_access — it offered no way
  to supply a website or start the analysis.
=> genuine missing provisioning dependency + UX dead-end. NOT frontend-stuck-but-ready,
NOT RLS/permission denial (the only 42501s were the gate correctly denying INCOMPLETE
members), NOT stale cache, NOT legacy-domain.

Reconciliation: "onboarding-complete" = the edge gate (profiles/billing/membership) which
IS complete; workspace readiness (a completed discovery analysis) is a distinct, unmet step.

## Fix
- Backend (mig_356, deployed + committed 13c734f): additive field
  workspace_analysis_status (none|not_started|queued|ready) on
  fn_member_onboarding_state / fn_workspace_access. ZERO change to any access_state,
  enforcement, RLS, or gate. Regression-verified: founder still READY; every member's
  access_state unchanged.
- Frontend (Lovable preview commit 83bbc02, NOT published): the WORKSPACE_PREPARING screen,
  when workspace_analysis_status is not_started/none, shows a business-website input +
  "Start setup" that calls the existing start-discovery edge; only HTTP 200 ok switches to
  the passive polling view; invalid_website and other failures show calm inline messages
  (no runtime overlay), input preserved for retry. queued → passive "Check again" polling.
  READY routing unchanged. Mobile-first (Android). 691 tests pass; typecheck/lint/build
  clean; 360px + 1280px no overflow. No other onboarding step, gate, or payment UI touched.

## Remaining action (the member's own website — the one external input)
surpyjabu's READY genuinely needs their business website (none exists in the system).
Two paths:
(a) Self-serve: pilot opens the PREVIEW URL
    https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app on Android, signs in,
    enters their website on "Preparing your workspace", taps Start setup; the discovery runs
    (pipeline proven: founder's own analysis completed 2026-11-10), then the workspace opens.
    Preview shares the production backend, so once analysis_status='ready' they are READY on
    the live app too — no publish of the (preview-only) payment UI needed.
(b) Founder relays surpyjabu's website -> provision the discovery server-side idempotently
    (same effect as start-discovery), member becomes READY.
READY was NOT force-set (analysis genuinely not run; forcing it would give an empty workspace).

## Guardrails preserved
Mandatory onboarding ON; invitation-only; COMP x3 at EUR 0 unchanged; card enforcement OFF;
trial autogrant OFF; wallet prices + provider budgets inactive; live Stripe OFF. Kalodata
imagery not started pending this member's access resolution.
