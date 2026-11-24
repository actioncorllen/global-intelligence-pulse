# GPD.01 — Legal Review Package & Controlled GB-Pilot Release Procedure

**Prepared:** 2026-11-24 · **Status:** PREPARATION ONLY — no rights clearance granted, no release performed, no GOLD checkbox changed (11/22 preserved).
**Owner action required:** a qualified Irish/EU legal interpretation (Part 6) **and** an explicit founder release decision (Part 7). Claude does **not** self-authorise either.

This package consolidates the existing DataForSEO terms, provider correspondence, Google-upstream restrictions and EU/UK database-right questions into one document for counsel, and sets out the reversible, founder-controlled procedure to release the five-product GB pilot **after** clearance. It introduces no new engineering (the rights-safe aggregate presentation is already complete — BE241/BE242/mig_361, Addenda 22 & 60) and makes no provider calls.

---

## 1. Purpose and scope

Strateloq wishes to display, to authenticated paying SaaS customers, a small amount of genuinely-observed competitor intelligence derived from Google-Shopping data acquired **via DataForSEO** (plus an eBay comparable from a separate source). All provider-level permissions needed are in hand **except** one narrow, non-contractual upstream question (Google Shopping / EU–UK database right). This package isolates that question and prepares the pilot so the founder can release reversibly once counsel answers.

In scope: the 5-product GB merchant pilot (`customer_source_release`, all `released=false`). Out of scope: images (blocked everywhere — 0 assets), merchant/product links (never stored or displayed — `observed_product_url` NULL), raw-data resale, creative/ad reuse, and any paid provider call.

---

## 2. The four distinctions counsel must hold separate

| # | Axis | Position | Evidence |
|---|---|---|---|
| A | **DataForSEO permission for derived SaaS use** | **GRANTED (provider level).** DataForSEO confirmed provider-level storage, resale-to-clients and no-attribution for derived data. Recorded as `analyse_cleared=TRUE` for DATAFORSEO / DATAFORSEO_MERCHANT. | DataForSEO reply, Gmail `1a1fb5da11e1432d`, 2026-11-20 23:49 UTC (BE239). Terms capture `docs/legal/captures/DATAFORSEO-TERMS-OF-SERVICE-CAPTURE-2026-11-20.md`. |
| B | **Potential upstream Google restriction** | **OPEN — the sole residual.** No Google contract binds Strateloq (no Google account, no direct API use; data arrives via DataForSEO, comparable via eBay). The residual is **non-contractual**: the EU/UK *sui generis* database right over Google's Shopping compilation, plus DataForSEO §7.1 (data must not compete with/adversely affect the search-engine provider) and §7.2 (indemnity for §7.1 breaches / breaches of search-provider terms or legal rights — risk assigned to Strateloq). | DataForSEO ToS §7.1/§7.2 (verbatim in the capture file). Addendum 21 §2, Addendum 22 Task 5. |
| C | **Verbatim seller identities vs aggregated counts/ranges** | The **only upstream-uncertain display field** was verbatim named marketplace-seller identities shown with exact prices. That field is **no longer displayed anywhere** — the product now shows **aggregate seller COUNT + observed price RANGE + exact-match flag** only; the verbatim compiled-seller list is withheld on every customer-reachable surface. | Aggregate presentation: BE241/BE242 (mig_311) for the FE RPCs; mig_361 closed the last two helper RPCs (`fn_pmc_monday_block`, `fn_pmc_summary`). Selftest `fn_gpd01_aggregate_display_selftest` 5/5; `fn_product_competitor_evidence` `verbatim_seller_list_withheld:true`, `competitors:[]`. |
| D | **Right to ANALYSE source data vs right to DISPLAY derived results commercially** | **Separate flags, separately gated.** `analyse_cleared` (internal analysis / derivation) is TRUE for DataForSEO; `display_derived_cleared` (show derived results to customers) is **FALSE** and is NOT set by Claude. `display_cleared` (raw observations) FALSE. `commercial_redistribution_cleared` FALSE. | `catalogue_source_rights` snapshot, Part 4. The customer RPCs gate display on `analyse_cleared`; the product-card release is additionally gated by `customer_source_release` (closed). |

