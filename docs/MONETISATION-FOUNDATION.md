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
