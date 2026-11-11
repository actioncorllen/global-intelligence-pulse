# MONETISATION FOUNDATION — DEPLOYED INERT (2026-11-10, founder business decision)

mig_354 + mig_354b: founding-member promotion, card-on-file and prepaid research revenue.
EVERY behaviour is gated OFF: `card_enforcement_active=FALSE`, `trial_autogrant_active=FALSE`,
all `wallet_price_point` rows inactive (amounts PROVISIONAL). No entitlement, member, budget
or billing row changed. No payment provider integrated (external dependency).
(Companion to docs/PULSE-ECOM-FOUNDING-MEMBER-ONBOARDING.md, which carries the onboarding
enforcement record through activation.)

## Verified identities (A)
- actioncorllen@gmail.com = auth 7c8ddf9d-172c-4a89-a402-bb7066228b61 / member 4bc6b405-2e6a-4fd0-a0cf-b2c409fd4177 (COMP, READY)
- surpyjabu@gmail.com = auth 83c7e6d2-b15a-479b-ad02-690cbf75c897 / member 57efbe13-c5a5-4464-9999-8c752726813f (COMP, BUSINESS_PROFILE_REQUIRED)
- "suryjabu@gmail.com" = spelling variant, ZERO accounts under it — resolved to surpyjabu; no duplicate created.

## What exists now (all inert)
- `payment_method_registry` — card-on-file SAFE references only (PSP refs, brand, last4, expiry);
  schema has NO column that can hold a PAN/CVV (last4 CHECK = exactly 4 digits); owner-only RLS;
  service-role writes (future verified webhook path). `get_own_payment_methods()` exists but is
  not yet on the PostgREST gate allowlist — added with the card-step activation mig.
- `wallet_price_point` — EUR 5 / 5 cr, EUR 10 / 11 cr, EUR 25 / 30 cr, PROVISIONAL + INACTIVE;
  anon/authenticated can read ACTIVE rows only (currently none). `fn_wallet_credit_purchase`
  (service-only): active-price-gated, idempotent per payment_ref (advisory lock + partial unique
  index `dcl_purchase_idem_uniq`), credits the EXISTING customer ledger
  (`discovery_credit_ledger`, new entry_type PURCHASE — mig_354b). Customer-facing Strateloq
  credits remain fully distinct from internal provider credits/budgets.
- 14-day trial: `fn_grant_founding_member_trial` (service-only) → TRIALING/MANUAL,
  `trial_end = activation + onboarding_policy.trial_days (14)`, `cancel_at_period_end=TRUE`
  (structurally no auto-charge), NON-RESETTABLE (any prior entitlement row refuses re-grant).
  `trg_member_trial_autogrant` fires at member creation (= invitation acceptance, the only
  member-creation path) ONLY while `trial_autogrant_active=TRUE`.
- State machine v3: `CARD_SETUP_REQUIRED` between billing and entitlement, emitted only while
  `enforcement_active AND card_enforcement_active`; flag OFF = byte-identical outputs (proven).
  Trial expiry → `ENTITLEMENT_INACTIVE`: workspace + edges denied, billing/membership/recovery
  allowlist unchanged, credits + data preserved.

## Rolled-back prod test suite: 17/17 PASS
Flag-off parity (md5-identical state outputs for all 5 live members); autogrant-off grants
nothing; trial exactly 14 days at activation; re-grant refused (non-resettable); no-auto-charge
flag set; inactive price point denied; purchase credits 5 / balance 5; webhook replay cannot
double-credit; no-subscription and no-provider-budget research denied (card registration alone
grants nothing); atomic reserve (cost 1 → balance 4) + idempotent replay; CARD_SETUP_REQUIRED
blocks workspace + edges and clears with a card row; trial expiry preserves credits (4) while
blocking; cross-tenant card rows invisible (0); PAN insert rejected by CHECK; 0 PAN/CVV-capable
columns. Zero synthetic residue afterwards; live states, entitlements and flags re-verified.

## Refund policy hook (C)
Settlement vs release stays evidence-based in the existing refresh pipeline
(`fn_discovery_refresh_settle/reconcile/is_refund`): a provider-charged failure settles
(consumes the credit) unless billing evidence shows no charge — unchanged, already live-tested.

## Pricing basis (provisional)
1 credit = 1 Refresh Discovery = 1 Kalodata call = 10 products (page_size 10 = 0.1 Kalodata
provider credit). EUR margin per credit depends on the Kalodata plan actually purchased —
provider cost per 0.1 credit requires founder verification before any price point is activated
(plus PSP fees ~1.5–2.9% + ~EUR 0.25/txn, which punishes EUR 5 top-ups → favour EUR 10/25).

