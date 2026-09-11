# PULSE-ECOM-LIGHTWEIGHT-HIGH-ASP-TEST-PRODUCT-001

**VERDICT: PASS. OUTCOME: B — no qualified HIGH-CONFIDENCE TEST (honest; not forced).**
Every proven system worked end-to-end: lightweight high-ASP demand discovery, economic ceiling,
category-scoped canonical CJ discovery (**it found real supply this time**), title-scoped identity,
real DE buyer intent. The funnel terminated at a new, deeper bottleneck: **economic ceiling vs real
supplier cost** — the one lightweight survivor (mini projector × DE, €60 median) yields a €15.62 landed
ceiling, but real CJ mini projectors cost €26–62, i.e. supplier cost alone is 1.7–4× the ceiling.
Supplier #2 is NOT justified (CJ *has* the product; the constraint is ASP-vs-COGS, which a second
China-shipping dropshipper would share). No store/ads/campaign/spend.

## 1. Markets screened
GB, DE, US this pass (global architecture via `ecommerce_market_universe`; claims only where real
evidence exists; other markets remain ANALYSIS_REQUIRED/LIMITED_EVIDENCE).

## 2. Demand sources
eBay Production Browse (real, exec `30141`, 20 queries) for price + saturation; DataForSEO Google Ads
search volume + intent (real, exec `30143`) for buyer intent; plus existing `market_price_observations`
/ `commerce_signals`. No synthetic demand.

## 3. Demand concepts (20 lightweight, differentiated, low-risk)
mini projector (GB/DE/US), bluetooth sleep mask, ultrasonic jewellery cleaner, LED neon sign (GB/DE/US),
electric wine decanter/aerator (GB/DE/US), facial steamer, reusable smart notebook (GB/US), bladeless
neck fan (GB/US), schlafmaske, ultraschall schmuckreiniger, gesichtssauna. First-beta risk filter
applied (no medical/regulated/hazardous/fragile/bulky/battery-restricted).

## 4. Buyer intent (real, DE, mini projector)
`mini beamer` 12,100/mo · `mini projektor` 2,400 · `beamer klein` 2,400 · `beamer für heimkino` 1,600 ·
`tragbarer beamer` 590 (~19k/mo aggregate). Competition **HIGH**; intent informational→commercial
(`mini beamer kaufen` transactional 0.9999 but only 90/mo). Genuine strong search demand; not fabricated
to a number. Buyer intent was **not** the binding constraint.

## 5. Local prices (real eBay medians)
Mini projector: **DE €60** (188 listings) · US $31.99 · GB £27.74. LED neon US $39.99 (83,873 listings).
All other lightweight concepts ≤ €32 median.

## 6. Saturation
Mini projector DE **LOW** (188). LED neon US VERY_HIGH (83,873). Others LOW→HIGH. UNKNOWN never treated
as LOW.

## 7–9. Economic ceilings & survivors (net VAT − €15 reserve − €15 contribution − ~8% variable)
| Concept × Country | Median € | Ceiling € | Saturation | Verdict |
|---|---|---|---|---|
| **mini projector × DE** | 60.00 | **15.62** | LOW | **OK (sole survivor)** |
| led neon sign × US | 34.43 | 1.67 | VERY_HIGH | THIN → drop |
| all other 18 | ≤ €32 | negative | — | DEAD |

20 concepts priced → **1 commercially-meaningful economic survivor** (mini projector × DE). The
lightweight bias exposed the core tension: genuinely light products mostly carry low ASP.

## 10. Shipping-friendliness prefilter
Applied via CJ list-level weight before any detail/freight calls (§10/§14). Mini projectors: 445 g–2.5 kg.

## 11. CJ categories (provider-native, getCategory exec 30138)
Projectors `0AC6B44A-…` and Projectors & Accessories `A9B643D0-…` (Consumer Electronics).

## 12. Category-scoped searches / candidates
Category+noun discovery (exec `30142`, 4 queries) → 36 candidates. **Retrieval works: category scoping
surfaced genuine mini projectors** (the keyword path historically returned junk for electronics).

## 13–16. List-level filtering · canonical PIDs · classifications · identity survivors
`fn_market_supplier_match` (title-scoped, mig_221): **12 STRONG_SAME_PRODUCT**, 3 CLOSE, 20 CATEGORY_ONLY
(accessories: screens/mounts/bulbs excluded), 1 UNRELATED. Subtype-price-validity: the cheapest "STRONG"
($17.42, 445 g) is a **Galaxy starry-sky nightlight** — a different, cheaper commercial subtype than the
€60 *video* mini-projector demand (the gooseneck-kettle lesson), so it is not price-valid and is excluded
from the tournament. Cheapest **genuine video mini projector: $29.99 (700 g)**.

## 17–19. List-level economic rejection (before detail/stock/freight — §14 cost control)
| Cheapest genuine video mini projector | $29.99 = **€25.8** |
|---|---|
| MAX_ACCEPTABLE_LANDED_COST (DE) | **€15.62** |
| Supplier cost vs ceiling | **€25.8 > €15.62 before any freight** |

