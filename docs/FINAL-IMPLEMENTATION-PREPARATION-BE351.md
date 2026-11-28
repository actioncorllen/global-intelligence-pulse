# BE351 — Final Product Discovery implementation preparation (18 Dec 2026)

**Executed:** 2026-11-28 · **Authority:** founder "BE351 FINAL PRODUCT DISCOVERY IMPLEMENTATION PREPARATION — BE350 accepted as prepared engineering, not production deployment; do not reopen completed audits or repeat accepted backend tests without a regression; continue Product Discovery-only launch preparation. P1 frontend implementation (if Lovable credits unavailable, prepare exact source-level patches + regression tests without a charged build); P2 migration release readiness (validate mig_382→mig_383→mig_384; do not deploy); P3 subscription readiness (verify Discovery-only plan; document remaining requirements; no invent/activate); P4 one concise subscriber acceptance sequence. Record only genuine implementation and verification results; if all remaining executable work is complete, stop and identify the specific external/approval dependency; do not invent further engineering tasks." **NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid provider calls; no Lovable credit spent (no charged build); no live Stripe price / checkout / charge; GPD.09 scope PENDING; Meta data restricted; GPD.07 OFF; GPD.01 legal release BLOCKED; historical GOLD 11/22 unchanged; no supplier/advertisement/website feature expansion; server-side controls not weakened.**

**Outcome: the executable frontend work is produced as exact, applyable source-level patches (the frontend lives only in Lovable and no credit is authorised), and the migration sequence + subscription config are validated from existing evidence. All remaining launch work is now gated on four external/approval dependencies (§5). No new engineering task is invented.**

---

## P1 — Frontend implementation: exact source-level patches (no charged build)

Full patch set: **`docs/BE351-FRONTEND-PATCHES.md`** — exact `OLD`→`NEW` blocks per file plus two new files, applyable verbatim when Lovable credits are available and authorised. Summary of the 8 patches:

1. `src/components/layout/app-sidebar.tsx` — hide **My Store** + **My Campaigns** nav for non-founders (`isFounder` already in scope).
2. `src/components/layout/mobile-nav.tsx` — same, mobile.
3. `src/components/commerce/product-commerce-actions.tsx` — a single founder early-return (placed after every hook) hides **Create Ad / Create Free Store / Add to My Store** and the creative generator for non-founders. This component is entirely an ad/store/creative surface; Discovery cards render it via `concreteProductActionsAllowed={false}`.
4. NEW `src/components/onboarding/founder-guard.tsx` — a `FounderGuard` mirroring `OnboardingGuard`, using the **server-authoritative** founder query (`FOUNDER_STATUS_QUERY_KEY` + `listIssuableApplications`, the same source as `useIsFounder`); fails closed; shows the skeleton while unresolved so a founder is never briefly redirected.
5–7. `workspace_.creative.tsx`, `workspace_.my-campaigns.tsx`, `workspace_.store.tsx` — wrap the page in `<FounderGuard>` (inside the existing `<OnboardingGuard>`): non-founders are redirected to `/workspace`, anonymous to `/auth`.
8. NEW `founder-guard.test.tsx` (founder renders / subscriber → `/workspace` / anonymous → `/auth`) + nav and commerce access-matrix assertions reusing the existing `useIsFounder: () => false` mock pattern.

**No change needed — `product-country-explorer.tsx`:** the "Create ads"/"Build store" buttons live in `HandoffCards`, rendered only when `showNextSteps` is true; the only production caller (`workspace_.product-markets.$productId.tsx:74`, the subscriber Compare-Countries route) already passes `showNextSteps={false}`, and the buttons are inert placeholders. Only the internal dev route renders them. Documented, no launch change.

**Preserved for subscribers** (untouched): Product Discovery (Overview/Products/Competitors/Suppliers), Compare Countries (`/workspace/product-markets/$productId`), Research, Save/Monitoring (Recommendations, Problem-to-Product). **Route guards use authoritative founder permissions** (the founder-only edge). **Server-side controls not weakened** — the patches only hide surfaces and guard routes; the authoritative denial is BE346 `mig_382` + BE350 `mig_383`.

**Status: PREPARED (exact patches), NOT built, NOT deployed.** No Lovable credit was spent. Apply + regression-run when credits are authorised (expected 7 Dec).

---

## P2 — Migration release readiness: `mig_382 → mig_383 → mig_384` (validated, not deployed)