## External dependencies (stop points)
PSP (Stripe) account + API keys (test mode first); hosted SetupIntent/Checkout; a
`stripe-webhook` edge function (signature + idempotency verified server-side) as the ONLY caller
of `fn_wallet_credit_purchase` and card-registry writes; card-step UI in onboarding (Lovable) +
gate-allowlist mig; Kalodata plan cost confirmation; VAT/tax treatment decision.

## Founder approvals required before any production activation
1. Stripe (or chosen PSP) account + credentials (test mode first).
2. Wallet price points + credit quantities + margins → `wallet_price_point.active=true`.
3. Refresh retail price (`discovery_credit_price.active=true`).
4. `trial_autogrant_active=true` (14-day trials at acceptance).
5. `card_enforcement_active=true` (only after card UI + webhook path tested end-to-end in test mode).
6. Migration moment for the two existing COMP members to register cards (no charge; COMP preserved).

---

# P0 PAYMENT INTEGRATION STAGE (2026-11-10 evening) — TEST-MODE READY, INERT

## mig_355 / mig_355b (applied to prod)
Trial autogrant hardened to the invitation-acceptance signature (application_ref +
account_status='active'); verified by code inspection that accept_invitation is the ONLY
INSERT INTO public.member and stamps exactly that signature at successful activation.
PSP webhook event dedupe (psp_webhook_event + fn_psp_webhook_begin/finish; error-outcome
claims are RECLAIMABLE so Stripe retries re-process after transient faults — mig_355b,
3/3 tested); service-only card registration/detach RPCs; get_own_credit_wallet owner read.

## Rolled-back prod suite: 14/14 PASS (+3 reclaim)
Trial at acceptance (exactly 14 d); placeholder insert grants nothing; re-grant refused
with trial_end unchanged (no reset via reinvite); COMP never expires (period NULL) and both
live COMP rows byte-identical before/after; webhook claim/retry idempotent + outcome write;
card register x2 -> one ACTIVE row -> detach -> re-register recovers; duplicate purchase
events single-fund (balance stays 5); wallet balances tenant-isolated (own 5 / other 0,
empty history). Zero residue.

## Stripe edges (deployed; fail-closed; live probes 4/4)
- stripe-card-setup v1 (verify_jwt true): hosted Checkout mode=setup; Stripe customer bound
  server-side to the AUTHENTICATED member (metadata + client_reference_id); customer reuse
  from the registry; NOT onboarding-gated (card setup is itself an onboarding step).
- stripe-wallet-topup v2 (verify_jwt true): onboarding-gated (mig_352); server-side price
  authority (ACTIVE price points only -> INERT today); exact server amounts; quote returned
  for pre-confirmation; return URLs /workspace/billing?topup=... (aligned with the UI).
- stripe-webhook v1 (verify_jwt false; signature-gated): HMAC-SHA256 Stripe-Signature
  verification (5-min tolerance, timing-safe; UNIT-TESTED 7/7 under Deno with a synthetic
  secret: valid / tampered / wrong-secret / stale / missing header / missing v1 / multi-v1);
  event dedupe with reclaim; handles checkout.session.completed (setup -> card registration
  with expand payment_method; payment -> fn_wallet_credit_purchase) and
  payment_method.detached; LIVE events ignored unless STRIPE_LIVE_ALLOWED='true'.
- Live probes: webhook unsigned 424 webhook_not_configured; webhook fake-signature 424;
  card-setup anon 401; topup anon 401. Nothing can process until credentials exist.
- Test-mode-first guard in both checkout edges: a non-sk_test_ key is refused unless
  STRIPE_LIVE_ALLOWED='true' (separate founder approval).

## Lovable payment experience (commit 45fe877, PREVIEW ONLY, not published)
Card onboarding step (server-driven CARD_SETUP_REQUIRED routing; unreachable until the
founder activates card enforcement), /workspace/billing Billing & Credits panel (balance,
history, purchases rendered only from server price_points -> "coming soon" today; server
quote confirmed before redirect), COMP "0 EUR" + trial badges + trial-ended preserved-data
copy. 639 tests / 83 files pass; typecheck + preview build green; no live payment testing.

