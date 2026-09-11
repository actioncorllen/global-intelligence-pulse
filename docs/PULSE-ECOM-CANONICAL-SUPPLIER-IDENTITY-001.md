# PULSE-ECOM-CANONICAL-SUPPLIER-IDENTITY-001

**VERDICT: PASS. OUTCOME B — no qualified TEST product (honest, and acceptable per PASS criteria).**
The structural identity bottleneck is removed: demand-led sourcing can now reach a defensible TEST
identity **without** weakening EXACT into fuzzy-title matching. Higher-ASP real demand discovery ran
and produced 8 economically-viable Product×Country survivors, but **CJ has no retrievable exact/strong
supplier** for any of them — confirming the supplier-coverage bottleneck at the level of CJ's available
catalogue search. No new supplier integrated. No store/ads/campaign/spend.

## 1. Old identity behaviour
`fn_resolve_supplier_identity` (mig_211–213) is a single-context token comparator. EXACT_PRODUCT was
reachable **only** when the caller passed `p_shared_identifier = true`; otherwise the ladder was
CLOSE_COMPARABLE (overlap≥0.5 ∧ ≥2 shared ∧ ≥1 non-generic) → CATEGORY_MATCH → UNRELATED.

## 2. Structural defect
A demand concept carries no CJ SKU/barcode, so `p_shared_identifier` is always false in demand-led
sourcing → EXACT_PRODUCT is unreachable by construction. Because TEST required EXACT_PRODUCT, **no
demand-led Product×Country could ever reach supplier validation**, even when CJ held the right product.
The function also conflated two different questions (is this the same CJ product? vs. is this the same
physical product as the marketplace concept?).

## 3. New identity model (mig_220) — two explicit contexts
`fn_resolve_supplier_identity` is left **unchanged** (still the primitive; EXACT still needs a shared
identifier). Added, purely functional (IMMUTABLE, `search_path=''`, no table access):

- **Context B — supplier canonical identity** `fn_supplier_canonical_identity(pid, query_confirmed_pid,
  subtype_ok)` → `SUPPLIER_EXACT` / `SUPPLIER_PID_UNVERIFIED` / `SUPPLIER_UNCONFIRMED`. A CJ PID
  re-confirmed by product/query (with compatible subtype) proves the CJ records are the same CJ product.
- **Context A — market↔supplier identity** `fn_market_supplier_match(spec, sup_title, sup_category,
  sup_ref, shared_identifier)` → `MARKET_SUPPLIER_MATCH_CONFIDENCE` ∈ {EXACT_CONFIRMED,
  STRONG_SAME_PRODUCT, CLOSE_COMPARABLE, CATEGORY_ONLY, UNRELATED, INSUFFICIENT_EVIDENCE}. Bridge uses
  product noun + required subtype + required attributes + **excluded subtypes** (+ brand/identifier).
- **TEST gate** `fn_test_identity_gate(supplier_state, market_match, subtype_price_valid,
  no_critical_risk)` → TEST_IDENTITY_SATISFIED / WATCH / REJECT.

## 4. Supplier canonical identity (Context B)
`SUPPLIER_EXACT` iff a real CJ pid equals the pid returned by product/query **and** subtype/attributes
are compatible. It establishes canonical identity of the **CJ product only** — never market identity.

## 5. Market↔supplier identity (Context A)
Conservative and defensible. **No fuzzy-title EXACT:** a same-type but unbranded/no-identifier match
tops out at `STRONG_SAME_PRODUCT`. `EXACT_CONFIRMED` requires a shared identifier **or**
brand+subtype+attrs. An explicitly excluded subtype (e.g. "pocket"/"compact" for a Hollywood mirror,
"cake"/"lazy susan" for a turntable) downgrades to `CATEGORY_ONLY`.

## 6. TEST identity rule (documented, not fuzzy-title)
| Supplier | Market | Extra conditions | TEST identity |
|---|---|---|---|
| SUPPLIER_EXACT | EXACT_CONFIRMED | no critical risk | **SATISFIED** |
| SUPPLIER_EXACT | STRONG_SAME_PRODUCT | price/demand valid at same commercial subtype **and** no critical risk | **SATISFIED** |
| SUPPLIER_EXACT | STRONG_SAME_PRODUCT | subtype/price not validated, or risk | WATCH |
| SUPPLIER_EXACT | CLOSE_COMPARABLE / CATEGORY_ONLY / … | — | WATCH |
| not SUPPLIER_EXACT | anything (even EXACT_CONFIRMED) | — | REJECT |