**Dependency ordering (verified):**
- `mig_382` (BE346) defines `fn_is_founder_uid(uuid)` and founder-gates `fn_product_generated_assets` / `fn_commercial_generated_asset_use` / `fn_product_image_import_register`. **Production has `fn_is_founder` but NOT `fn_is_founder_uid`** (verified live this cycle) → `mig_382` must apply first.
- `mig_383` (BE350) adds `public.fn_is_founder_uid` gates to 5 route-read RPCs → **strictly requires `mig_382`** (hard dependency; the gate call fails otherwise).
- `mig_384` (BE350) is **independent** (billing tables only) but is grouped at the end of the sequence.
- The three touch **disjoint** function sets (apart from the shared `fn_is_founder_uid`), so there is no ordering conflict beyond `382 → 383`.

**Compatibility (verified):** `mig_383` uses `CREATE OR REPLACE FUNCTION` on 5 existing functions with **identical signatures, argument names/defaults and return types** (confirmed against the live definitions) → it replaces in place, creates no overloads, changes no return type. Its function bodies reference only objects that already exist in production (the original bodies, plus `public.fn_is_founder_uid` from `mig_382`). `mig_384` `UPDATE`s `billing_plan` and upserts `plan_feature_allowance` on the real PK `(plan_code, feature)` → idempotent, additive. No destructive DDL in either.