## Research economics (provisional; NO paid calls made)
Customer operation: 1 credit = 1 Refresh Discovery for ONE country = 1 Kalodata call
(page of 10 products; duplicates suppressed on ingest; never promised as 10 NEW products).
Provider consumption verified earlier: 1 call = 0.1 Kalodata credit.
Let K = EUR cost per Kalodata credit on the founder's actual plan (UNVERIFIED — founder
input needed; do not activate prices before this is known). Provider cost/our credit = K/10.
Stripe EEA card fees ~1.5% + EUR 0.25 per transaction:
  EUR 5 / 5 cr   -> fee 0.325 -> net 4.675  -> net/credit 0.935  -> positive if K < 9.35
  EUR 10 / 11 cr -> fee 0.40  -> net 9.60   -> net/credit 0.873  -> positive if K < 8.73
  EUR 25 / 30 cr -> fee 0.625 -> net 24.375 -> net/credit 0.8125 -> positive if K < 8.13
(Non-EEA cards ~2.5–3.25%+0.25 reduce net ~1–2%.) VAT: if prices are VAT-inclusive (B2C EU),
divide net by (1+rate) first (e.g. DE 19% at the EUR 10 tier: net/credit ~0.734 -> positive
if K < 7.34). VAT treatment decision = founder/accountant input.
Hard spend ceilings unchanged: per-tenant provider_call_budget (atomic, fail-closed) +
reserve-before-call + evidence-based settle/refund; no top-up can bypass them.

## External dependencies (unchanged stop points)
Stripe account + sk_test_ key + whsec_ webhook secret (edge env), webhook endpoint
registration in Stripe (checkout.session.completed, payment_method.detached), Kalodata
plan cost figure, VAT treatment decision.

## Exact next founder authorisation
1. Create the Stripe account; provide TEST-mode keys (STRIPE_SECRET_KEY sk_test_...,
   STRIPE_WEBHOOK_SECRET whsec_...) as Supabase edge secrets -> end-to-end test-mode run.
2. Confirm Kalodata plan cost (K) + VAT treatment -> final price approval ->
   wallet_price_point.active=true.
3. Later, separately: trial_autogrant_active, card_enforcement_active (after the
   test-mode run + Lovable publish), and any live-mode switch (STRIPE_LIVE_ALLOWED).

---

# STRIPE TEST-MODE ACCEPTANCE (2026-11-11) — WEBHOOK VERIFIED LIVE

Founder configured STRIPE_SECRET_KEY (test) + STRIPE_WEBHOOK_SECRET as edge secrets
(values never read or printed by tooling; presence proven by behaviour only).

## Configuration validation (Stage 1) — PASS
- Edges ACTIVE: stripe-webhook (signature-gated, verify_jwt=false), stripe-card-setup,
  stripe-wallet-topup (both verify_jwt=true; anon probes still 401).
- Secret present: unsigned POST now 400 invalid_signature (was 424 webhook_not_configured);
  fake signature 400. Unauthenticated Stripe delivery accepted, signature mandatory.
- Same test sandbox: account acct_1UXq... (IE), key mode test; destination
  .../functions/v1/stripe-webhook enabled with exactly checkout.session.completed +
  payment_method.detached (api_version 2026-10-28.endive, livemode=false). No further
  event subscriptions needed (card registration reads the setup_intent on
  checkout.session.completed; setup_intent.succeeded not required).
- NOTE for founder: the same sandbox carries a second destination
  nlfkwrjmhxbubtlwepwx.supabase.co/.../billing-webhook (subscription events) — presumed
  another project of yours; per-destination secrets, no interference, please confirm.

## Real signed-delivery suite (Stage 2) — PASS (method: temporary zz-stripe-diag edge
function used the configured key INSIDE the edge runtime to attach+detach Stripe's
shared test card on a throwaway customer; Stripe then fired its own signed event;
replays were REAL events fetched from Stripe and signed with the real secret in-runtime;
the diag function was neutralised (410 stub) and its n8n driver archived afterwards)
- Stripe's own delivery landed ~3 s after detach: evt_1UaaAH... payment_method.detached,
  livemode=false, signature verified, outcome card_detached:ok (graceful detached:0 —
  no member card existed). Repeated across two runs (also evt_1UaZuw...).
- Duplicate delivery of the same real event: 200 {duplicate:true}; row unchanged;
  no side effects (dedupe on event id via fn_psp_webhook_begin).
- Tampered signature: 400 invalid_signature. Stale timestamp (t-400 s > 300 s
  tolerance): 400 invalid_signature.
