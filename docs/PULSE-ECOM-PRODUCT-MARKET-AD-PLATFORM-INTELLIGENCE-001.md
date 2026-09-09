# PULSE-ECOM-PRODUCT-MARKET-AD-PLATFORM-INTELLIGENCE-001

**VERDICT: PASS.** Permanent Product × Market × Advertising-Platform Intelligence: for a product ×
market Pulse recommends which platform to test first, why, on what evidence, alternatives, and what
evidence is missing — with opportunity kept strictly separate from execution readiness.

## Audit: evidence vs execution (kept separate)
- **FACEBOOK / INSTAGRAM:** real evidence (Meta Ad Library) **and** execution (Meta executor, paused-proof). Distinguished as separate platforms though both use the Meta adapter.
- **GOOGLE_SEARCH:** real intelligence (DataForSEO SEARCH_DEMAND) but **no execution** — Google Ads API rejected → `execution_readiness = BLOCKED`, intelligence-only, never bypassed.
- **TIKTOK:** creative-variant contract only; **no standalone intelligence source, no adapter** → evidence INSUFFICIENT, execution NOT_CONNECTED. Never fabricated.

## Model
`product_market_platform_evaluations` (mig_180): one row per (tenant, product, country, platform, score_version), linked to `product_market_evaluations.id`. Platform taxonomy FACEBOOK/INSTAGRAM/TIKTOK/GOOGLE_SEARCH, extensible. Execution readiness stored via `fn_ppf_execution_readiness` and **never** affects score/recommendation.

## Scoring (`ppf_score_v1`, reuses `fn_pm_score`)
8 weighted components (buyer_intent_fit 18, observable_competitor_activity 12, audience_fit 14, product_demonstrability 12, creative_format_fit 12, price_consideration_fit 8, competition_saturation 12, platform_opportunity_gap 12). Weighted mean over KNOWN components only; UNKNOWN excluded (never zero). Coverage + evidence_confidence exposed separately.

## Search vs discovery (`fn_ppf_acquisition_mode`)
SEARCH_LED / DISCOVERY_LED / HYBRID / UNKNOWN derived from evidence — search buyer-intent band + transactional volume vs discovery social attention + demonstrability — not from generic LLM knowledge.

## Facebook vs Instagram
Kept distinct. When evidence proves only "Meta ecosystem" activity and cannot separate IG performance, IG carries lower coverage/confidence (verified: FB HIGH vs IG MEDIUM) — precision is never fabricated.

## TikTok
Evidence INSUFFICIENT → `INSUFFICIENT_EVIDENCE`, confidence NONE, metrics UNKNOWN. PRODUCT_PLATFORM_FIT (e.g. demonstrability 80) is distinguished from OBSERVED_PLATFORM_MARKET_EVIDENCE; product fit alone never produces a TikTok ranking (verified: raw component present but not ranked).

## Google / Search
Uses DataForSEO search-intent evidence only. CPC / advertiser competition are never treated as CPA/conversion/performance. Intelligence is produced without Google Ads execution access; the API rejection is not bypassed.

## Competitor integration
Consumes Product×Market×Competitor signals: observable competitor/advertiser counts, observable ads, patterns, saturation feed the platform components. Active ads never become sales/revenue/ROAS/CPA/winning-ad.

## Platform-gap intelligence
UNDERUSED_PLATFORM / HIGH_DEMAND_LOW_AD_ACTIVITY / SEARCH_INTENT_GAP / CREATIVE_FORMAT_GAP / AUDIENCE_PLATFORM_GAP / SATURATED_PLATFORM — each with evidence + confidence + why_it_matters. Zero competitor activity alone never becomes an opportunity (must be corroborated by demand/intent/product fit).

## Ranking & recommendation (`fn_ppf_rank`, deterministic)
Eligible candidates ordered by **confidence-tier first, then fit, then platform** → #1 PRIMARY_TEST, #2 SECONDARY_TEST, rest ALTERNATIVE; INSUFFICIENT_EVIDENCE / AVOID stay as-is. This prevents a partial-coverage platform outranking a well-supported one via excluded unknowns. Ranking **ignores execution readiness**. States: PRIMARY_TEST / SECONDARY_TEST / ALTERNATIVE / WATCH / INSUFFICIENT_EVIDENCE / AVOID.

## Execution readiness is separate
Recommended platform may be BLOCKED/NOT_CONNECTED (proven: DE PRIMARY = GOOGLE_SEARCH with execution BLOCKED, above FACEBOOK which is CONNECTED). Meta connected ≠ Meta best.

## Market isolation
Per product × market. Proven: DE PRIMARY = GOOGLE_SEARCH vs GB PRIMARY = FACEBOOK. No global platform recommendation.

## Monday contract (`fn_ppf_monday_block`)
BEST_AD_PLATFORM / FIT_SCORE / WHY / SEARCH-vs-DISCOVERY / COMPETITOR_ACTIVITY / SATURATION / CREATIVE_FIT / ALTERNATIVE / EVIDENCE_CONFIDENCE / EXECUTION_READINESS. Monday cadence unchanged; no new recurring workflow.

## Downstream + performance/learning linkage
Consumable by Product Decision, Audience/Offer, Keyword, Product Page, Ad Studio (platform-native creative from patterns, never protected creative), Campaign Planning, Manual/Bounded Launch, Performance, Learning — keyed by product_id + product_market_evaluation_id + platform + score_version so future real results can link back ("recommended Instagram; actuals showed Facebook stronger").

## Tests — 22/22 PASS (deterministic fixtures, is_fixture=true)
Same product ranks platforms differently (DE) and across countries (DE Google vs GB Facebook); high search intent favors Google; demo-fit alone can't fabricate TikTok evidence; TikTok INSUFFICIENT stays INSUFFICIENT; Meta execution doesn't make Meta #1; active ads ≠ performance; CPC ≠ CPA; UNKNOWN stays UNKNOWN; low-evidence platform (IG MEDIUM, fit 68.5) cannot outrank HIGH platforms; FB≠IG distinguishable; saturation downgrades fit; underused platform not auto-opportunity; ranking deterministic; tenant isolation; market isolation; pme link preserved (4); competitor integration (FB ad_count 5); fixtures ≠ acceptance (0 real rows); campaign_target_market unchanged (null); campaign_activation FALSE; advertising_spend 0.

## Roadmap impact
Phase 2 (evidence → platform fit), Phase 3 (competitor activity by platform), Phase 5 (Product×Market×Platform recommendation), Phase 6 (search/channel intent), Phase 7 (platform audience/offer), Phase 9 (platform-native Ad Studio), Phase 14/15 (Product×Market×Platform performance/learning) now have a canonical platform layer. **Monday Product Opportunity Acceptance NOT marked PASS** (requires real external evidence).

## Safety / invariants
No founder acceptance run, no workspace publish, no page/ads/campaign/activation/spend, no Google Ads bypass, no fabricated TikTok intelligence, no Monday-cadence change, no new recurring workflow.
`campaign_activation = FALSE`; `advertising_spend = 0`; cost €/$0.
