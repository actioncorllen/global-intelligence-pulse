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

## CORRECTION (2026-11-11, founder-approved rules supersede the website approach)
Founder clarified: the initial discovery analysis is NOT a prerequisite for workspace
access; business name+industry mandatory, website OPTIONAL; a registered payment card is the
pre-workspace requirement under the (separately approved) card-enforcement policy. The
website-entry screen from Lovable 83bbc02 was the WRONG fix.
- Backend mig_357 (deployed): removed the `WHEN NOT v_ready THEN 'WORKSPACE_PREPARING'`
  clause from fn_member_onboarding_state. Workspace access is now READY once the approved
  prerequisites pass (email verified, business profile, billing, card ONLY when
  card_enforcement_active, entitlement, membership). Discovery readiness is informational
  only (workspace_ready + workspace_analysis_status retained for the empty-state UI). No
  access_state/enforcement/RLS weakening; no fake discovery data; no forced readiness flag.
- Result: surpyjabu is now access_state=READY under current flags (business+billing+
  membership+COMP; card enforcement OFF so no card required yet). No website, no discovery
  needed. Verified live.
- Card-enforcement rolled-back simulation (zero residue): enforcement OFF -> surpyjabu READY;
  enforcement ON + no card -> CARD_SETUP_REQUIRED; enforcement ON + card -> READY; founder
  (has card) READY; incomplete member -> BUSINESS_PROFILE_REQUIRED. Proves the mandatory-card
  gate works WHEN the founder approves it, without enabling it now.
- surpyjabu payment card status (TASK 2): NO active card (payment_method_registry empty for
  them). Billing CONTACT complete != a stored card.
- €0 card setup (TASK 3): the existing Stripe Checkout Setup edge (mode=setup, EUR 0) + signed
  webhook + CARD_SETUP_REQUIRED state are the mandatory-card path; proven earlier (founder
  registered a EUR 0 card, no charge). Making it mandatory = flip card_enforcement_active=TRUE
  = SEPARATE founder approval (global, affects all members). NOT enabled here.
- Frontend follow-up (Lovable, preview): neutralise the 83bbc02 website-as-requirement (the
  WORKSPACE_PREPARING screen is now unreachable) and ensure an honest empty Product Discovery
  state for members with no research.

## Guardrails preserved
Mandatory onboarding ON; invitation-only; COMP x3 at EUR 0 unchanged; card enforcement OFF;
trial autogrant OFF; wallet prices + provider budgets inactive; live Stripe OFF. Kalodata
imagery not started pending this member's access resolution.
