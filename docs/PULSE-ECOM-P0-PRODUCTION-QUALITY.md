# P0 Production-Quality Corrections — consolidated release package (2026-11-09)

Supersedes the prior Product Discovery P0. Work within the existing architecture; no rebuild. Nothing deployed
or published without founder approval; no paid provider calls; no discovery wave; no provider-budget / billing /
advertising / signup changes. Current production baseline: Product Explorer **v4** (mig_340), Lovable **db027f5**,
DE Explorer 29 = 9 DISPLAY / 3 REFERENCE / 17 NONE.

## 1. Desktop Explorer layout (A) — root cause + correction
- **Root cause:** a CSS grid row takes the height of its tallest card; one `aspect-square` image card makes a row
  ~2× taller than the compact research cards, and `items-start` left empty space beneath the shorter cards.
- **Correction (preview `334d843`, smallest durable, sort order preserved):** card gets `h-full`; grid
  `items-start` → `items-stretch`; DISPLAY media `aspect-square` → `aspect-[4/3]` (shrinks the height delta);
  the "Seen…" footer is pinned (`mt-auto`). No reorder, no grouping, pagination unchanged, compact cards keep
  the no-blank-placeholder behaviour. Code-verified; **desktop signed-in visual is a founder-device check**.

## 2. Mobile workspace header (D) — root cause + correction
- **Root cause:** `src/components/layout/dashboard-shell.tsx` used `grid grid-cols-[minmax(0,1fr)_auto]` with a
  `shrink-0` actions wrapper. On a phone the `auto` track gave the two buttons ("Analyse another business",
  "Refresh discovery") their full ~300px, leaving the text column ~40–60px, so the description wrapped almost
  word-by-word and the title truncated. `min-w-0` was present — a column-sizing problem, not a min-width one.
- **Correction (preview `334d843`):** header → `grid grid-cols-1 gap-4 … sm:flex sm:items-end sm:justify-between`;
  h1 `break-words … sm:truncate`; actions wrapper `min-w-0 sm:shrink-0`. On mobile the buttons stack full-width
  under the description, which now wraps in natural lines; desktop unchanged. Fixes **every** page using the
  shared PageHeader. Mobile tabs got `max-w-full snap-x overscroll-x-contain` so they scroll inside their bar and
  never cause whole-page horizontal overflow. Code-verified; **mobile signed-in visual is a founder-device check**.

## 3. Mobile homepage (E) — correction + evidence
- **Correction (preview `334d843`):** inside the existing `@media (max-width:639px)` block in `src/styles.css`,
  hero h1 `clamp(2.75rem,13vw,3.45rem)` → `clamp(2.1rem,9.5vw,2.6rem)` (line-height 1.05), reduced hero top
  padding, tightened `.d3-actions` (gap .5rem, margin-top 1.25rem, button height 2.75rem). Desktop untouched;
  branding, gradient span and CTAs preserved; founding-member access policy unchanged.
- **Evidence (real render, public page):** headline 360px ~34px (was ~46px); measured at 320/360/375/390/430/
  768/1280/1440 — no horizontal scroll at any width (table in the Lovable build report).

## 4. Image-resolution findings + implementation (B)
- Existing resolver (Explorer v4 / mig_340) already resolves per canonical identity in rights-priority order
  (supplier-authorised → provider research reference), surfaces marketplace listings as link-only references
  (never copied), and preserves provenance + display vs commercial rights. **No code change needed.**
- **Coverage (29 DE, live, evidence-based):** 9 authorised display images (FastMoss provider, research-display);
  3 permitted reference links (eBay listing, image never copied); 0 supplier-authorised (CJ) images; 17 none.
- **Verified, not assumed:** the saved Kalodata and FastMoss native signals carry **no image field** — Kalodata's
  responses contain no product image, so Kalodata does **not** guarantee imagery. `product_asset_intelligence`,
  `media_assets` and exact-SKU supplier bindings hold **zero rows** for all 29. → Image availability **cannot be
  improved from existing data**; a richer image for the 20 requires an authorised supplier (CJ) binding with
  display rights — a separate, founder-approved (paid) sourcing step. Until then the compact research card is the
  professional secondary presentation (no wrong-product substitution, no fabrication, no unlicensed copying).

## 5. Refresh Discovery (C) — implementation (prepared, INERT) + 6. existing infra & gaps
- **Existing infrastructure reused:** subscription entitlements (`account_entitlement` + `fn_entitlement_active`);
  external **provider** budgets (`provider_call_budget` + `fn_provider_budget_try_consume` — this is provider
  credits, distinct from customer credits); Kalodata dispatch + pagination cursor (`fn_kalodata_run_discovery`,
  `fn_kalodata_next_page`/`advance_page`); canonical dedup (ingest path).