- Unknown-but-real event type (customer.created): 200 ignored; outcome ignored_type.
- End state: payment_method_registry 0 rows, PURCHASE ledger 0 rows, no member/
  entitlement/flag changed; 3 test event rows in psp_webhook_event are the audit trail.
- Edge logs show exactly the expected deliveries (two 200s per run window).

## P0 fix (2026-11-11 ~12:30 UTC): card-setup 502 SESSION_CREATE_FAILED
Founder's live billing test failed at "Add payment card" (502). Root cause CONFIRMED by
in-runtime reproduction (never assumed): on the account's Stripe API version
(2026-10-28.endive) `payment_method_types` is NO LONGER SUPPORTED on Checkout Session
creation (invalid_request_error; methods are Dashboard-managed), and `mode=setup` now
REQUIRES `currency`. Customer creation was unaffected. Fix (smallest durable change):
stripe-card-setup drops payment_method_types and sends currency=eur (v4 deployed);
probe of the exact fixed params returned 200 + hosted checkout.stripe.com URL,
mode=setup, livemode=false, amount_total NULL (nothing chargeable), member binding
echoed. stripe-wallet-topup's params were probed UNCHANGED-OK (200 + URL; v4 adds only
secret-free Stripe-error logging, now in both edges: type/code/param/message, no keys,
no card data). Post-deploy regression: webhook unsigned/fake-sig 400, anon edges 401.
Two orphaned test-mode Stripe customers from the failed attempts remain in the sandbox
(harmless; no card, no charge). Lovable hardening landed as preview commit 0e7f784
(653 tests pass incl. 8 new failure-path tests; typecheck+lint clean): any failed
card-setup/top-up reply, network drop or odd URL -> calm toast; redirect ONLY on
HTTP 200 + status ok + https://checkout.stripe.com/ URL; 403 PRICE_POINT_NOT_ACTIVE
now reads as the calm "not available yet" notice (correct while prices are inactive);
one status-only console.warn. Lovable could not reproduce an app crash even pre-fix:
the founder's "runtime error" overlay was most likely the PREVIEW's own instrumentation
flagging the failed 502 network call (member-facing code already toasted); with the 502
gone and the UI hardened, both layers are covered.

## Embedded-preview hand-off (preview commit 4e1996a; follow-up to the blank pane)
Founder retest inside the Lovable EDITOR pane: card-setup returned 200 with a valid
hosted URL (fix confirmed live), but Stripe's hosted page refuses to display inside an
embedded pane, so the pane went blank. UI change: when the app detects it is framed,
"Add payment card" (billing + onboarding step) and the top-up confirm show a
"Continue to secure Stripe page" button that opens Stripe in a NEW TAB (stays open for
blocked-popup retry; closing re-reads the card/balance or re-checks onboarding). A
normal tab keeps direct navigation. URL guards unchanged (200 + ok +
checkout.stripe.com only). 661 tests pass (8 new), typecheck + lint clean.

