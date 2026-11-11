# STRATELOQ — Stripe Live Integration (pilot-scoped live card setup)

Date: 2026-11-11. Status: **PARTIAL** — live Stripe account is activated; the application-side
live integration is PREPARED and INERT, pending founder-side live credentials + a separate approval.
**No live charge, subscription, wallet price, provider budget, payment-UI publish, or global
`require_live_card` was enabled.** €0 card setup only.

## 1. Live account verification (read-only, against the live Stripe API)
Probed via a temporary read-only edge (now retired, HTTP 410). Non-secret readiness only:
- Account `acct_…Uk8C` (IE, EUR): **charges_enabled=true, payouts_enabled=true, details_submitted=true**;
  no `currently_due`/`past_due` requirements; no `disabled_reason`; capabilities card_payments=active,
  transfers=active. → **Account is live-ready.**
- Application credentials: `STRIPE_SECRET_KEY` = **test** key (`sk_test_`); `STRIPE_WEBHOOK_SECRET` =
  present (test); `STRIPE_LIVE_ALLOWED` = **unset**; `STRIPE_MEMBERSHIP_PRICE_ID` = unset.
- → Dashboard visibility is NOT proof of app integration: the app still runs on test credentials.
  The exact missing dependency is the **live key + live webhook secret**, added as NEW secrets.

## 2. Test/live separation (smallest durable change; existing architecture reused)
Dual credentials — the test secrets are NEVER overwritten:
- `STRIPE_SECRET_KEY` (test) + `STRIPE_WEBHOOK_SECRET` (test) — unchanged.
- NEW `STRIPE_SECRET_KEY_LIVE` (sk_live_) + `STRIPE_WEBHOOK_SECRET_LIVE` (live endpoint secret) — founder-set.
- `STRIPE_LIVE_ALLOWED` gate (unchanged default) — the final activation switch.

Edge changes (deployed, INERT until the live secrets + flag exist):
- **stripe-card-setup v8**: picks LIVE for a member ONLY when `STRIPE_LIVE_ALLOWED='true'` AND a
  `sk_live_` key is set AND the member is on the `live_card_pilot` allowlist (mig_361). Otherwise TEST.
  Pilot check fails safe to TEST on any error. Customer reuse is filtered by `livemode` so a test
  customer id can never be used with the live key (or vice versa). Returns `mode:"test"|"live"`.
- **stripe-webhook v4**: verifies the signature against the LIVE secret OR the TEST secret (separate
  endpoints, separate secrets, never mixed); selects the Stripe API key by `event.livemode`; ignores
  live events unless `STRIPE_LIVE_ALLOWED='true'`; fail-closed (424) if NO secret at all. Idempotent
  (fn_psp_webhook_begin) and records `livemode` (mig_359).
- **mig_361 `live_card_pilot`**: service-only allowlist (RLS deny-all, 0 policies). Seeded with the
  approved pilot **surpyjabu** (enabled). The founder is NOT on it (keeps the sandbox card; not routed
  to live). INERT until live credentials + flag exist.

## 3. Current configuration + exact missing dependencies
Present: live-ready account; test key; test webhook secret; dual-mode edges; pilot allowlist.
Missing (founder-side, external): `STRIPE_SECRET_KEY_LIVE`, `STRIPE_WEBHOOK_SECRET_LIVE`, a LIVE
webhook endpoint in Stripe, and (final, separate approval) `STRIPE_LIVE_ALLOWED='true'`.

## 4. Backend changes implemented this stage
mig_361 (pilot allowlist + fn_live_card_pilot); stripe-card-setup v8 (dual-key, pilot-scoped,
livemode-correct customer reuse, live-card fail-closed guidance); stripe-webhook v4 (dual-secret
verification + livemode-keyed API key). Temporary read-only probe deployed then retired (410).