- **Gap:** there is **no customer-credit (Strateloq credits) model** in the schema — no balance/ledger, no price.
- **Prepared (mig_341, NOT deployed, INERT):** `discovery_credit_ledger` (append-only, RLS read-own),
  `discovery_refresh_request` (unique per tenant+idempotency_key), `discovery_credit_price` (founder config,
  starts EMPTY). Functions (SECURITY DEFINER, `search_path=''`, fail-closed): `fn_discovery_credit_balance`,
  `fn_discovery_refresh_quote` (server-authoritative cost; returns `can_refresh`+reason), `fn_discovery_refresh_reserve`
  (atomic, advisory-lock + unique-index idempotent — double-click safe, no double charge, advances the correct
  Kalodata page), `fn_discovery_refresh_settle` (idempotent; **policy:** full refund on provider failure or zero
  NEW products, else settle). The actual provider call is NOT fired here — it stays gated behind a founder-
  authorised `provider_call_budget` (real spend). **Transactional test PASSED** (production untouched):
  fail-closed with no price → `PRICING_NOT_CONFIGURED`; priced+granted+entitled+budgeted → `can_refresh`;
  reserve 5→4; idempotent replay (no 2nd charge); zero-new → refund 4→5; idempotent settle; ledger
  {GRANT:1, RESERVE:1, REFUND:1}.
- **INERT until the founder decides/activates (nothing invented):**
  - **D1 — pricing:** insert active `discovery_credit_price` rows (credits per refresh, per market).
  - **D2 — credit grant:** how customers receive Strateloq credits (subscription allowance vs purchased packs) —
    who writes GRANT ledger rows (needs a billing decision; may integrate with Stripe).
  - **D3 — refund/settlement policy:** confirm the default (refund on failure/zero-new, else settle) or amend.
  - **D4 — provider authorisation:** a real refresh consumes a `provider_call_budget` = paid Kalodata capacity;
    activating that is the existing founder-gated step (forbidden here).
- **Frontend (next stage, gated):** wire the existing "Refresh Discovery" button to `fn_discovery_refresh_quote`
  → a confirm modal (required credits + balance) → `fn_discovery_refresh_reserve` → dispatch → `…_settle`, with
  the button disabled and showing the quote `reason` until D1–D4 are satisfied. Not built yet (depends on D1–D4).

## 7. Proposed credit cost + actual provider usage evidence
- **Provider usage (evidence):** Kalodata page_size 10 = 1 provider call = 0.1 Kalodata credit (prior verified
  pricing); the cursor advances pages (no page-1 re-buy), enforced by `fn_kalodata_next_page`. Customer-credit
  cost is **not proposed here** — it is founder decision D1 (do not invent). The quote is server-authoritative
  from `discovery_credit_price`.

## 8. Migrations + rollback artifacts
- `mig_341_discovery_credit_refresh.sql` (+ `mig_341_ROLLBACK.sql`) — prepared, tested, **NOT deployed**.
- Already live from the prior release: `mig_340` (Explorer v4) + its rollback.

## 9. Frontend preview commit
- **`334d843`** (A/D/E/F), preview only, **NOT published**. Production remains `db027f5`.

## 10. Full test results
- **Frontend:** 549 tests pass, 0 failed (76 files; 3 updated for new wording/labels); typecheck clean; lint 0
  errors (13 pre-existing warnings); preview build OK.
- **Backend:** mig_341 transactional test PASS (above); Explorer v4 (mig_340) acceptance still green.

## 11. Responsive viewport evidence
- **Public homepage (E):** real render at 320/360/375/390/430/768/1280/1440 — hero scaled, no horizontal scroll.
- **Authenticated workspace (A grid, D header):** not renderable from the container (auth-gated) → **founder-device
  checks** (see §13). Code-verified + unit/component tests pass.

## 12. Production deployment sequence (on approval)
1. A/D/E/F (visual/content): publish Lovable `334d843`. Low-risk, no backend dependency. Rollback: re-publish `db027f5`.
2. C (Refresh Discovery): only after D1–D4. Apply `mig_341`; set `discovery_credit_price`; define credit-grant
   path (D2); authorise provider budgets (D4); then ship the gated frontend wiring; then the button activates.
   Rollback: `mig_341_ROLLBACK.sql` (safe while inert).

## 13. Remaining founder approvals / checks
- **Publish** `334d843` to production (A/D/E/F) — your go.
- **Founder-device visual acceptance** (auth-gated; not possible from the container): desktop Explorer grid at
  1280/1440 (balanced rows, no big gaps); mobile workspace at 320/360/375/390/430 (header stacks, description
  wraps in lines not word-by-word, buttons full-width, tabs scroll without page overflow, no clipped headings).
- **Phase C decisions** D1 (pricing), D2 (credit grant / billing), D3 (refund policy), D4 (provider budgets) —
  required before Refresh Discovery can be deployed or activated.
- **Image coverage blocker (B):** authorised supplier (CJ) image sourcing with display rights for the 20
  imageless DE products — a separate approved (paid) step.