**Key point for counsel:** A, C and D are resolved/engineered. **B is the only open question**, and C has been engineered specifically to *narrow* B (removing the verbatim-list element that carried the non-trivial database-right risk).

---

## 3. Consolidated source material

### 3.1 DataForSEO Terms of Service (captured 2026-11-20, own stamp "UPDATED: 12 JUNE 2026")
- **§7.1 — Data usage restriction:** SERP data/content obtained through the Service (incl. data from Google, Bing, Yahoo and other providers) *"shall not be used to compete with or adversely affect the business interests of the search engine providers from which such data originates."*
- **§7.2 — Indemnity:** customer indemnifies/defends/holds DataForSEO harmless from claims arising from a §7.1 violation, *"including any use of SERP data that violates the terms of service or legal rights of the search engine providers."*
- §8.1 notes certain DataForSEO services are **resold** (relevant to whether DataForSEO can convey downstream display rights it does not itself hold).
- Full text: `docs/legal/captures/DATAFORSEO-TERMS-OF-SERVICE-CAPTURE-2026-11-20.md`.

### 3.2 Provider correspondence on file (already recorded — not re-fetched)
- **DataForSEO** (Gmail `1a1fb5da11e1432d`, 2026-11-20): provider-level storage / resale-to-clients / no-attribution confirmed → `analyse_cleared=TRUE`. Provider permission is **necessary but not sufficient** for the Google-upstream question (§7.2 keeps upstream compliance on Strateloq).
- **CJ** (Gmail `1a20272d6c7c3448`, 2026-11-22): supplier identity / product-data / SKU / variant / stock display + CJ page links to authenticated SaaS customers PERMITTED (→ CJ `analyse` + `display_derived`); images NOT auto-licensed. *(CJ is a supplier source, not part of the Google-upstream question; included for completeness.)*
- **Kalodata** (Andrew Lin, 2026-11-11): derived/analysed intelligence to paying SaaS customers permitted; Product-Rank main images in authenticated research with attribution; raw resale prohibited; creative/storefront/ad reuse not covered → fully cleared for the research-display use (`display_cleared=TRUE`). *(Kalodata is not part of the Google-upstream question; it is already cleared.)*

### 3.3 Google upstream — why no Google contract binds Strateloq (Addendum 21 §2)
- **Merchant Center Terms** bind entities that *list products via Merchant Center*; Strateloq is not a merchant → not governed.
- **Shopping Content API / developer terms** bind *direct API users*; Strateloq makes no direct Google call → not applied.
- **Google general ToS (automated-access)** binds whoever accesses Google; the extractor is DataForSEO, not Strateloq; Strateloq never assented and has no Google account → **no Google contract in privity with Strateloq**.
- Residual is therefore **non-contractual law**, Part 3.4.

