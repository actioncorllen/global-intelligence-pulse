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