## 5. Test/live isolation evidence
- Two independent keys/secrets; test secrets untouched; `mode` is chosen per-member, never global.
- A live event is processed only under `STRIPE_LIVE_ALLOWED`; the Stripe key is chosen by livemode.
- Customer reuse filters on `livemode` → no test/live customer confusion.
- `require_live_card=true` → a test card (livemode=false) does NOT satisfy the gate (rolled-back sim).

## 6. Non-charging test results (all PASS)
| Test | Result |
|---|---|
| Live account selection | account live-ready; app key=test; live_allowed=unset |
| Webhook unsigned event | 400 `invalid_signature` |
| Webhook forged signature | 400 `invalid_signature` (dual-secret still rejects) |
| card-setup no auth header | 401 (gateway) |
| card-setup anon bearer | 401 `UNAUTHENTICATED` (function) |
| Duplicate webhook event | first accepted, replay → `duplicate:true` |
| Test card as live evidence | founder test card under `require_live_card` → CARD_SETUP_REQUIRED |
| No subscription / wallet purchase | 0 PROVIDER entitlements, 0 active wallet prices, 0 active budgets |
| COMP entitlements | COMP × 3 unchanged |
| Founder access | READY, card_on_file=true (unchanged) |
| Stray rows from rejected probes | 0 webhook-event rows; zero residue after rolled-back sims |
No genuine card submitted; no charge; no live transaction.

## 7. Production flags + membership state (preserved)
`enforcement_active=true`, `card_enforcement_active=true`, `require_live_card=false`,
`trial_autogrant=false`; wallet prices + provider budgets inactive; COMP × 3 at €0; payment UI
preview-only. surpyjabu = CARD_SETUP_REQUIRED; founder = READY.

## 8. Exact founder-side steps (Stage 6 — external; never paste secrets into chat)
1. **Live secret key**: Stripe Dashboard → Developers → API keys (**Live mode**) → reveal the secret
   key (`sk_live_…`). In Supabase → Project Settings → Edge Functions → **Secrets**, add a NEW secret
   `STRIPE_SECRET_KEY_LIVE` = that value. Do NOT change `STRIPE_SECRET_KEY`.
2. **Live webhook endpoint**: Stripe Dashboard (**Live mode**) → Developers → Webhooks → Add endpoint →
   URL `https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/stripe-webhook`. Subscribe to
   `checkout.session.completed` and `payment_method.detached` (add the subscription/invoice events
   later only for paid membership). Reveal its **Signing secret** (`whsec_…`) and add it in Supabase
   Edge Function Secrets as a NEW secret `STRIPE_WEBHOOK_SECRET_LIVE`. Keep the existing TEST endpoint
   + `STRIPE_WEBHOOK_SECRET` as they are.
3. **Verify (no secret exposure)**: confirm in the Supabase Secrets list that both new names exist
   (values hidden). A re-run of the read-only readiness check will then report `stripe_key_mode` and
   both webhook secrets present without revealing values.
4. **Do NOT set `STRIPE_LIVE_ALLOWED` yet** — that is the final activation (step below).

## 9. Can a genuine-card pilot safely begin?
Not yet. Everything is prepared and tested, but it stays INERT until steps 1–2 above are done AND a
final activation is explicitly approved. The pilot is already scoped to surpyjabu only.

## 10. Explicit approval required before enabling
Final activation = set `STRIPE_LIVE_ALLOWED='true'` (after a short preflight: confirm the two live
secrets resolve, send one Stripe-signed LIVE test event to confirm the live endpoint verifies). Only
then may surpyjabu be asked to register a genuine card (hosted Stripe Checkout, €0). This requires a
separate founder go-ahead; it is NOT done here.

## Rollback / safety
- `live_card_pilot` is service-only + inert; `TRUNCATE` or `enabled=false` disables the pilot.
- stripe-card-setup/stripe-webhook degrade to TEST with no live secrets; reverting to v7/v3 is safe.
- No change to enforcement, card enforcement, `require_live_card`, RLS, COMP entitlements, prices, or budgets.