### 3.4 EU/UK database right (Addendum 22 Task 5)
- **Directive 96/9/EC**: Art. 3 copyright (original selection/arrangement); **Art. 7 sui generis right** for a maker with *substantial investment in obtaining, verifying or presenting* contents, against *extraction / re-utilisation of a substantial part*; **Art. 7(5)** bars repeated/systematic extraction of *insubstantial* parts conflicting with normal exploitation; 15-yr term. Retained in UK (Copyright and Rights in Databases Regulations 1997).
- **CJEU authority:** *British Horseracing Board v William Hill (C-203/02)* — protects investment in *obtaining* existing data, not *creating* it (merchant listings are supplied by merchants; Google's investment is arguably in obtaining/verifying/presenting — genuinely uncertain); *Innoweb v Wegener (C-202/12)* — re-utilisation via meta-search.
- **Facts favouring Strateloq:** facts/prices/short titles lack originality; a 5-product pilot is unlikely to be a quantitatively substantial part; aggregation (counts + ranges, verbatim list withheld) further reduces both quantum and the "reproduction of the compiled list" character; no images; no links.
- **Open risk:** aggregation reduces but does not automatically eliminate the right — Art. 7(5) can still bite on *repeated/systematic* insubstantial extraction at SaaS scale; and the BHB obtaining-vs-creating question for Google's Shopping compilation is genuinely unresolved.

---

## 4. Rights register snapshot (`catalogue_source_rights`, live 2026-11-24)

| source_provider | analyse | display | display_derived | cache_images | commercial_redist |
|---|---|---|---|---|---|
| KALODATA | ✅ | ✅ | ✅ | ✅ | ❌ |
| CJ | ✅ | ❌ | ✅ | ❌ | ❌ |
| DATAFORSEO | ✅ | ❌ | ❌ | ❌ | ❌ |
| DATAFORSEO_MERCHANT | ✅ | ❌ | ❌ | ❌ | ❌ |
| EBAY / EBAY_MARKETPLACE | ❌ | ❌ | ❌ | ❌ | ❌ |
| META_AD_LIBRARY | ❌ | ❌ | ❌ | ❌ | ❌ |
| FASTMOSS | ❌ (retired) | ❌ | ❌ | ❌ | ❌ |
| TIKTOK / REDDIT | ❌ | ❌ | ❌ | ❌ | ❌ |

On a positive counsel decision the founder (not Claude) would set **`DATAFORSEO_MERCHANT.display_derived_cleared = TRUE`**. eBay stays uncleared → eBay-sourced observations remain excluded from customer display regardless.

---

## 5. What a released card shows vs withholds (per-field inventory)

| Field | Displayed? | Basis |
|---|---|---|
| Product title | Yes | Fact; low copyright risk |
| Country-local observed price **range** (min–max, single currency) | Yes | Derived intelligence (SUPPORTED) |
| **Aggregate seller count** (distinct, only where every row carries identity, else UNKNOWN) | Yes | Aggregate; verbatim list withheld |
| Observed-offer count + exact-match flag | Yes | Aggregate |
| Derived demand/competition/saturation (where evidence exists) | Yes | Independently calculated |
| Source attribution / provenance / freshness | Yes | Metadata (REFERENCE_ONLY; source labelled) |
| **Verbatim named seller identities** | **No** | Withheld on every customer-reachable surface (the one upstream-uncertain field) |
| Merchant / product links | **No** | `observed_product_url` NULL; never projected |
| Images / media | **No** | 0 assets; TEXT_FALLBACK; blocked at data + projection layers |
| eBay-sourced observations | **No** | EBAY `analyse_cleared=false` → excluded from counts/range/ads |

---

## 6. The precise question for qualified legal interpretation (do NOT self-answer)

> **Does displaying to authenticated, paying SaaS customers a small set of factual Google-Shopping-sourced observations — product titles, observed country-local prices, and only *aggregate* seller counts and observed price ranges (verbatim per-seller identities withheld), with no images and no links — acquired via DataForSEO (not via any direct Google relationship), amount to extraction or re-utilisation of a substantial part of Google's Shopping database under the UK/EU sui generis database right (Directive 96/9/EC Art. 7, including the Art. 7(5) prohibition on repeated/systematic extraction of insubstantial parts at SaaS scale), or otherwise breach any term or legal right binding Strateloq, given (a) Strateloq has no direct Google account, access or assent, (b) DataForSEO §7.1 forbids use that competes with/adversely affects the search-engine provider and §7.2 assigns upstream risk and indemnity to Strateloq, and (c) certain DataForSEO services are resold? And does the aggregate/anonymised presentation reduce any such risk to an acceptable level for a controlled five-product GB pilot and for ongoing SaaS-scale operation?**

Sub-questions: (i) does Google hold an Art. 7 right in the Shopping compilation (BHB obtaining-vs-creating)? (ii) substantial-part / Art. 7(5) at scale? (iii) copyright in titles (expected low)? (iv) §7.2 indemnity exposure and whether DataForSEO's resold-data permission can convey the downstream display right.

---

## 7. The exact founder decision required

After counsel answers Part 6, **one** founder decision authorises release. It has three atomic, individually reversible steps — **none performed here**:

1. **Record the clearance.** Set `DATAFORSEO_MERCHANT.display_derived_cleared = TRUE` in `catalogue_source_rights` (with a dated note citing the counsel opinion). Reversible: set back to FALSE.
2. **Flip the release gate.** Set `customer_source_release.released = TRUE` for the five GB pilot product rows (Part 8 lists them). Reversible: set back to FALSE (immediately removes them from `fn_product_explorer`).
3. **Confirm post-release QA** (Part 8.4) before announcing.

If counsel declines or narrows: keep `display_derived_cleared=FALSE` and the gate closed; the aggregate engineering stands for a future decision. Claude will not perform steps 1–2 without this explicit founder authorisation plus the clearance evidence.

---

## 8. Reversible, founder-controlled GB-pilot release procedure

### 8.1 The five pilot products (`customer_source_release`, `source_store='dataforseo_merchant'`, all `released=false`)
| product_id | title | market | cleared competitor evidence on release |
|---|---|---|---|
| `1def97b0-…` | Projecteur Ciel Étoilé 4K planetarium projector | GB | **5 offers / 5 distinct sellers / £33.99–£39.99 / exact** |
| `d985e5af-…` | Govee Star Light Projector | (GB card) | none cleared (only an eBay US comparable — excluded) → UNKNOWN |
| `0f959bd8-…` | Govee Star Projector Exquisite Aurora | GB | none observed → UNKNOWN |
| `2a714fe9-…` | pococo Starry Sky Projector Galaxy | GB | none observed → UNKNOWN |
| `7dc13291-…` | 2000 ml Cold Brew Iced Coffee Maker | GB | none observed → UNKNOWN |

### 8.2 Pre-release checks (all must hold)
1. **Clearance recorded:** `DATAFORSEO_MERCHANT.display_derived_cleared=TRUE` with a note citing the counsel opinion and date.
2. **Rights register correct:** eBay/Meta/etc. remain uncleared; images remain blocked (`display_cache_images_cleared=FALSE`); `commercial_redistribution_cleared=FALSE`.
3. **No verbatim leak:** `fn_gpd01_aggregate_display_selftest` = ok; `fn_product_competitor_evidence_selftest` = 6/6; no customer-reachable function projects `competitor_identity`/`observed_product_url` (sweep clean as of mig_361).
4. **Image/link safety:** every pilot `image_status=TEXT_FALLBACK`, `cover_url` NULL, 0 `product_image_assets`; `observed_product_url` NULL.
5. **Tenant/country isolation intact:** competitor + stage3b selftests green (cross-tenant rejected; no cross-country reuse).

### 8.3 Release-gate verification (after the flip)
- `fn_product_explorer` now lists the released pilots in GB; each card's competitor block shows the **aggregate** only (Projecteur: 5 sellers / £33.99–£39.99 / exact; the other four: honest UNKNOWN).
- Confirm no card exposes a verbatim seller name, an image or a link.
- Confirm a non-GB market and a foreign tenant still see 0 of these rows.

### 8.4 Post-release customer QA (founder, authenticated)
1. Projecteur GB card shows aggregate seller count + price range + exact flag; **no** named sellers, **no** image, **no** link.
2. The four empty pilots show **"no competitor price evidence — UNKNOWN, not zero"** (not a fabricated 0).
3. Switching country changes/empties the evidence correctly (country isolation).
4. Saved/Monitor/Compare still function; opportunity score behaviour unchanged.

### 8.5 Rollback conditions (any ⇒ set the 5 rows `released=false`, and `display_derived_cleared=false`)
- Any verbatim seller identity, image, or link appears on a customer card.
- Counsel withdraws or narrows the clearance.
- A rights-register or source-gating regression is detected.
- DataForSEO notifies a §7.1 issue.
Rollback is immediate and complete: flipping `released=false` removes the pilots from `fn_product_explorer` on the next query; no customer data is destroyed (observations retained for audit).

---

## 9. Verification: products without cleared observations display UNKNOWN (item 5)

Confirmed against live data and the standing selftest — **no release performed**:
- Of the 5 pilots, **4** have **0 analyse-cleared competitor observations**; `fn_product_competitor_evidence` returns `price_summary.observation = 'UNKNOWN'` (never 0) for such products — asserted by `fn_product_competitor_evidence_selftest` check `FASTMOSS_PRODUCT_EMPTY_HONEST` and by the explorer invariant `unknown_not_zero=true`.
- The one product with evidence (Projecteur) returns `OBSERVED` with the aggregate.
- eBay-only evidence (Govee `d985e5af`) is excluded as uncleared → that card is UNKNOWN, not a false "1 seller".

---

## 10. GPD.06–GPD.11 genuine-evidence assessment (item 6)

Assessed against each gate's **own** acceptance criterion using genuinely-observed, customer-visible (post-release) pilot evidence. **The aggregate competitor-price display working (GPD.10) does not carry the demand, advertiser or saturation gates.** All six remain formally OPEN/FALSE; this states only what *could* be sighted after clearance + release.

| Gate | Own criterion | Genuine pilot evidence? | Can progress after clearance? |
|---|---|---|---|
| **GPD.06** Comparable country search demand & growth | Customer-visible search-demand + growth (or honest UNKNOWN) | **No** customer-visible demand on any pilot (0 SEARCH_DEMAND signals; genuine GB demand signals exist only on TENANT_PRIVATE products). | **No** — needs demand evidence on a released product; release of these competitor pilots does not supply it. UNKNOWN path already accepted. |
| **GPD.07** Search and social demand | Customer-visible search/social demand | **No** (0 search/social signals on pilots). | **No** — same gap. |
| **GPD.08** Country seller counts | Observed seller count (aggregate), honest UNKNOWN otherwise | **Yes, for 1 product** — Projecteur GB 5 distinct sellers (cleared, aggregate). | **Partially** — Projecteur sighting possible on release; still single-product. |
| **GPD.09** Authorised advertiser observations | Observed advertiser/ad presence | **No** — **0 observable ads across all 5 pilots.** (Advertiser evidence exists elsewhere in the catalogue but not on the customer-visible pilot set.) | **No** — not satisfiable on this pilot. |
| **GPD.10** Observed competitor offers + GB-local pricing | Observed offers + local price range | **Yes** — Projecteur GB 5 offers £33.99–£39.99 (cleared). | **Yes** — strongest; directly sightable on release. |
| **GPD.11** Country-specific saturation & maturity | Derived saturation with confidence | **Partial** — derivable from Projecteur's 5 direct sellers (→ VERY_HIGH, MEDIUM confidence), but from the *same* seller evidence as GPD.08/10; no ad or marketplace-diversity signal. | **Partial / weak** — do **not** treat as independently passed; it rides the seller evidence. |

**Honest conclusion:** after clearance + release, only **GPD.10** (and, single-product, **GPD.08**) gain a genuine customer-visible sighting; **GPD.11** is weak/derivative; **GPD.06, GPD.07, GPD.09 cannot progress** on this pilot for lack of demand and advertiser evidence. Closing those three needs genuinely-observed demand/advertiser evidence on customer-visible products — a separate acquisition, not part of GPD.01.

---

## 11. Controls & status

No rights clearance granted; no `customer_source_release` row flipped (5/5 `released=false`); `display_derived_cleared` unchanged (FALSE); images blocked; links absent; tenant/country isolation intact; no provider call, no order, $0. GOLD acceptance **11/22** (C2:C23) unchanged — no checkbox flipped. GPD.01 remains **OPEN** pending Part 6 (counsel) + Part 7 (founder release).
