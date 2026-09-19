# STRATELOQ-SEARCH-DEMAND-RELEVANCE-FIX-013L

**FINAL VERDICT: `SEARCH_DEMAND_RELEVANCE_FIXED`.**

The 013K false-negative is corrected truthfully (not by relaxing until the score rose). For
**kids nightlight projector + GB**, `night light projector` (1,600/mo) is now a full-weight
CLOSE_VARIANT and `star projector` / `galaxy projector` are CATEGORY_DEMAND weighted ×0.35 (labeled,
never claimed as product-specific searches). buyer_search_intent **0 → 61 (GOOD)**; opportunity
score **51.0 → 68.2**; the rise is the correction of a false-zero, not inflation. Recompute via the
canonical pipeline only; no value patched. TikTok recorded `BLOCKED_EXTERNAL_APPROVAL /
APPLICATION_SUBMITTED`, still not AVAILABLE — full-launch deep-research remains PARTIAL.

Migration: `mig_248_search_demand_relevance_fix.sql`.

---

1. **Root cause** — `fn_classify_search_query_relevance` is pure product-name token overlap. For
   product tokens `[kids, nightlight, projector]`, category queries share only `projector` →
   overlap 1/3 = **0.33**, one point below the 0.34 floor → `IRRELEVANT`; and `nightlight` (one
   token) never matches `night light` (two tokens) — a compound-word normalization gap. There was
   **no CATEGORY/SOLUTION tier**, so genuine category demand had nowhere to land. Only
   `fn_ingest_search_demand_for_product` consumed the classifier, and it counted only
   DIRECT_PRODUCT/CLOSE_VARIANT → buyer_search_intent = 0.
2. **Existing behavior** — states: DIRECT_PRODUCT / CLOSE_VARIANT / AMBIGUOUS / IRRELEVANT +
   ACCESSORY / SERVICE / INFORMATIONAL; thresholds 0.75 (direct), 0.6/0.5+mod (close), 0.34
   (ambiguous). Receiver: only DIRECT+CLOSE counted.
3. **Exact change** — (a) de-spaced compound containment (coverage ≥ 0.6) → CLOSE_VARIANT (fixes
   `nightlight` vs `night light`); (b) query shares the product's category **head noun** →
   CATEGORY_DEMAND; (c) shares meaningful non-head product tokens (overlap ≥ 0.34) → SOLUTION_DEMAND;
   (d) any shared token → ADJACENT; else IRRELEVANT. `screen` added to the generic accessory list so
   `projector screen` → ACCESSORY. Vocabulary now: DIRECT_PRODUCT / CLOSE_VARIANT / CATEGORY_DEMAND /
   SOLUTION_DEMAND / ADJACENT / IRRELEVANT (+ ACCESSORY/SERVICE/INFORMATIONAL guards).
4. **DIRECT vs CATEGORY vs SOLUTION** — DIRECT/CLOSE = the exact product or a close variant (name
   overlap / compound containment). CATEGORY = shares the product's category head noun (broader
   category demand). SOLUTION = same audience/use-case tokens without the category noun. Derived from
   the product's own name tokens + head noun — no hardcoded projector terms.
5. **Evidence weighting** — DIRECT + CLOSE = full-weight **product demand**; CATEGORY + SOLUTION =
   **discounted ×0.35** and tracked separately (`product_relevant_volume` vs
   `category_relevant_volume`, `effective_relevant_volume`, `demand_basis`). Category volume is never
   summed into product-specific monthly searches; `claim_safety` states it is broader-than-product,
   weighted, and not product-specific. CATEGORY_ONLY demand also caps confidence at 0.55.
6. **DataForSEO calls** — **none re-executed**; the cached 013K keyword evidence (real GB
   search_volume / cpc / competition / intent / monthly_history) is deterministic and was re-ingested
   through the fixed receiver (§4 cache reuse).
7. **Cost** — **€0.00** (no new paid call).
8. **buyer_search_intent before/after** — subscore **0 (LOW)** → **61 (GOOD)**.
9. **opportunity_score before/after** — **51.0 → 68.2**.
10. **coverage before/after** — 0.78 → 0.78.
11. **evidence_confidence before/after** — HIGH → HIGH.
12. **Product Decision before/after** — WATCH → WATCH.
13. **Search terms accepted/rejected**

| Query | Before | After | Tier / weight |
|---|---|---|---|
| kids nightlight projector | DIRECT_PRODUCT | DIRECT_PRODUCT | product (null GB vol) |
| night light projector | IRRELEVANT | **CLOSE_VARIANT** | product, full (1,600) |
| night light projector for kids | CLOSE_VARIANT | CLOSE_VARIANT | product |
| kids star projector | CLOSE_VARIANT | CLOSE_VARIANT | product |
| star projector | IRRELEVANT | **CATEGORY_DEMAND** | category ×0.35 (2,900) |
| galaxy projector | IRRELEVANT | **CATEGORY_DEMAND** | category ×0.35 (3,600) |
| star projector night light | IRRELEVANT | **CATEGORY_DEMAND** | category ×0.35 (880) |
| buy star projector | IRRELEVANT | **CATEGORY_DEMAND** | category ×0.35 (10) |

    product_relevant_volume = 1,600; category_relevant_volume = 7,390; effective = 1,600 + 0.35×7,390 = **4,186.5**.
14. **TikTok status** — `provider_capability_registry` SOCIAL_VIDEO remains `SOURCE_UNSUPPORTED`
    (not AVAILABLE); limitations record `BLOCKED_EXTERNAL_APPROVAL; APPLICATION_SUBMITTED
    (founder-reported)`. Deep-research completion gate stays PARTIAL; no TikTok evidence fabricated,
    no build against unissued credentials.
15. **Regression** — new `fn_search_relevance_selftest` **10/10**; orchestrator 7/7; 013I/013A/013E/
    entitlement/storefront all_pass. Existing eBay (106 marketplace) / Meta (3 advertising) / Reddit
    (1 community) evidence unchanged; SEARCH_DEMAND upserted (still 1 signal, not duplicated). Other
    founder decisions unchanged (red-light mask 89.6, digital frame 74.6, shoe organizer 67.4). No
    fixtures entered founder decisions; research ledger coherent; registry authoritative.
16. **Security** — classifier is IMMUTABLE, pure, no data access; receiver stays SECURITY DEFINER
    service-role; no browser provider credentials; cross-tenant + anon paths unchanged (orchestrator
    contracts untouched). Advisors: 5 categories, unchanged. No synthetic evidence.
17. **Files/functions/migrations changed** — `mig_248_search_demand_relevance_fix.sql`
    (`fn_classify_search_query_relevance` v2, `fn_ingest_search_demand_for_product` with weighted
    tiers + provenance-merge on conflict + one-time provenance restore, `fn_search_relevance_selftest`);
    `provider_capability_registry` TikTok limitations updated. No Lovable/payment/publish/schedule
    change; no new provider; no new country.
18. **Commit** — see delivery message.
19. **Push / divergence** — branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

**STOP. No next unit started.**
