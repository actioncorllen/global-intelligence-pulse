# BE348 — Product Discovery gap closeout: inspect → fix → verify → reconcile (18 Dec launch)

**Executed:** 2026-11-28 · **Authority:** founder "PRODUCT DISCOVERY GAP CLOSEOUT — move from comparison to completion; close every actionable launch gap; fix reproducible technical defects now; record what is externally/legally blocked; return one reconciliation table." **Live inspect/fix/verify pass (read-only probes on production). NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid provider calls; no GPD.07 social release/activation; historical GOLD 11/22 unchanged; fail-closed rights / Product Asset Lock / country-tenant isolation / founder-only privileges preserved; no fabricated data; 5-market bounded proof not re-expanded.**

**Outcome: every Product Discovery engine within current access was inspected live and found CORRECT and fail-closed — no reproducible technical defect to fix.** Per "do not rebuild accepted components," no change was made to the working engines. The remaining launch gaps are external rights/legal, founder-approval, or 7 Dec credits — recorded precisely below, each as its own gate so nothing is held behind another.

---

## Live verification performed this session (production, read-only)
1. **Discovery quality** — 263 genuine products, **0 duplicate product_identity groups**, 0 null/short titles, 263/263 identified, all observed <90 days; genuine opportunity decisions across **12/18 markets**; verdicts honestly conservative (all WATCH while competition/demand display is gated). No missing/duplicate/wrong-variant/identity/category defect.
2. **Market-intelligence engines (GPD.06/08/10/11)** — probed `fn_product_competitor_evidence` + `fn_product_ad_evidence` live for e453 across GB/DE/US:
   - Competitor: GB excluded **148** uncleared eBay offers, DE **3**, US **56** — each market its own (no cross-country bleed); `distinct_sellers_known=false` (offers never equated to sellers); price UNKNOWN (not 0); all 8 invariants true (reference_only, unknown_not_zero, tenant_market_scoped, server_owned_auth_uid, single_currency_range, offers_not_equated_to_sellers, verbatim_seller_list_withheld, only_analyse_cleared_sources_in_decision).
   - Advertiser (GPD.09): Meta/TikTok `coverage_state=NOT_AUTHORISED`, `observed_advertisers`/`observed_creatives` null, `ADVERTISING_COMPETITION_UNKNOWN`, advertiser≠seller; the raw Meta ads are **not leaked** (withheld, retained for audit).
3. **Access control** — the discovery/research readers are owner-scoped (`server_owned_auth_uid` invariant), **not** founder-gated → open to entitled subscribers; creative generation/asset/import/store/campaign are founder-only (BE346 `mig_382` selftest 8/8). No accidental mis-gate.
4. **Billing/entitlement engine** — `fn_billing_selftest` **36/36 all-pass** (successful-payment activation, failed/past-due, idempotent + out-of-order webhooks, cancellation/expiry, cross-tenant isolation, comp preservation, unknown-plan reject, no-auth-binding reject, cancel-at-period-end, list-plans no-price-leak, reconcile missed renewal, checkout/portal require-auth, permission matrix, definer+search_path locked). (An initial 34/36 was a self-inflicted artifact of injecting a session JWT before the selftest controlled its own auth context; re-run clean = 36/36.)

---

## RECONCILIATION TABLE (Product-Discovery launch units)
Columns: GPD | criterion (original/revised) | previous status | defect found | fix/evidence this cycle | tests/verification | new status | remaining external dependency.

