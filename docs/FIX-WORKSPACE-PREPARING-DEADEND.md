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

## CARD ENFORCEMENT ACTIVATED (2026-11-11, explicit founder approval, TEST mode)
Preflight PASS: project nxaunmyihhjixxxljcqt; enforcement ON; mig_357 applied (discovery not a
gate); invitation/membership/entitlement checks intact; card registry owner-only; stripe-card-setup
v6 + signed webhook functional (founder EUR 0 card registered earlier today); Stripe TEST only
(sk_test_, livemode=false); surpyjabu 0 active cards (billing contact != card); founder 1 active
card; 0 duplicate card rows; COMP x3 at EUR 0; prices + budgets inactive. The onboarding
CardSetupStep (CARD_SETUP_REQUIRED -> hosted Stripe EUR 0 setup, never renders a card field)
exists in the Lovable preview = the accessible approved onboarding route.
Server-side enforcement prepared (mig_358): added get_own_payment_methods to the
fn_pre_request_gate RPC allow-list = the narrow exception so a CARD_SETUP_REQUIRED member can read
their own card status + reach stripe-card-setup (edge, ungated) while ALL workspace data stays
blocked. Both gates enforce the card requirement via fn_onboarding_complete (CARD_SETUP_REQUIRED ->
false -> blocked); not UI-only.
ACTIVATED: UPDATE onboarding_policy SET card_enforcement_active=true. Verified live: founder READY
(card_on_file true); surpyjabu CARD_SETUP_REQUIRED (card_on_file false); incomplete member
BUSINESS_PROFILE_REQUIRED; surpyjabu fn_onboarding_complete=false + fn_edge_onboarding_allowed=false
(server-side blocked from workspace data); COMP x3 EUR 0 unchanged; prices/budgets inactive; no
duplicate card rows; no charge (mode=setup EUR 0); live charging still OFF (sk_test_, STRIPE_LIVE_
ALLOWED unset).
NOT PUBLISHED (safety: payment UI unpublished unless separately authorised): surpyjabu's accessible
card-setup route is the PREVIEW URL (shares the production backend; registering a card there makes
them READY everywhere). Publishing the card-setup UI to production strateloq.com for future members
is a SEPARATE founder publish authorisation.
ROLLBACK (if an actual access regression / a member cannot reach card setup):
UPDATE public.onboarding_policy SET card_enforcement_active=false WHERE id; (one line; restores the
prior state; mig_357/356/358 are independent and stay).
ANDROID ACCEPTANCE: NOT marked complete — pending surpyjabu's own successful test (register the
Stripe TEST card 4242 4242 4242 4242 on the preview URL -> becomes READY -> workspace).

## Frontend polish complete (Lovable preview 12fc3ab, NOT published)
Retired the website-as-requirement/Preparing step (onboarding is now Business -> Billing -> Card
-> Membership -> Workspace); honest "No product research yet — run your first discovery" empty
state for a READY member with no research (no spinner/blank/crash); READY routes straight to
workspace; card onboarding step (CARD_SETUP_REQUIRED) UNCHANGED. 680/680 tests pass; typecheck/
lint/build clean; browser-verified 360px + 1280px, no overflow/errors. Preview-only.

## REAL-CUSTOMER / LIVE-CARD ACCEPTANCE (2026-11-11) — Stripe Live Mode NOT configured (external blocker)
Goal: establish whether surpyjabu (COMP founding member) can complete the SAME production-grade
onboarding a future paying customer would, including registering their OWN genuine card via the
secure Stripe-hosted interface (no charge). Finding + preparation:

LIVE MODE READINESS = NOT AVAILABLE (hard external blocker, verified against the live Stripe API):
- Stripe account (acct, IE): charges_enabled=false, payouts_enabled=false, details_submitted=false
  => the account is NOT activated with Stripe (business/identity verification not submitted).
- Only a TEST secret key (sk_test_) is configured; no sk_live_ key present.
- STRIPE_LIVE_ALLOWED is unset; both webhook endpoints are livemode=false.
=> A genuine LIVE card CANNOT be collected until the founder completes Stripe activation. The webhook
   already ignores livemode events unless STRIPE_LIVE_ALLOWED='true' (separate approval), so no live
   event could be processed even if one arrived.

