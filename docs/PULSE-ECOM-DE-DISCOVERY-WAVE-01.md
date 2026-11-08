# Germany Fresh-Discovery Wave 01 — Executed Result (2026-11-08)

Founder EXECUTE approval: consume up to **0.2 Kalodata credit** for fresh DE product discovery. **Executed within cap.**
Actual spend: **0.1 Kalodata credit** (1 Product-Rank call). No FastMoss / DataForSEO / CJ / other chargeable provider used.
No orders, ads, billing, signup, or credit purchase. Country-isolated to **DE**. Discovery signals only — **not** verified Gold/Platinum.

## Credit consumption + budget ledger
| Item | Value |
|---|---|
| Provider call made | **1** × Kalodata `tiktok/product/rank` (DE, `page_size=10`, `last7Day`, `launch_date<30`, sort `revenue_growth_rate DESC`) |
| Kalodata credit consumed | **0.1 credit** (0.1 / 10 products × 10 products returned) |
| Authorised ceiling | 0.2 credit — enforced as `provider_call_budget` KALODATA/DE `max_calls=2` (1 call = 10 products = 0.1 credit) |
| Budget state now | `consumed_calls=1 / max_calls=2`, **active=false** (closed) — unused 0.1 credit (1 call) **not** spent |
| Enforcement | `fn_provider_budget_try_consume` (atomic, fail-closed) gated the call; KALODATA is a metered fail-closed provider |

Why 0.1 and not 0.2: the request builder fixes `page_number=1`, so a 2nd call would re-fetch the **same** 10 products (guaranteed duplicates, 0 new candidates). Spending the 2nd 0.1 credit would buy nothing, so the wave was stopped at 1 call — within the 0.2 authorisation. Reaching 20 fresh candidates needs a 2nd page/window (an architecture change), not reused here.

## Safety guarantees verified (post-run)
- **Only** 1 outbound provider call (the Kalodata rank call). `net._http_response` shows **0** further HTTP calls after it.
- Auto-research dispatch was **neutralised for the run**: the `research_executor_webhook` was temporarily parked (URL blanked, secret preserved in-table), so `fn_research_dispatch` returned `NO_WEBHOOK_CONFIGURED` for every candidate → **no n8n → CJ/FastMoss/eBay/Meta call**. Webhook **restored verbatim** afterwards (verified url len 67 + secret len 64; hold key deleted).
- DataForSEO search-demand: **fail-closed** (`budget_disabled; paid DataForSEO skipped`). Reddit: free cache-reuse only (`SEARCHED_NO_EVIDENCE`). CJ / eBay / Meta / TikTok: `NOT_SEARCHED` (never dispatched).
- Tenant-isolated to the founder uid; exclusion ran against the founder's canonical identities.

## Duplicate exclusion (canonical identity)
Dedup enforced via `ingest_commerce_product` canonical identity (`url:` / `pid:` / `name:`), tenant-scoped. **Excluded-duplicate count this wave = 0** — all 10 are `dedup_status=new` vs the founder's existing **78** canonical identities (the 79th prior product belongs to a different tenant and is out of scope by tenant isolation). No prior product recycled or substituted.

## The 10 fresh Germany candidates (TikTok-Shop product-native, DE, observed this run)
Revenue/units = Kalodata market-scoped, last-7-day window; `confidence=0.6` (PLATFORM_REPORTED, single source); `observed_at=2026-11-08`.

| # | Product (DE) | Price | 7-day revenue | Rev. growth | Units | First seen | Lead channel |
|---|---|---|---|---|---|---|---|
| 1 | More Nutrition Rich & Creamy Protein Iced Coffee 500 g | €30.12 | €269,754 | −54.6% | 8,955 | 2026-10-27 | video |
| 2 | More Nutrition DAILY100 (Vitamine/Superfoods, vegan) | €82.32 | €119,858 | **+746.4%** | 1,456 | 2026-11-01 | video |
| 3 | More Nutrition XXL Topseller Bundle (53 Produkte) | €248.14 | €101,984 | −96.1% | 411 | 2026-10-31 | video |
| 4 | More Nutrition 4er Tasterbox Bundle (18 Produkte) | €71.39 | €66,178 | −38.6% | 927 | 2026-10-20 | live |
| 5 | Shark NeverChange Luftreiniger (air purifier, anti-odour) | €152.20 | €44,444 | **+210.4%** | 292 | 2026-10-15 | video |
| 6 | Weihnachts-Adventskalender 2026, 24 Squishy Überraschungen | €11.79 | €43,434 | −4.9% | 3,685 | 2026-10-26 | video |
| 7 | Country Music Cowgirl Pajama Set (2-piece loungewear) | €36.30 | €43,195 | −81.8% | 1,190 | 2026-10-28 | showcase |
| 8 | Purelei Classic Adventskalender Schmuck (Edelstahl, 24 Türchen) | €141.31 | €41,829 | **+50.9%** | 296 | 2026-10-16 | video |
| 9 | More Nutrition Protein Fasten Bundle (25 Produkte) | €132.41 | €34,825 | −88.8% | 263 | 2026-10-25 | showcase |
| 10 | Shark BlastBoss All-in-One-Gebläsesystem mit BlastBroom | €100.59 | €31,184 | **+451.1%** | 310 | 2026-10-15 | video |

Strongest genuinely-**emerging** signals (positive 7-day revenue growth, freshly launched): **#2 DAILY100 (+746%)**, **#10 Shark BlastBoss (+451%)**, **#5 Shark NeverChange air purifier (+210%)**, **#8 Purelei jewelry advent calendar (+51%)**. The high-absolute-revenue items with negative growth (#1, #3) are decelerating, not emerging.

## Discovery signal vs verified tier (honest distinction)
These are **initial discovery signals only**, not tier-qualified:
- One corroborating source (Kalodata PLATFORM_REPORTED, confidence 0.6), DE-isolated, fresh this run.
- **No** validated local price, **no** exact supplier/SKU binding, **no** landed-cost/margin, **no** saturation evidence, **no** multi-source corroboration.
- Under the deployed tier rules: **none is PREMIUM/GOLD/PLATINUM yet** (PREMIUM needs corroborated ≥MEDIUM demand + provenance + freshness; GOLD adds validated price + supplier economics + suitable saturation; PLATINUM adds HIGH-confidence + all gates). No tier was fabricated.
- Media: the product-rank endpoint returns demand metrics, **no** cover image — so 0 reference images were persisted. Imagery comes only from the later supplier-binding step.
- Each candidate has an inert `commerce_research_run` in `RESEARCHING` (created, nothing dispatched) awaiting the validation phase.

## Next recommended validation step (requires separate, explicit authorisation)
Promote the strongest emerging candidates (suggest **#2, #5, #8, #10**) into one bounded validation wave, each provider separately capped and approved:
1. **DataForSEO** (enable `research_budget_config`, `authorized_market='DE'`, small USD cap) → DE search-demand corroboration + local-price validation.
2. **CJ** exact-SKU identity-preserving search → supplier binding + rights-cleared images + stock + DE freight → landed cost/margin.
3. **FastMoss** new-listed corroboration (optional) if a second TikTok-Shop source is wanted.
4. Re-score via the existing engine/tier rules per country; report any that reach GOLD with evidence.

Nothing above is started: FastMoss/DataForSEO/CJ remain unauthorised and were not called.