## P0 fix (2026-11-11 ~13:05 UTC): return URL pointed at the dead legacy domain
Founder's test-mode card setup SUCCEEDED end to end (webhook evt_1Uab1v...
checkout.session.completed -> card_registered:ok; payment_method_registry has the
Visa ****4242 bound to the founder member; 0 charges; COMP x3 unchanged). The ONLY
failure was the browser landing on https://globalintelligenceactions.com/... (legacy
domain, ERR_SSL_PROTOCOL_ERROR). The webhook never travels through the browser, so
registration was never at risk; the ?card=success param is cosmetic (a card is written
ONLY by the signed webhook, never by a return param).
Root cause: both checkout edges defaulted their return origin to the hardcoded legacy
domain (STRATELOQ_APP_ORIGIN unset or legacy). Fix (smallest safe): removed the legacy
default; added safeReturnOrigin() -> canonical https://strateloq.com, honouring a
client-proposed `origin` ONLY if it is strateloq.com / www.strateloq.com / *.lovable.app
/ *.lovableproject.com (server-side allowlist; NOT an open redirect). Applied to BOTH
stripe-card-setup (v5) and stripe-wallet-topup (v5). Lovable asked to send
origin: window.location.origin so preview tests return to the preview tab.
Verification: local Deno unit test 14/14 (incl. open-redirect vectors: userinfo @ trick,
suffix spoof strateloq.com.attacker.com, lookalike evil-lovable.app, http://, javascript:).
Live end-to-end probe read Stripe's STORED success_url on created sessions:
  no origin     -> https://strateloq.com/workspace/billing?card=success
  legacy domain -> https://strateloq.com/... (rejected)
  lovable preview-> https://id-preview--12db6c84-...lovable.app/... (honoured)
  evil.example  -> https://strateloq.com/... (blocked)
All mode=setup, nothing chargeable. Diag apparatus retired (410) + probe workflows archived.

## Card acceptance FINISHED + return-origin hardened (2026-11-11 ~13:20 UTC)
Card registration accepted as complete: one ACTIVE Visa ****4242 (exp 12/2029) bound to
the founder member (auth 7c8ddf9d...), exactly one registry row, one
checkout.session.completed event, 0 charges, 0 PURCHASE ledger entries, COMP x3 at EUR 0,
flags unchanged (enforcement ON / card_enforcement OFF / trial_autogrant OFF),
0 active prices. No new Checkout Session created to verify this (pure read).

Lovable origin passthrough: commit 3ac1ca1 (preview only, 666 tests pass, typecheck+lint
clean) adds origin: window.location.origin to both edge calls, guarded for SSR.

Return-origin security TIGHTENED (card-setup v6 + wallet-topup v6): replaced the
*.lovable.app / *.lovableproject.com WILDCARD with an EXACT allowlist set
{https://strateloq.com, https://www.strateloq.com,
https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app}; exact,
case-normalised origin match or fall back to production. Unit test 17/17 incl. NEGATIVE
cases (another project's id-preview, some-other-project.lovable.app, this project's
lovableproject.com host, preview suffix-spoof -> all fall back to prod) plus the prior
open-redirect vectors. Live end-to-end (Stripe stored success_url) 6/6:
  no origin / legacy / attacker / other-project preview / lovableproject host -> strateloq.com
  exact Strateloq preview -> honoured.
Diag apparatus retired (410) + probe workflows archived.

## BOUNDED €5 WALLET TEST — EXECUTED (2026-11-11 14:05 UTC, founder-authorised)
Method (true founder-only isolation, no production-wide price, no exposure): a dedicated
code 'WALLET_TEST_FOUNDER_5' was NEVER added to wallet_price_point (so invisible to
get_own_credit_wallet and unpurchasable via the topup edge for everyone); instead a
TEMPORARY founder-only special case in fn_wallet_credit_purchase funded it only for the
founder uid. All real price codes stayed byte-identical.
Pre-payment isolation proof (rolled-back txn, zero residue): founder funds 5; duplicate
payment_ref idempotent; surpyjabu (the OTHER onboarding-complete member) denied
TEST_PRICE_FOUNDER_ONLY; real codes still PRICE_POINT_NOT_ACTIVE; other tenant balance 0.
One Checkout Session (cs_test_a0VFb2Ip...) created server-side, client_reference_id=founder,
livemode=false, €5/5cr. Founder paid test card.
Live results: signed webhook evt_1Uac9Y... checkout.session.completed -> wallet_purchase:ok
(livemode=false); founder funded EXACTLY 5 (one PURCHASE row, payment pi_3Uac9X...); all
other members balance 0 (tenant isolation); duplicate re-delivery of the same signed event
-> 200 {duplicate:true}, balance stayed 5 (dedupe). Reversed with auditable ADJUST -5
(idempotency 'ADJUST:reverse-WALLET_TEST_FOUNDER_5-pi_3Uac9X...'); founder balance back to 0.
Cleanup: fn_wallet_credit_purchase restored to original (special case removed, verified);
zz-wallet-test-session + zz-stripe-diag -> 410; driver workflow archived.
Final state: 0 active prices, 0 test price rows, 0 active budgets, enforcement ON,
card_enforcement OFF, trial_autogrant OFF, COMP x3 at EUR 0 (no billing period), UI preview-only,
no live billing. Next queued build: Kalodata Product Imagery Integration.

## Remaining journeys (need the founder's signed-in device; everything else ready)
- Card registration: preview app -> Workspace -> Billing & Credits -> Add payment card
  -> Stripe-hosted page -> test card 4242 4242 4242 4242 (any future expiry/CVC).
  Then verify: registry row bound to the correct member, no charge, cancel path leaves
  no row. UI = Lovable commit 14f2c3f (preview only, unpublished).
- Wallet top-up: requires a founder-approved timed test boundary (activate one price
  point briefly in test mode, purchase, verify single-funding, deactivate, reverse).
Production flags unchanged: enforcement ON, card enforcement OFF, trial autogrant OFF,
prices inactive, budgets inactive, COMP x3 (2 founding + support demo) intact.
