# Product Discovery — Growth Accuracy Release Gate (2026-11-09)

Final release gate for the growth-metric correction. Supersedes the "convert FastMoss raw ÷100" approach in
the earlier quality-corrections pass: the FastMoss scale could **not** be verified authoritatively, so FastMoss
growth is now surfaced as **UNVERIFIED** (never converted), and only Kalodata revenue growth is shown as a
figure. Nothing deployed or published — both artifacts are prepared, tested, and gated on founder approval.
No paid provider calls; no discovery wave; no provider-budget / advertising / billing / signup changes.

---

## 1. Verified FastMoss growth-unit finding

**Question:** what are the real units of `sales_growth_rate`, `units_sold_growth_rate`, and
`revenue_growth_rate`, and can the FastMoss value be converted to a percentage with confidence?

**What was inspected (not assumed):**
- **Adapter / storage path.** There is **no FastMoss n8n workflow** doing arithmetic. The `fastmoss-discovery`
  edge function (endpoints `/product/v1/rank/newListed | topSelling | mostPromoted`) and
  `fn_fastmoss_ingest_candidates_ml` store the provider's `units_sold_growth_rate` **raw**, with no transform.
  In the Explorer it surfaces as `commerce_signals.sales_growth_rate`. So the stored number is exactly what
  FastMoss returned — any unit interpretation is ours, not theirs.
- **Authoritative docs.** `developers.fastmoss.com` lists the field as "Sales volume growth rate" with **no
  documented unit** and a large-integer sample (`59335`). The vendor overview elsewhere shows
  `growth_rate 212 → "+212%"` (implying the value **is already** a direct percentage, contradicting ÷100).
- **Live data.** The DE distribution includes negatives beyond −100 (e.g. `−3906`). A raw percentage cannot go
  below −100% (a quantity cannot fall by more than 100%), which **rules out** reading the value as a plain %.
  But ÷100 (→ −39.06%) and "already a %" (212 → 212%) **cannot both be true** of the same field.

**Verdict — UNVERIFIABLE.** The evidence is internally contradictory: the docs sample and the vendor "+212%"
example point one way, the live negatives point another, and the field carries no authoritative unit. There is
**no honest single scale**. Per the founder's explicit instruction ("if it cannot be verified, display growth
as UNVERIFIED or UNKNOWN rather than converting it speculatively; never fabricate percentages"), FastMoss
growth is **never converted to a number**. The raw value is retained in the payload for transparency only.

**Kalodata `revenue_growth_rate` — VERIFIED.** Genuine percentage, live DE range ≈ −96…+746, no values below
−100. It is **revenue** growth over Kalodata's 7-day window (not sales-units). Shown as a figure, explicitly
labelled as such.

The three fields are **not interchangeable**: `revenue_growth_rate` (Kalodata, revenue %, verified) ≠
`sales_growth_rate`/`units_sold_growth_rate` (FastMoss, units, unverifiable unit).

---

## 2. Final source-specific growth presentation rules

| Source | Field | Status | How it is shown |
|---|---|---|---|
| **Kalodata** | `revenue_growth_rate` → `growth_pct` (basis `revenue_7d_pct`) | **VERIFIED** | Label **"Revenue growth"**; figure `+48.3%` / `−39.1%`; at **≥1000%** a multiplier `527×` (= 1 + pct/100, unambiguous for growth); sub-line + tooltip **"7-day · Kalodata · <freshness>"**. |
| **FastMoss** | `sales_growth_rate` (units, raw) | **UNVERIFIED** | Label **"Growth"**; **"Rising · unverified"** / **"Declining · unverified"** (sign only) or **"Unverified"**. **Never** a %, ×, K%/m%, or any number. |
| **Either** | no verified figure / unknown status | **UNKNOWN** | Card renders **nothing** for growth (never "0%"); table shows "—". |

Hard guarantees enforced in code + tests:
- A number appears **only** when the server marks growth `VERIFIED` **and** basis is `revenue_7d_pct` **and**
  the value is a finite % ≥ −100. Any mismatch fails closed to UNKNOWN (no overstated "verified" claim).
- The raw FastMoss rate is **never** turned into a figure anywhere — card, table, **and** the product-detail
  drawer's "Sales growth" lane (previously showed e.g. "4,826%"; now direction + "unverified").
- No large genuine value is concealed: big verified Kalodata growth shows as a clear multiplier, not hidden.
- No `K%` / `m%` compaction anywhere (that produced the "571.17K% / 5.26m%" artefact).

---

## 3. Final mig_339 migration and rollback

- **`supabase/migrations/mig_339_product_explorer_growth_normalization.sql`** — `fn_product_explorer` → **v3**
  (`pulse_product_explorer_v3`), additive. Emits per item: `growth_pct` (Kalodata `revenue_growth_rate` only,
  NULL for FastMoss), `growth_basis` (`revenue_7d_pct` | `units_sold_growth_rate_unverified` | null),
  `growth_status` (`VERIFIED` | `UNVERIFIED` | null), `image_status` (`DISPLAY` | `NONE`), plus `observed_at`,
  `source`, and the raw rates kept for transparency. Numeric growth min/max filter applies to `growth_pct`
  only; `HIGH_GROWTH` facet is **sign-based** (positive growth, from whichever source) so it never implies a
  FastMoss magnitude. Invariants include `growth_never_fabricated:true`, `fastmoss_growth_unverified:true`;
  a `growth_units` object documents both bases. No engine / tier / label / identity change; tenant + market
  scoping and Product Asset Lock unchanged.