| GPD | Criterion | Previous | Defect found | Fix / evidence (BE348) | Tests / verification | New status | Remaining dependency |
|---|---|---|---|---|---|---|---|
| GPD.02 | Exact identity + image lock | ACCEPTED | none | — | identity resolved live (e453 IDENTITY_RESOLVED) | **DONE** (unchanged) | — |
| GPD.03 | Fresh acquisition + provenance | ACCEPTED | none | — | 263 products, 0 dup identity, <90d | **DONE** (unchanged) | — |
| GPD.04 | 18-country isolated discovery | ACCEPTED | none | — | 12 markets live; per-market competitor exclusions distinct (148 GB/3 DE/56 US) | **DONE** (unchanged; 5-market bounded proof) | — |
| GPD.05 | Sales/GMV or explicit UNKNOWN | ACCEPTED | none | — | honest UNKNOWN preserved | **DONE** (unchanged) | — |
| GPD.06 | Country search demand (or UNKNOWN) | OPEN (shared gap) | none (engine correct) | DataForSEO search-demand retrievable + withheld DISPLAY_PENDING_RIGHTS (verified prior; unchanged) | GB/DE/US readers fail-closed, UNKNOWN preserved | **ENGINEERING DONE; EXTERNAL RIGHTS BLOCKED** | GPD.01 DataForSEO display clearance (legal) + founder release flip |
| GPD.08 | Country seller counts | OPEN | none | competitor engine excludes uncleared eBay; distinct sellers UNKNOWN when identity absent | 148/3/56 excluded; `distinct_sellers_known=false` | **ENGINEERING DONE; EXTERNAL RIGHTS BLOCKED** | GPD.01 (eBay/source display rights) + founder flip |
| GPD.10 | Observed competitor retailers/offers + local pricing | OPEN | none | aggregate price range + exact-match, single-currency; verbatim seller list withheld | 8 invariants true; positive control (DataForSEO GB) shows 5 offers £33.99–39.99 | **ENGINEERING DONE; EXTERNAL RIGHTS BLOCKED** | GPD.01 price/source display rights + founder flip |
| GPD.11 | Country-specific saturation/maturity | OPEN | none | saturation derives only from analyse-cleared sources; UNKNOWN otherwise | competitor selftest rights-aware (6/6, prior); live UNKNOWN | **ENGINEERING DONE; EXTERNAL RIGHTS BLOCKED** | GPD.01 + founder flip |
| GPD.09 | Optional authorised advertiser observations | OPEN | none | safe fallback verified: Meta/TikTok NOT_AUTHORISED, advertisers null, no raw leak, advertiser≠seller | live GB/US withholding; no fabricated advertisers | **FALLBACK DONE; ORIGINAL CRITERION NOT ACCEPTED; FOUNDER APPROVAL REQUIRED** | founder scope decision (launch with advertiser=UNKNOWN fallback) OR Meta Ad Library licence |
| GPD.07 | Search + social demand | OPEN | none | search leg = GPD.06; social leg has no authorised path (withheld NOT_AUTHORISED) | live withholding | **EXTERNAL RIGHTS BLOCKED (social) — NOT required for launch; do NOT activate** | Reddit/TikTok licence or Kalodata creator/video ingest (future) |
| GPD.12 | Opportunity score + confidence | ACCEPTED | none | — | conservative WATCH; suppression honest | **DONE** (unchanged) | — |
| GPD.13 | Rank / filter / compare | ACCEPTED | none | — | — | **DONE** (unchanged) | — |
| GPD.14 | Explainable TEST/WATCH/AVOID/INSUFFICIENT | ACCEPTED | none | — | truthful verdicts | **DONE** (unchanged) | — |
| GPD.15 | Rights-safe research detail | ACCEPTED | none | — | rights-enforcement boundary live | **DONE** (unchanged) | — |
| GPD.16 | Exact-SKU supplier/stock/variants | ACCEPTED (revised: supplier-independent) | none | supplier moved to future scope; discovery works without it | Supplier Unknown 4-state; fail-closed | **ACCEPTED (revised) — supplier = future** | (future) authoritative supplier identity |
| GPD.17 | Landed cost / margin | SCOPE-REMOVED (customer responsibility) | n/a | UNKNOWN preserved; no invented economics | — | **OUT OF LAUNCH SCOPE** | (future) |
| GPD.18 | Save / retrieve / shortlist / monitor | ACCEPTED | none | — | change detection + ACL (prior) | **DONE** (unchanged) | — |
| GPD.19 | Decision → research → Save/Monitor continuity | ACCEPTED (revised scope) | none | supplier-independent continuity; 6/6 signed-in (prior) | — | **ACCEPTED (revised)** | — |
| GPD.20 | Research card + workspace UX | ACCEPTED | none | production UI authenticated 7/7 (BE319) | — | **DONE** (unchanged) | — |
| GPD.21 | Country comparison / change-of-verdict | ACCEPTED | none | — | — | **DONE** (unchanged) | — |
| GPD.22 | 10×6 GOLD benchmark | ACCEPTED (revised: 2×5 bounded isolation proof) | none | superseded by the founder-approved bounded proof | — | **ACCEPTED (revised); 60-cell NOT reinstated** | — |
| Billing/entitlement (commercial) | Subscription entitlement + Stripe lifecycle | engine present | none (36/36) | engine green incl. auth, cross-tenant, webhook idempotency | `fn_billing_selftest` 36/36; plans list empty (config) | **ENGINE DONE; ACTIVATION EXTERNAL/FOUNDER** | 9 Dec CRO/Revenue registration → live Stripe keys/tax/plans; founder go-live |
| Access control (security) | Founder-only creative; subscriber discovery open | BE346 prepared | none | creative founder-gated; discovery readers subscriber-open (owner-scoped) | mig_382 selftest 8/8; live reader invariants | **SERVER-SIDE DONE (prepared); FE nav removal awaits credits** | 7 Dec Lovable credits (frontend); controlled deploy |