Every genuine video mini projector ($29.99–$72.54 = €25.8–62.4) exceeds the entire landed ceiling at the
supplier-cost stage alone. Per §14 these are economically impossible; no detail/stock/freight calls were
spent on them (correct discipline; the prior turntable run already demonstrated the full stock+freight
chain on a heavy item).

## 20. Evidence breadth (mini projector × DE)
Real: SEARCH_DEMAND (DataForSEO) + MARKETPLACE (eBay) + SUPPLIER (CJ, 12 STRONG) = **3 independent
categories**. (Enough for breadth; the block is economics, not evidence.)

## 21. Product Confidence
**LOW** — fails viable economics (landed cost cannot fit under ceiling). Strong demand + real supply do
not grant HIGH when economics fail.

## 22–25. WPS / tournament / strongest Product×Country
No Product×Country cleared the hard gates. Strongest = **mini projector × DE**: strong demand + LOW
saturation + real STRONG_SAME_PRODUCT CJ supply, but **landed economics fail** (supplier cost > ceiling).
Decision: **WATCH/AVOID**. Advertising Headroom: N/A (never reaches a viable landed cost). No country
alternative rescues it (US/GB medians lower → deader).

## 26–27. Outcome
**B.** Funnel: 20 concepts priced → 1 buyer-intent-supported & ceiling-viable (mini projector DE) →
shipping-friendly ✓ → CJ category matches ✓ (12 STRONG) → SUPPLIER_EXACT achievable ✓ → **economics
fail at supplier-cost prefilter** → 0 IN_STOCK-gated → 0 TEST.

## 28. Binding bottleneck (quantitative)
**ECONOMIC_CEILING_VS_SUPPLIER_COST.** Market ASP €60 → net €50.4 → after €15 reserve + €15 contribution
+ VAT + variable → **€15.62 landed ceiling**, but the cheapest genuine CJ video mini projector is
**€25.8** (before freight). Gap ≈ **−€10 to −€47** depending on model. This is distinct from prior
bottlenecks (supply retrieval → fixed; freight-weight → this concept is lighter). The residual
constraint is that €40–90 median ASP is still too low for the €15 reserve + €15–20 contribution model
once EU VAT and real electronics COGS are honestly subtracted.

## 29. Supplier #2 verdict
**CJ_SUFFICIENT_CONTINUE.** CJ demonstrably *has* the product (12 STRONG canonical candidates,
retrievable via category-scoped discovery). The block is ASP-vs-landed-cost economics, which a second
China-shipping dropship supplier would share (similar wholesale + similar freight + same VAT). Adding
supplier #2 would not change the arithmetic. **Do not add supplier #2.**

## 30. API / query counts
eBay: 1 auth + 20 searches (30141). CJ: 1 auth + 4 category product/list (30142); getCategory reused
from 30138. DataForSEO: 1 search-volume + 1 search-intent (30143, cost $0.10). CJ detail/stock/freight
this run: **0** (list-level economic rejection). Supabase: reads + 20 inserts. €0 infra cost.

## 31. Bugs / fixes
None. mig_221 title-scoped classifier held correctly (accessories → CATEGORY_ONLY; genuine projectors →
STRONG). Recommendation (spec-level, not code): add `galaxy/starry/night light` to the mini-projector
concept's excluded_subtype so ambient nightlights are not counted as video-projector STRONG in future
runs.

## 32. External blockers
None. eBay, CJ, DataForSEO all returned real data; quotas healthy.

## 33. Campaign safety
No store/publication/Ad Studio/campaign/activation. Paused Meta proof campaign untouched.
`campaign_activation = FALSE`.

## 34. Advertising spend
`advertising_spend = 0`.

## 35. Tests
mig_221 regression remains green (from prior unit); classifier applied to 36 real candidates with
correct STRONG/CATEGORY/UNRELATED separation; buyer-intent and price evidence real and provenance-kept.

## 36. Git
Report doc committed; no schema/code change required this run. Secret-scanned, pushed to
`claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0.

## 37. Paid-beta readiness
≈ **86%** (unchanged): discovery + identity + economics pipeline is complete and trustworthy. The
remaining gap to a first real TEST is **concept economics** (finding a category whose real market ASP
clears real landed cost + the contribution model), not engineering.

## 38. EXACT NEXT ACTION (for founder approval — not executed)
Two honest levers to reach Outcome A, for your decision:
1. **Raise the ASP target band to ~€80–140** (still market-led) for differentiated products whose real
   median clears a €25–45 landed cost — e.g. premium/branded-feel home, higher-spec electronics — and
   re-run this same funnel. The €40–90 band is structurally too low for the €15 reserve + €15–20
   contribution model after VAT + real COGS.
2. **Revisit the contribution model** for the beta (e.g. accept €10–12 first-test contribution, or
   treat the €15 ad reserve as CPA budget rather than a subtracted reserve) — this is a founder economic
   policy decision, not something Pulse should change unilaterally.
Recommended: run (1) first (pure discovery, no policy change). Supplier expansion remains unjustified.