**Validation evidence (existing, not re-run beyond this cycle's prepare):** `mig_382` selftest 8/8 (BE346). `mig_383` + `mig_384` validated together this session on a throwaway Postgres 16: **selftest 23/23** (founder passes all 5 gates; subscriber → `founder_only` on all 5; anon → `unauthenticated`/`founder_only`; billing config correct; priced tier unmutated) + `mig_384`'s own end-state assertions pass.

**Rollback (per migration):**
- `mig_384`: delete the 5 `ecommerce_monthly` `plan_feature_allowance` rows and set `billing_plan.provider` back to `NULL` for `ecommerce_monthly` (no price/activation was set).
- `mig_383`: `CREATE OR REPLACE` the 5 functions back to their pre-BE350 bodies (additive gates only; no data or non-gate behaviour changed).
- `mig_382`: per BE346 (replace the 3 RPCs with pre-BE346 bodies; `fn_is_founder_uid` can remain or be dropped once nothing references it — drop only after `mig_383` is rolled back).

**Deploy prerequisites (controlled deploy, separate approval — NOT done here):** apply in order `mig_382 → mig_383 → mig_384`; deploy the BE346 founder-gated edges (`commercial-image-generate`, `commercial-concept-generate`, `commercial-video-generate`) alongside `mig_382`; the wider prepared backlog (`mig_379–mig_381`) applies ahead of `mig_382` in the same controlled deploy by migration number, and none of `mig_382/383/384` depends on them. **No deploy performed.**

---

## P3 — Subscription readiness: Discovery-only plan verified; remaining requirements documented

**Verified (prepared config, `mig_384`):** the launch plan `ecommerce_monthly` ("Product Discovery — Monthly") is correctly represented for a Discovery-only offering — `provider='stripe'`, `active=false`, **no live price** (`provider_price_id_live IS NULL`), and a Discovery-only `plan_feature_allowance` set: `research_actions` / `tracked_products` / `problem_journeys` **enabled**, `product_images=0` (creative is founder-only), `video_metadata=0` (GPD.07 OFF). The priced tiers (`strateloq_starter/growth/pro`) are unmutated. Validated on throwaway Postgres 16 (selftest 23/23 + the migration's own assertions). Live state unchanged this cycle (`billing_event=0`, all plans inactive, `billing_pilot_state.pilot_active=true` → public checkout closed).

**Remaining pricing / Stripe / tax / entitlement configuration requirements (documented, not performed — all founder/registration-gated):**
1. **Pricing decision (founder):** the monthly price for `ecommerce_monthly` (currently `amount_minor` unset/0, no price invented) and confirmation of the `plan_feature_allowance` limit values (BE350 used `strateloq_growth` as a founder-adjustable default; `research_actions=100`, `tracked_products=75`, `problem_journeys=5`).
2. **Live Stripe (9 Dec registration):** create the live Stripe Product + Price for the launch plan; populate `billing_plan.provider_price_id_live`; provision live Stripe keys as edge secrets (no key in chat/repo).
3. **Tax + invoicing (9 Dec, Stripe dashboard):** Stripe Tax for the registered entity; VAT / EU-OSS registration (EUR pricing); invoice numbering/branding. External to the codebase.
4. **Entitlement activation:** once priced + registered, flip the launch plan `active=true` and open public checkout (`billing_pilot_state.pilot_active=false`) — founder go-live. The entitlement **engine** is verified (BE348 `fn_billing_selftest` 36/36); only the plan representation + activation remained, and the representation is now prepared.
5. **Compliance pages (legal):** terms / privacy / refund + cancellation policy pages for the registered entity.

No live subscription, no live price, no checkout opened, no charge. **Do not assume registration or tax/legal clearance is complete before verification.**

---

## P4 — Subscriber acceptance sequence (concise; emphasises what BE350/BE351 changed)

Run once, signed in, after the frontend patches are applied and the migrations deployed (controlled). Reuses BE319 (production UI accepted authenticated 7/7) and BE348 (engines + billing) for parts not changed by BE350/BE351; the two founder-only/entitlement checks are new and must be run.

| # | Check | What "pass" looks like | Reuses / New |
|---|---|---|---|
| 1 | **Genuine product discovery** | A signed-in subscriber sees real discovered products (identified, fresh, deduplicated); no fixture/demo data. | Reuse BE319/BE348 (unchanged). |
| 2 | **Country-specific evidence** | Opening a product shows per-country intelligence with honest UNKNOWN where evidence/display-rights are absent (no fabricated demand/competition). | Reuse BE348 (unchanged; display still gated on GPD.01). |
| 3 | **Product research** | Research detail renders rights-safe; provenance/freshness/confidence shown; no uncleared source data. | Reuse BE319 (unchanged). |
| 4 | **Country comparison** | Compare Countries (`/workspace/product-markets/$productId`) renders side-by-side; no "Create ads/Build store" handoff for the subscriber (`showNextSteps=false`). | Reuse BE348; verify handoff absent. |
| 5 | **Save + Monitoring** | Save a product, see it in the shortlist, monitoring/change-detection works; owner-scoped. | Reuse BE319/BE348 (unchanged). |
| 6 | **Mobile usability** | At 375px the discovery → research → compare → save flow is usable; nav sheet shows no My Store/My Campaigns for the subscriber. | Affected by nav patch — verify. |
| 7 | **Founder-only feature denial (NEW)** | As a subscriber: no My Store/My Campaigns nav, no Create Ad/Create Free Store/Add to My Store on product cards; direct navigation to `/workspace/creative`, `/workspace/my-campaigns`, `/workspace/store` redirects to `/workspace`; a direct API call to the 5 BE350-gated RPCs returns `founder_only`. As the founder: all surfaces present and routes reachable. | **NEW (BE350 `mig_383` + BE351 patches).** |
| 8 | **Entitlement enforcement (NEW)** | The subscriber's plan maps to the Discovery-only allowances (research/tracking/problem-journeys enabled; product-image generation and video metadata = 0); consumable limits counted; no creative/video entitlement. | **NEW (BE350 `mig_384`).** |

Checks 1–6 are largely covered by accepted BE319/BE348 evidence and are re-run only where the nav/handoff change touches them (4, 6). Checks 7–8 are the genuinely new acceptance criteria introduced by BE350/BE351 and are the focus. **Do not re-run the full accepted production UI suite** — only the paths affected by the new changes.

---

## 5. Remaining external / approval dependencies (no further engineering to invent)

All remaining Product Discovery launch work is gated on exactly these — none is an open engineering task:
1. **7 Dec — Lovable credits + authorisation:** apply the P1 patches (`docs/BE351-FRONTEND-PATCHES.md`), run the regression + full suite, run acceptance checks 4/6/7/8.
2. **9 Dec — CRO/Revenue registration:** live Stripe Product/Price for `ecommerce_monthly`, Stripe Tax/VAT/OSS, live keys as edge secrets, then founder plan activation + open checkout (P3 items 1–4).
3. **Founder approval — controlled deploy:** apply `mig_382 → mig_383 → mig_384` (+ the broader prepared backlog) and the founder-gated edges; production is `df1e2f6` until then.
4. **GPD.01 legal sign-off:** unchanged — still blocks customer display of GPD.06/08/10/11 (release flip runbook in BE349 §8).
5. **GPD.09 scope decision:** PENDING — not assumed; advertising observations stay restricted (Meta restricted, GPD.07 OFF).

**Legal + compliance pages** (terms/privacy/refund) and **founder launch sign-off** complete the set. There is no remaining executable engineering task within current access that is not one of the above.

## Strict controls — all honoured
Genuine implementation (exact patches + validated migrations) and verification recorded; preparation not presented as implementation, implementation not presented as production acceptance; no production deployment; no production migration applied; 0 paid provider calls; no Lovable credit spent (no charged build); no live Stripe price / checkout / charge / premature billing activation; GPD.09 PENDING; Meta restricted; GPD.07 OFF; GPD.01 legal release blocked; GOLD 11/22 unchanged; no supplier/advertisement/website feature expansion; Product Discovery / Compare Countries / Research / Save / Monitoring preserved for subscribers; server-side controls strengthened, not weakened. Evidence: this report, `docs/BE351-FRONTEND-PATCHES.md`, master-doc Addendum 122, Build Evidence row **BE351**, repo branch `claude/sharp-archimedes-n0l0tl`. Next BE id: **BE352**. Production remains `df1e2f6` (BE336).
