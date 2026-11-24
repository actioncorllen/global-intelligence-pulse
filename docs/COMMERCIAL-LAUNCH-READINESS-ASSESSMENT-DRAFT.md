# Strateloq Technologies — Commercial Launch-Readiness Assessment

**STATUS: DRAFT — PROPOSED, NOT FORMALLY ACCEPTED.** Target launch 18 Dec 2026. Prepared 2026-11-24 (BE295 / Addendum 70) under founder authorisation of 2026-11-24.

This is a **separate** assessment. The `LIVE MASTER — GOLD` tracker tab and **all historical acceptance checkboxes are preserved and unchanged** — **formal GOLD remains 11/22**. Nothing here is marked accepted; the revised criteria stay PROPOSED pending explicit founder approval. No source-rights flags, security settings, customer-release gates or provider budgets were altered; no paid API calls, supplier purchases or n8n executions were made in producing it.

**State legend:** `ACCEPTED` (formal GOLD, launch-ready as is) · `READY FOR FOUNDER TEST` (ready for the founder's acceptance review/test) · `BLOCKED — EXTERNAL` (open, waiting on a third-party right/decision) · `DEFERRED` (optional, out of launch unless founder opts in) · `RETIRED FROM LAUNCH` (removed from launch scope; original criterion stays not accepted). `RETIRED` and `DEFERRED` are **never** counted as accepted GOLD.

## Part 1 — 22-unit assessment

| ID | Unit | GOLD box | Proposed launch treatment | Existing evidence | Remaining action | Proposed state |
|----|------|----------|---------------------------|-------------------|------------------|----------------|
| GPD.01 | Provider & rights matrix | FALSE | Mandatory, no reduction | BE239–242/284–285; legal-review package; Kalodata/DataForSEO/CJ analyse-cleared; display gated | Google-upstream counsel decision + founder release flip; TikTok-embed & Meta each need own permission | **BLOCKED — EXTERNAL** |
| GPD.02 | Exact identity + image lock | TRUE | Keep | BE228/233 (10/10 identity; PAL; attribution) | None | **ACCEPTED** |
| GPD.03 | Fresh acquisition & provenance | TRUE | Keep | BE228 (fresh cohort, provenance, freshness) | None | **ACCEPTED** |
| GPD.04 | 18-country isolated discovery | TRUE | Keep (must remain intact) | BE209–210 (18/18 routing; 6-country proof) | None | **ACCEPTED** |
| GPD.05 | Licensed sales/GMV OR UNKNOWN | TRUE | Keep | BE223–224 (labels, UNKNOWN, export/API) | None | **ACCEPTED** |
| GPD.06 | Country search demand/growth | FALSE | Keep evidence standard | Real US DataForSEO search-demand; GLOBAL_SAFE; DISPLAY_PENDING_RIGHTS (BE288–292) | GPD.01 DataForSEO display clarification (customer display) | **BLOCKED — EXTERNAL** |
| GPD.07 | Search & social demand | FALSE | Keep evidence standard; TikTok official embeds OK | TikTok official-embed product videos built (BE294, REFERENCE_ONLY, EXACT/RELATED labels); search leg = GPD.06; social sources uncleared (BE293) | GPD.01 (search display) + a social analysis/display licence OR Kalodata creator/video ingest. **Video embed ≠ social-demand** | **BLOCKED — EXTERNAL** |
| GPD.08 | Country seller counts | FALSE | Keep evidence standard | Mechanism proven on stored eBay obs (BE228); seller identity honest-UNKNOWN | GPD.01 + marketplace (eBay) data rights | **BLOCKED — EXTERNAL** |
| GPD.09 | Authorised advertiser observations | FALSE | Preserve standard; respect optional nature | 440 Meta obs stored + rights-withholding verified (BE293/294); display gated | Meta Ad Library analysis+display licence — **or** explicit founder deferral | **BLOCKED — EXTERNAL** (deferral available on founder approval) |
| GPD.10 | Competitor offers / local pricing | FALSE | Keep evidence standard | Pricing mechanism proven on stored obs (BE228); customer price UNKNOWN | GPD.01 + marketplace price display rights | **BLOCKED — EXTERNAL** |
| GPD.11 | Country saturation & maturity | FALSE | Keep evidence standard | Independent per-country saturation proven (BE228; GPD.22 benchmark below) | GPD.01 + observed-competition display rights | **BLOCKED — EXTERNAL** |
| GPD.12 | Explainable score & confidence | TRUE | Keep | BE227 (suppression data-wide; sighted) | None | **ACCEPTED** |
| GPD.13 | Rank/filter/compare | TRUE | Keep | BE227 (DESC NULLS LAST; range filters; selftest) | None | **ACCEPTED** |
| GPD.14 | Explainable TEST/WATCH/AVOID/INSUFFICIENT | TRUE | Keep | BE228 (explainable decisions; sighted) | None | **ACCEPTED** |
| GPD.15 | Rights-safe research detail | TRUE | Keep | BE228 (drawer; REFERENCE_ONLY; PAL) | None (image-display licence rides GPD.01, recorded on GPD.02) | **ACCEPTED** |
| GPD.16 | Exact-SKU supplier/stock/variants | FALSE | **Optional for research** (supplier-independent discovery); exact verification separate | CX.02 engineering complete + published; Supplier Unknown 4-state selftest 5/5; **0/1,317 supplier rows carry a URL → no VERIFIED_SUPPLIER exists**; FE suite 1,074 tests | Founder approval of the revised research-scope criterion. Exact-supplier leg stays external (CJ URL/identity) | **READY FOR FOUNDER TEST** (research-scope) · exact-supplier leg **BLOCKED — EXTERNAL** |
| GPD.17 | Landed cost / shipping / margin | FALSE | **Retired from launch** (customer assesses economics) | Founder decision 2026-11-23; economics return UNKNOWN; no verified-profit claims | None for launch; original criterion stays not accepted | **RETIRED FROM LAUNCH** |
| GPD.18 | Save/retrieve/shortlist/monitor | TRUE | Keep | BE223–224 (change detection, dedupe, ACL; founder alert sighting) | None | **ACCEPTED** |
| GPD.19 | Decision→research→Save/Monitor continuity | FALSE | **Remove supplier-link dependency** for research continuity | Backend chain verified (BE256); 4-state supplier 5/5; supplier-independent; store/ads founder-gated | **One authenticated production-browser test** (Part 2) + founder acceptance | **READY FOR FOUNDER TEST** |
| GPD.20 | Research card & workspace UX | TRUE | Keep | BE225 (security, rights-revoke, mobile) | None | **ACCEPTED** |
| GPD.21 | Country comparison / change-of-verdict | TRUE | Keep | BE226 (genuine ≥2-market comparison; suppression) | None | **ACCEPTED** |
| GPD.22 | Multi-market benchmark | FALSE | **Replace 60-cell with bounded 5-market / 10-cell** (GPD.04 intact) | **Bounded benchmark executed — Part 3** (10/10 cells genuinely evaluated; genuine same-product cross-market comparison; isolation proven) | Founder review/acceptance of the revised criterion + results. Original 60-cell stays not accepted | **READY FOR FOUNDER TEST** (results ready) |

**Tally (proposed, advisory — not a GOLD count):** ACCEPTED 11 · READY FOR FOUNDER TEST 3 (GPD.16/19/22) · RETIRED 1 (GPD.17) · BLOCKED — EXTERNAL 7 (GPD.01/06/07/08/09/10/11). **Formal GOLD unchanged at 11/22.**

## Part 2 — GPD.19 authenticated production-browser acceptance test

**Backend substrate already verified (reuse-first, by connected tools, $0):**
- Supplier Unknown 4-state engine — `fn_product_supplier_state_selftest` **5/5**: `A_VERIFIED_SUPPLIER` only with a genuine URL **and** verified identity; `B_POTENTIAL_NOT_VERIFIED`; `C_SUPPLIER_UNKNOWN`; `D_NOT_YET_VERIFIED`; no-persist.
- The candidate product (RGBIC Wall-Wash Floor Lamp `207dbaa8`, US): **0 bound supplier resolutions → Supplier Unknown**; **0 of 1,317 supplier rows carry a URL system-wide → "View Supplier" is unavailable everywhere and not required** for the journey.
- Discovery/research/save/monitor are supplier-independent (CX.02 engineering complete + published); save/retrieve/monitor mechanics accepted (GPD.18/BE224: change detection, dedupe, ACL); member store/ads are founder-gated (`commercial_cleared=false`); research drawer emits no unlicensed images and honest UNKNOWN.
- Bonus to sight: the lamp now carries a REFERENCE_ONLY TikTok reference video (BE294), labelled RELATED_CATEGORY.

**Steps that genuinely require your authenticated production session** (nothing here is runnable from the build session — no tenant login, and `strateloq.com`/`lovable.app` are not reachable from the container):
1. Sign in to production as an eligible customer tenant.
2. Open Product Discovery/Explorer; find an eligible **generic** product (e.g., the RGBIC Wall-Wash Floor Lamp, US). Confirm it is discoverable **without any supplier**.
3. On the Product Card, confirm supplier status reads **"Supplier Unknown"** (not Verified), an *independently source this product* affordance is shown, and **no active "View Supplier" link** exists.
4. Open the product research/detail drawer; confirm research details render (identity, evidence labels, UNKNOWN where absent), the Product Videos section behaves correctly (official TikTok embed / "Watch on TikTok" + RELATED label), **no CJ/unlicensed images**, and sales/revenue honest.
5. **Save** the product — confirm it saves with **no verified supplier required**.
6. Navigate away, then **retrieve** it from the saved/shortlist view — confirm it persists under your tenant.
7. Confirm **monitoring** is active for the saved product (appears in monitoring; change-detection on).
8. Confirm selected **country** + evidence labels are correct, and there is **no member Store/Ads creation** control.
9. Capture screenshots of: the Supplier Unknown card, research drawer, saved item, monitoring entry.

**Evidence to capture for the record:** the four screenshots + a note confirming no "View Supplier" link and no store/ads controls. On your confirmation, GPD.19 can be put to acceptance (I will not mark it accepted without that).

## Part 3 — GPD.22 bounded benchmark (executed)

**Design:** 2 independently-resolved **generic** (GENERIC_OK) products × 5 supported markets = **10 product-market cells**. Reuse-first, stored evidence only, **$0, 0 provider calls**. Tenant `7c8ddf9d`. No invented metrics; no category-for-exact substitution; UNKNOWN is **not** treated as verified demand.

**Products:** `efca8b59` *over door shoe organizer*; `e453eed4` *kids nightlight projector*. **Markets:** GB, DE, IE, IT, US.

| Product | Market | Classification | Qual/Present families | Saturation | Genuine observations (source · dates) | Rights/visibility | Price |
|---------|--------|----------------|-----------------------|------------|----------------------------------------|-------------------|-------|
| kids nightlight projector | GB | EMERGING | 1/1 | OBSERVED_VERY_HIGH | SEARCH_DEMAND (DataForSEO, 19 Sep); eBay 148 (5–29 Sep); Meta 29 (19–29 Sep) | eBay/Meta NOT_AUTHORISED (withheld); search display pending GPD.01 | UNKNOWN |
| kids nightlight projector | DE | EMERGING | 1/1 | OBSERVED_HIGH | SEARCH_DEMAND (DataForSEO, 7 Oct); eBay 3; Meta 47 (19 Sep–7 Oct) | eBay/Meta NOT_AUTHORISED | UNKNOWN |
| kids nightlight projector | US | EMERGING | 1/1 | OBSERVED_VERY_HIGH | SEARCH_DEMAND (DataForSEO, 7 Oct); eBay 56 (7 Oct) | eBay NOT_AUTHORISED; search display pending GPD.01 | UNKNOWN |
| kids nightlight projector | IE | DISCOVERED | 0/0 | UNKNOWN | none (no IE observations) | — | UNKNOWN |
| kids nightlight projector | IT | DISCOVERED | 0/0 | UNKNOWN | none (no IT observations) | — | UNKNOWN |
| over door shoe organizer | DE | EMERGING | 1/1 | UNKNOWN | SEARCH_DEMAND (DataForSEO, 20 Sep); eBay 35; Meta 17 (20 Sep) | eBay/Meta NOT_AUTHORISED | UNKNOWN |
| over door shoe organizer | IE | EMERGING | 1/1 | OBSERVED_VERY_HIGH | SEARCH_DEMAND (DataForSEO, 7 Oct); eBay 63; Meta 5 (7 Oct) | eBay/Meta NOT_AUTHORISED | UNKNOWN |
| over door shoe organizer | IT | EMERGING | 1/1 | OBSERVED_LOW | SEARCH_DEMAND (DataForSEO, 7 Oct); eBay 1; Meta 17 (7 Oct) | eBay/Meta NOT_AUTHORISED | UNKNOWN |
| over door shoe organizer | GB | DISCOVERED | 0/0 | OBSERVED_VERY_HIGH | eBay 8 (5 Sep) only — no authorised qualifying family | eBay NOT_AUTHORISED | UNKNOWN |
| over door shoe organizer | US | DISCOVERED | 0/0 | UNKNOWN | none (no US observations) | — | UNKNOWN |

**Completed: 10/10 cells genuinely evaluated** — 6 EMERGING (a genuine market-specific qualifying family — authorised DataForSEO SEARCH_DEMAND), 4 honest DISCOVERED/UNKNOWN (insufficient authorised market evidence). No cell fabricated; thin cells reported as UNKNOWN, not padded.

**Genuine same-product cross-market comparison:** *kids nightlight projector* evaluated independently in **GB vs US vs DE** — same resolved product, independent per-market observations and verdicts, with **different saturation** (GB & US OBSERVED_VERY_HIGH; DE OBSERVED_HIGH) and DataForSEO search demand dated per market; IE/IT independently UNKNOWN. A second independent divergence: *over door shoe organizer* is **DISCOVERED in GB** (eBay-only, no qualifying family) yet **EMERGING in IE/IT/DE** — verdicts not copied across markets.

**Country-isolation result (pass):** every cell used only its own market's observations. Proof: *over door shoe organizer* **US = DISCOVERED/UNKNOWN** despite rich GB/DE/IE/IT evidence; *kids nightlight projector* **IE & IT = DISCOVERED/UNKNOWN** despite GB/DE/US evidence — no seller counts, prices, demand or classifications leaked across borders. Prices UNKNOWN in all cells (no cleared local-price display); marketplace/advertiser sources consistently NOT_AUTHORISED (withheld from customer display, used only as internal saturation context).

**Honest limitation:** this bounded benchmark genuinely demonstrates per-market evaluation, independent verdicts, honest UNKNOWN and country isolation. It does **not** turn the blocked customer-DISPLAY of seller/price/advertiser evidence (GPD.08/10/11/09) green — those remain gated on GPD.01. The original 60-cell GPD.22 criterion stays **NOT ACCEPTED**.

## Part 4 — Recommendation (for founder acceptance review)

**Ready for your acceptance review now:**
- **GPD.16 (research-scope / supplier-independent):** engineering complete, published, Supplier Unknown truthful, no fabricated supplier anywhere — ready for your criterion acceptance. Keep exact-supplier verification as a separate optional capability.
- **GPD.19:** backend verified; ready pending the single authenticated browser test in Part 2 + your confirmation.
- **GPD.22 (bounded):** benchmark executed 10/10 with genuine evidence, a real cross-market comparison and isolation — ready for your review of the revised criterion + results.
- **GPD.17:** retired from launch scope (not accepted) — confirm the retirement.

**Critical path for 18 Dec:** **GPD.01 is the single gating dependency.** Its counsel decision + your release flip is what unblocks customer display for GPD.06/07/08/10/11 (and the search leg) — these stay BLOCKED — EXTERNAL on rights, not engineering. **GPD.09** is a keep-or-defer decision (needs a Meta licence to operate, else explicit deferral).

**Unchanged / preserved:** formal GOLD 11/22; all historical checkboxes; security, source-rights, release gates and provider budgets; GPD.01 mandatory; DataForSEO DISPLAY_PENDING_RIGHTS; Supplier Unknown / generic-only / PAL / 18-country isolation. Nothing in this assessment has been accepted or applied.