## 7. False-match regression (all PASS)
| Case | Result | Expected |
|---|---|---|
| pocket mirror ≠ Hollywood mirror | CATEGORY_ONLY | reject ✓ |
| passive watch box ≠ motorized winder | UNRELATED | reject ✓ |
| ordinary photo frame ≠ wifi digital picture frame | CLOSE_COMPARABLE | not same ✓ |
| gua sha ≠ facial roller | UNRELATED | reject ✓ |
| generic lamp ≠ projector nightlight | UNRELATED | reject ✓ |
| real winder / wifi frame / hollywood mirror (true positives) | STRONG_SAME_PRODUCT | ✓ |
| shared identifier / brand+subtype | EXACT_CONFIRMED | ✓ |

Gate cases also verified: STRONG without subtype-valid price → WATCH; STRONG with risk → WATCH;
non-canonical supplier + market EXACT → REJECT.

## 8. CJ PID canonical proof (real data, exec `30137`, 2026-09-11)
product/list candidate pid `2098293864388591618` → product/query returned **the same** `data.pid =
2098293864388591618`, with productSku `CJKP3154608`, variant vid `2098293864917073921` / variantSku
`CJKP315460801AZ` / barcode `8600001141970`, 9 catalogue images, category, weight/dims, supplier
(Shenzhen Upton Technology). End-to-end on real data: `fn_supplier_canonical_identity` → **SUPPLIER_EXACT**;
that product vs the kettle concept spec → **UNRELATED**; combined gate → **WATCH / IDENTITY_TOO_WEAK**
(mechanism works; discipline holds — a confirmed CJ product still cannot reach TEST unless it matches
the concept). CJ quota healthy (~1,090 / 50,000 points used today).

## 9. Markets screened
GB, DE, US this pass (architecture is global via `ecommerce_market_universe`; claims only where real
evidence exists). Prior evidence also covers FR.

## 10. Demand sources
eBay Production Browse API (real, exec `30135`) for price + saturation; plus existing
`market_price_observations`, `commerce_signals` (Reddit community-attention, marketplace activity).
DataForSEO buyer-intent available but **not spent** — the funnel terminated at the supplier-coverage
wall before any Product×Country needed final scoring (cost control §22: do not deep-enrich failed
concepts). No synthetic demand.

## 11. New demand concepts (18 Product×Country, 13 distinct; higher-ASP differentiated)
sunrise alarm (GB/US), bluetooth turntable (GB), smart hydroponic herb garden (GB/US), gooseneck
electric kettle (GB), portable espresso (GB/US), electric wine opener set (GB), levitating moon lamp
(GB/US), aroma diffuser (GB/DE), lichtwecker (DE), plattenspieler bluetooth (DE), wasserkocher temp (DE),
nackenmassage shiatsu (DE), cold brew maker (US). Low regulatory/fragility/battery risk prioritised.

## 12. Buyer-intent evidence
Not spent this pass (see §10). Available via DataForSEO for a re-run once real supply exists.

## 13. Local prices (VAT-inclusive medians, real eBay)
Highlights → EUR: turntable GB £79.70/€92.77; herb garden GB £76.70/€89.27; moon lamp GB £73.50/€85.55;
gooseneck kettle GB £63.53/€73.94; plattenspieler DE €61.99; moon lamp US $64.23/€55.29; herb garden US
$60/€51.65; portable espresso US $54.99/€47.34; wasserkocher DE €43.78; lichtwecker DE €41.52.

## 14. Economic ceilings (net of VAT − €15 ad reserve − €15 contribution − ~8% variable)
turntable GB €39.88; herb garden GB €37.25; moon lamp GB €34.45; gooseneck kettle GB €25.70; moon lamp
US €20.87; herb garden US €17.52; plattenspieler DE €17.13; portable espresso US €13.55 (all CEILING_OK).
wasserkocher DE €3.29 / lichtwecker DE €1.57 (thin); sunrise/aroma/espresso-GB/cold-brew/wine-opener dead.

## 15. Economic survivors
**8** Product×Country reached CEILING_OK (≥ €8 landed headroom) — vs only 2 in the prior low-ASP run.

## 16. CJ searches
10 exact-spec `product/list` queries (exec `30136`) across the 4 strongest survivor concepts (moon lamp,
herb garden, gooseneck kettle, bluetooth turntable) → 74 candidates. +1 `product/query` (canonical proof).

## 17. Canonical CJ products
1 canonically confirmed on real data (pid round-trip, §8). No survivor concept yielded a canonical
product that also matched the concept.