- **`supabase/migrations/mig_339_ROLLBACK.sql`** — restores v2 (`pulse_product_explorer_v2`) exactly.
- **Backend test: 6/6 PASS** (transactional, production untouched): total still **29**; all 20 Kalodata items
  `growth_status=VERIFIED` with `growth_pct=revenue_growth_rate`; FastMoss items that have a rate →
  `UNVERIFIED` + `growth_pct` NULL + raw retained; FastMoss items without a rate → no status; **no** FastMoss
  item ever carries `growth_pct`; `HIGH_GROWTH` sign-based; `image_status=NONE` for the 10 new Kalodata
  products. Committed `62ca15e` (revised from the superseded ÷100 version `e169774`). **NOT deployed.**

---

## 4. Final Lovable preview commit

- Preview commit **`312fce3`** on project `12db6c84…` — **preview only, NOT published**. Changes:
  - `src/lib/business-discovery/product-explorer-contract.ts`: replaced `explorerGrowthPct` (÷100 fallback)
    with `explorerGrowth()` → discriminated union `{verified, pct}` | `{unverified, direction}` | null;
    added `growthFreshness()` (relative `observed_at`); decoder reads `growth_status`; `formatGrowthPct`
    restricted to verified values only.
  - `src/components/business-discovery/product-explorer.tsx`: `growthDisplay()` drives card + table —
    "Revenue growth" + figure + "7-day · Kalodata · <fresh>" for verified; "… · unverified" / "Unverified"
    for FastMoss; nothing for unknown.
  - `src/components/business-discovery/product-intelligence.tsx`: drawer "Sales growth" lane now direction +
    "unverified", never a raw %.
  - `AGENTS.md` / `roadmap.md` updated to the verified-only rule.
- **Preserved from the prior preview** (re-asserted by the component tests): honest **"No image"** for
  `image_status=NONE` (no `<img>`, no substitute); **Newly discovered** vs **Newly listed** strictly from
  `opportunity_class` (marketplace `NEW_LISTED` lane chip hidden); **Research pending** with suppressed score;
  click opens **that product's own** detail preserving country; **24 + 5 = 29** reachable with page controls;
  Product Asset Lock intact.

---

## 5. Test evidence

- **Backend (source-aware growth):** 6/6 PASS, transactional, against the exact v3 function body (above).
- **Frontend full suite:** **540 tests across 74 files PASS** (+3 vs. prior), including the existing Product
  Explorer regression tests and the two rewritten growth files
  (`product-explorer-growth.test.ts`, `product-explorer-corrections.test.tsx`). The component test asserts
  `527×` (no K%/m%), `Revenue growth`, `7-day · Kalodata · 2 days ago`, FastMoss "Rising · unverified" with
  the card body matching **no** `%|×|5711|571170`, "Newly listed" from `opportunity_class`, "No image" with no
  `<img>`, "Research pending" with no score, and 24 + 5 pagination.
- **Typecheck:** clean. **Lint:** no errors (13 pre-existing react-refresh warnings, unrelated).
- **Preview build:** `build OK`.

---

## 6. Unresolved data-provenance limitations

- **FastMoss growth unit remains unknowable** from available evidence; this is now surfaced honestly as
  UNVERIFIED rather than guessed. If FastMoss later publishes an authoritative scale, the fix is a single,
  localized change (set `growth_status='VERIFIED'` + a documented conversion for the FastMoss branch in
  mig_339, and let `explorerGrowth` treat it as verified) — no architecture change.
- **P1 images unchanged:** the 10 new Kalodata products still have **no display-rights-cleared image**
  (Kalodata `product/rank` returns none; the only images present are eBay `MARKETPLACE_PUBLIC_LISTING`,
  `tenant_id=NULL`, rights not established). "No image" stays correct until an authorised supplier (e.g. CJ)
  binding with display rights is sourced — a separate, approved step.
- **Freshness depends on `observed_at`:** when a signal has no `observed_at`, the "· <freshness>" suffix is
  omitted (fails closed); the "Revenue growth · 7-day · Kalodata" label still shows.
- **Signed-in visual acceptance is a founder-device step:** container egress to the live app is auth-gated
  (403), so the on-device render of the DE Explorer was **not** verified here — tests used sample data shaped
  like the v3 server output.

---

## 7. Controlled deployment sequence (gated on founder approval)

1. **Apply `mig_339`** (additive; drops nothing; data/history preserved). Verify `fn_product_explorer` reports
   `contract = pulse_product_explorer_v3` and total DE = 29 with Kalodata growth VERIFIED / FastMoss NULL.
2. **Publish the Lovable preview `312fce3`** to production (after on-device visual confirmation).
3. **Order: `mig_339` first, then publish.** The frontend fails closed without the new fields (shows nothing
   for growth rather than a wrong figure), so the order is low-risk; deploying the backend first means
   `growth_status`/`growth_pct`/`image_status` exist before the UI reads them.
4. **Rollback:** `mig_339_ROLLBACK.sql` restores v2; un-publish/revert the Lovable commit. No provider budgets,
   advertising, billing, or signup are touched at any step.

**Status: READY — prepared, tested, and consistent across backend and frontend; awaiting founder approval to
deploy mig_339 and publish the preview.**