## Execution-package outcomes
- **EP1 (market intelligence):** engines correct + fail-closed on live genuine data; no defect. Display of competition/demand/pricing/saturation = EXTERNAL RIGHTS BLOCKED on GPD.01 (legal) + founder release flip. Aggregate processing is NOT treated as legal clearance (uncleared sources stay excluded).
- **EP2 (GPD.09):** safe fallback verified (no unauthorised Meta data, UNKNOWN/NOT_OBSERVED where absent, no fabricated advertisers/volumes, no GPD.07 activation). Original GPD.09 NOT marked accepted. **Prepared founder decision (below).**
- **EP3 (discovery quality):** 10-item bounded test passes on genuine products within the 5-market scope (real/identifiable; category-relevant via generic-only; no dup/wrong variant; country-local; sources+dates visible; demand/competition supported-or-UNKNOWN; truthful explanation; save/compare/monitor; independent suitability investigation; no winning/profit claim). 60-cell benchmark NOT reinstated.
- **EP4 (security/access):** server-side verified — creative founder-only, discovery/research/comparison/save/monitor subscriber-open. Frontend nav/control removal for subscribers = genuinely Lovable-dependent → reserved for 7 Dec credits.
- **EP5 (commercial):** billing/entitlement engine green (36/36). Activation blocked on 9 Dec CRO/Revenue registration (live Stripe keys, tax config, plan catalogue is currently empty) + legal pages/DR/monitoring sign-off + founder go-live. No paid checkout, no deploy performed.

## Prepared founder decision — GPD.09 (for explicit approval)
> "For the 18 December Product Discovery launch, advertiser observations (GPD.09) are offered as OPTIONAL and are presented as honest UNKNOWN/NOT_OBSERVED, because the only genuine source (Meta Ad Library) is not analysis/display-licensed. No advertiser counts or volumes are shown or implied. This is the documented truthful fallback; the original GPD.09 criterion remains NOT ACCEPTED and is satisfied later only by a Meta Ad Library licence. Approve launch with advertiser observations unavailable (fallback), or authorise the Meta licence."

This is **FOUNDER APPROVAL REQUIRED** (a consequential scope decision); it is not recorded as accepted by engineering.

## Remaining launch path (each an independent gate)
- **EXTERNAL RIGHTS / LEGAL:** GPD.01 — counsel sign-off on the one Google-upstream question (or formal adoption of the already-built aggregate presentation) → unlocks GPD.06/08/10/11 display (no code). GPD.09 Meta licence (optional). GPD.07 social = future, not activated.
- **FOUNDER APPROVAL REQUIRED:** GPD.01 release flip (set DATAFORSEO_MERCHANT display_derived_cleared + flip the 5 `customer_source_release` rows); GPD.09 scope decision (above); commercial go-live; controlled deploy of prepared backend/edges; edge-secret provisioning.
- **AWAITING 7 DEC LOVABLE CREDITS:** subscriber role-restriction frontend removal; final member research-journey + mobile sighting.
- **AWAITING 9 DEC CRO/REVENUE REGISTRATION:** live Stripe keys, tax config, plan catalogue, legal pages, billing activation.

## Strict controls — all honoured
Inspect/verify only; no production deployment; 0 paid provider/AI calls; no paid checkout; no GPD.07 release/activation; historical GOLD 11/22 unchanged (revised-scope acceptances are the founder's, on the Launch Acceptance Decisions tab); fail-closed rights / PAL / country-tenant isolation / founder-only privileges preserved; 5-market bounded proof not re-expanded; no fabricated data (all figures from live production reads). No supplier automation / Creative Studio / AI video / website work was continued. Evidence: this report, master-doc Addendum 119, Build Evidence row **BE348**. Next BE id: **BE349**.
