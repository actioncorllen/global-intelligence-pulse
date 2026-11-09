# P0 Next Execution — final verdicts (2026-11-09)

Continues the P0 release package. Visual results were **rendered and measured** (standalone harness, no auth),
not assumed. Nothing deployed or published. Baseline unchanged: Explorer v4 (mig_340), production frontend
`db027f5`.

## 1. Desktop layout verdict — FIXED (was genuinely unbalanced)
- The earlier `334d843` fix (`h-full` + `items-stretch` + `aspect-[4/3]`) did **not** resolve it: rendering a
  realistic 9 image / 3 reference / 17 no-image grid showed compact cards **stretched with ~170–310px empty
  interiors at 1280px (235–360px at 1440px)**, and tall photos overflowing the 4:3 box (image cards 60–110px
  taller). The founder's concern was correct.
- **Correction (preview `55c8230`):** every card shares one 4:3 top region — a strictly-4:3 image
  (`overflow-hidden` + absolute img) for DISPLAY, and a **styled research panel** (flask icon + "Research view —
  no image yet", soft tint — not an image, not a blank box) for NONE/REFERENCE; titles reserve two lines; the
  reference link sits inside the panel. **Result: uniform rows (404px @1280, 434px @1440), no empty interiors,
  no between-row gaps**; residual ≤40px within a row from the verified-growth caption's extra line. Product
  order, sorting, filtering, canonical identity, pagination and all three card behaviours preserved (verified
  by clicking in the harness). Also fixed a small pre-existing truncation of the FastMoss "Rising · unverified"
  growth label (now wraps). **Verdict: balanced.** Signed-in desktop at your device is the final acceptance.

## 2. Mobile layout verdict — PASS (rendered 320/360/375/390/430)
- Workspace header: description reads as a normal paragraph (5 lines, 4 at 430px) — **no word-by-word column**;
  title not clipped; action buttons ("Analyse another business", "Refresh discovery") stack **full-width** below
  the heading at every width; no overlap; no horizontal page overflow; the tab bar scrolls only within itself.
- (Before the fix, at ≥375px the two buttons sat side-by-side and not full-width — now corrected via the
  dashboard-shell stack + the workspace actions `grid-cols-1 sm:flex`.)
- Homepage hero: unchanged from the verified 334d843 mobile scaling; desktop untouched; founding-member policy
  unchanged.

## 3. Final preview commit
- **`55c8230`** (A desktop grid balance + growth-label wrap, on top of 334d843's D/E/F), preview only,
  **NOT published**. Production remains `db027f5`.

## 4. Tests
- **549 pass / 0 fail** (76 files); typecheck clean; lint 0 errors (6 pre-existing warnings); preview build OK.
  The sample-data render page used for screenshots was removed before commit.

## 5. Refresh Discovery end-to-end design + gaps
- Full design in `docs/PULSE-ECOM-REFRESH-DISCOVERY-DESIGN.md`. Flow: confirm → quote → reserve → provider
  authorisation → execution → canonical dedup → persistence → settlement. **Corrected refund policy** (mig_341
  settle v2, re-tested): refund is driven by whether a chargeable provider call occurred, **not** by new-count —
  a zero-new SUCCESS **settles** (no refund). Explicit outcomes defined for all 8 cases (pre/post-charge failure,
  zero-new, partial, duplicate, concurrent, timeout, cancellation). **Remaining gaps:** dispatch step wiring
  (RESERVED→EXECUTING→settle on edge result), a reconciliation sweep for stuck requests, and the gated frontend
  (quote→confirm modal→reserve→dispatch→settle; button disabled with reason until activated).

## 6. Customer-credit commercial decisions required (founder)
- **D1** credits per refresh, per market (`discovery_credit_price`). **D2** how customers receive credits
  (subscription allowance vs purchased packs; billing integration). **D3** confirm post-charge-failure refund
  default (currently: refund customer, Strateloq absorbs provider cost). **D4** authorise provider budgets per
  market (real provider spend). None invented; all gate activation.

## 7. Controlled release steps — visual fixes (independent, low-risk)
1. Publish Lovable `55c8230` to production (A/D/E/F). No backend dependency. Rollback: re-publish `db027f5`.
2. Founder-device visual acceptance: desktop grid at 1280/1440 (balanced, no gaps/empty interiors); mobile
   workspace at 320/360/375/390/430 (header stacks, paragraph wrap, full-width buttons, no overflow).

## 8. Controlled release steps — credit-based refresh (separate, gated)
1. Founder sets D1–D4.
2. Apply `mig_341` (+ dispatch wiring + reconciliation sweep).
3. Ship the gated Refresh Discovery frontend.
4. Activate provider budgets (D4) — the button then enables. Rollback: `mig_341_ROLLBACK.sql` (safe while inert).

**Release boundary:** the visual corrections (step 7) are fully independent of credit-billing activation (step 8)
and can ship first. mig_341 is NOT deployed until the complete credit model + execution path are approved.