EXACT FOUNDER ACTIONS to enable genuine live-card collection (all external to this project, in order):
1. Complete Stripe account activation (business details + identity) until details_submitted=true and
   charges_enabled=true in the Stripe Dashboard.
2. Provide the LIVE secret key (sk_live_...) as the STRIPE_SECRET_KEY edge secret (replacing/adding a
   live-keyed function or a live-scoped deployment — NOT a blind swap of the test key; see migration).
3. Create a LIVE-mode webhook endpoint in Stripe pointing at stripe-webhook and set its LIVE signing
   secret as STRIPE_WEBHOOK_SECRET for the live path.
4. Set STRIPE_LIVE_ALLOWED='true' only after 1-3 are verified.
Until all four are done, surpyjabu MUST NOT be asked to enter a real card.

CONTROLLED LIVE-CARD INFRASTRUCTURE PREPARED (mig_359, applied; webhook redeployed) — NOTHING ACTIVE:
- payment_method_registry gains livemode boolean (DEFAULT false). The registry now distinguishes a
  TEST card from a LIVE card. Existing founder sandbox card is correctly livemode=false.
- onboarding_policy gains require_live_card boolean (DEFAULT false). When ON, the card gate counts a
  stored card only if pm.livemode=true => a sandbox test card can NEVER satisfy a live-card requirement.
- fn_psp_card_registered captures p_livemode; stripe-webhook passes event.livemode so real
  registrations record LIVE vs TEST. Idempotent upsert updates livemode on conflict.
- SAFETY (no lockout): require_live_card defaults FALSE, so TODAY nothing changes — the founder's test
  card still satisfies card_enforcement; surpyjabu is still CARD_SETUP_REQUIRED exactly as before.
  Enabling require_live_card is a SEPARATE founder decision that must come AFTER live mode is configured
  AND the member has registered a LIVE card (otherwise they would be locked out).

ROLLED-BACK SIMULATION (zero residue, auto-rollback via RAISE EXCEPTION) proving the separation:
- require_live_card=TRUE + founder's TEST card  -> CARD_SETUP_REQUIRED (would lock out a test-only card:
  confirms the flag must wait for a real live card).
- require_live_card=TRUE + surpyjabu TEST card  -> CARD_SETUP_REQUIRED (sandbox card cannot satisfy live).
- require_live_card=TRUE + surpyjabu LIVE card   -> READY (a genuine live card is accepted).
Verified afterwards: require_live_card=false live; founder card livemode=false; no rows changed.

CARD SETUP CANNOT CHARGE / TOP-UP / SUBSCRIBE (verified): stripe-card-setup is mode=setup (EUR 0, no
PaymentIntent); stripe-wallet-topup requires an ACTIVE wallet price (none active => inert) and is
onboarding-gated; there is NO subscription code anywhere. Registering a card never moves money.

FOUNDING-MEMBER PRIVILEGE vs FUTURE PAYING CUSTOMER:
- Identical flow: invitation -> email verify -> Business name+Industry (website optional) -> billing
  contact -> secure Stripe-hosted card registration -> signed webhook binds customer/payment-method ->
  membership confirmation -> workspace. Same gates, same RLS/tenant isolation, same card enforcement.
- COMP difference ONLY: EUR 0 membership, no subscription charge, no card charge, no auto research-credit
  purchase. No bypass of identity/billing/security and no artificial shortcut to READY.
- A PAID-MEMBERSHIP TRANSACTION PATH IS NOT BUILT OR TESTED in this project. This EUR 0 founder test is
  NOT proof that paid-membership collection works; a paid membership must be explicitly authorised and
  independently verified before any paid entitlement is granted.

SAFE NEXT ACTION for surpyjabu: continue the existing TEST-mode card step if desired (register the
Stripe TEST card on the preview URL -> becomes READY) — this is NOT the genuine-card acceptance. The
genuine live-card test is DEFERRED until the four founder actions above are complete and verified.

## Guardrails preserved
Mandatory onboarding ON; invitation-only; COMP x3 at EUR 0 unchanged; card enforcement ON (TEST mode,
server-side, founder-approved); require_live_card OFF; live Stripe OFF (account not activated);
trial autogrant OFF; wallet prices + provider budgets inactive. Kalodata imagery not started pending
this live-card work being resolved or externally blocked (it is now externally blocked on Stripe
activation).