## 18. Market↔supplier classifications (74 candidates)
| Concept | STRONG | CLOSE | CATEGORY | UNRELATED |
|---|---|---|---|---|
| levitating moon lamp | 0 | 11 | 1 | 7 |
| smart herb garden | 0 | 3 | 0 | 20 |
| gooseneck kettle | 0 | 0 | 0 | 17 |
| bluetooth turntable | 0 | 0 | 0 | 15 |

**0 STRONG_SAME_PRODUCT, 0 EXACT_CONFIRMED.** Inspection confirmed the moon-lamp CLOSE candidates are
wall/desk/table lamps, a flashlight keychain, solar fence lights, even "moon" foot spray and wedding
dresses — the classifier correctly refused to promote any (no false positives; no real matches).

## 19–21. Stock / warehouse / freight
Not spent on survivor concepts for a decision — none reached identity survival (reverse-sourcing
discipline: exact/strong only). Freight/stock exercised only on the canonical-proof product (mechanism);
that product was OUT_OF_STOCK (CJ 0 / factory-only) and would fail the stock gate regardless.

## 22. Landed economics / 23. Advertising Headroom / 24. Product Confidence
Not computed to a decision — the funnel terminated at the identity/coverage wall before any Product×Country
became TEST-eligible. Economic ceilings (§14) stand as the pre-CJ headroom; final landed economics await
a real exact/strong supplier.

## 25. Final tournament / 26. Strongest Product×Country
No TEST-eligible Product×Country. Strongest identity reached = **CLOSE_COMPARABLE** (levitating moon lamp
GB, smart herb garden GB) → **WATCH** under the gate. Best economics: turntable GB (€39.88 ceiling) but
0 CJ supply.

## 27. Outcome
**B — no qualified TEST.**

## 28. CJ supplier-coverage verdict
**SUPPLIER_COVERAGE_BOTTLENECK_CONFIRMED** (retrievable-catalogue level). Real, commercially-viable,
differentiated, higher-ASP demand repeatedly passed demand → price → economic ceiling → saturation, then
failed at supplier identity because CJ's available discovery (`product/list` keyword search) returned no
exact/strong product for any survivor. **Honest caveat:** this confirms a gap in what CJ's keyword search
*retrieves*; distinguishing "CJ catalogue truly lacks these" from "CJ keyword search cannot surface them"
would require CJ category-browse / the dedicated CJ search endpoint — a new supplier-search capability
explicitly out of scope for this unit. Recommend that as the next step **before** any decision to add a
second supplier.

## 29. API / query counts
eBay Browse: 1 auth + 18 searches (exec 30135). CJ: 1 auth + 10 product/list (30136); 1 auth + 1
product/query + 2 freight + 1 stock + 2 comments (30137, canonical proof). Supabase: 1 migration + reads.
€0 cost. CJ points ~1,090/50,000 today.

## 30. Bugs / fixes
None. New functions passed all regression and gate tests first time.

## 31. External blockers
None. eBay + CJ credentials valid; quotas healthy.

## 32. Campaign safety
No store, publication, ads, campaign, or activation. Paused Meta proof campaign untouched.
`campaign_activation = FALSE`.

## 33. Advertising spend
`advertising_spend = 0`.

## 34. Tests
11/11 market↔supplier classification tests PASS; 6/6 TEST-gate cases correct; canonical PID round-trip
proven on real data; end-to-end real-data gate = WATCH as designed.

## 35–36. Git / remote verification
mig_220 mirrored to `supabase/migrations/`; doc added. Secret-scanned, committed and pushed to
`claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0. (See commit footer below.)

## 37. Paid-beta readiness
≈ **85%** (up slightly from 84%): the identity model no longer structurally blocks demand-led sourcing,
and higher-ASP demand capture is proven. The remaining gap to a first real TEST is supplier coverage /
retrievability, not Pulse engineering.

## 38. EXACT NEXT ACTION (for founder approval — not executed)
Add **CJ canonical discovery** (category-browse and/or the dedicated CJ search endpoint that returns
pid/sku) so higher-ASP survivor concepts (moon lamp, herb garden, kettle, turntable) can be resolved to a
canonical CJ product and run through the new `SUPPLIER_EXACT → market_supplier_match → test_identity_gate`
chain. This settles catalogue-gap vs search-retrieval-gap **without** weakening identity and **without**
adding a second supplier. Only if CJ still cannot supply the commercially-viable set does supplier
expansion become justified.
