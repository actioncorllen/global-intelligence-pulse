# STRATELOQ — Restore + Surpass Premium Product Page Quality

**Status:** `PASS_LOVABLE_RENDER_DELTA_REQUIRED`.

## Root cause (why the real page was Hero → Trust → CTA)

Three connected defects, all in the intelligence→spec handoff (not the renderer):

1. **Frontend strategy gate bug.** `buildProductPageSpec` (`src/lib/storefront/builder-spec.ts`) used the strategy only when `canonical.strategy.hasPreparedListing` is true. The evidence-validated draft sets `has_strategy` (not `has_prepared_listing`), so `strat` resolved to `null` and the rich strategy was discarded — the page fell back to the empty acquisition.
2. **Backend under-forwarded the copy.** `fn_product_page_strategy` surfaced only positioning / value proposition / benefits and **dropped** the rest of the existing claim-safe copy engine's output (`fn_generate_page_copy`): problem, solution, how-it-works, FAQ, details. With no content for those sections, `gateSections` hid them → only Hero/Trust/CTA survived.
3. **No market label.** The context exposed `market` (GB) but no country name, so the storefront rendered "Your market" / "--".

The premium `StorefrontRenderer`, `TEMPLATE_REGISTRY`, `SECTION_REGISTRY`, `composeSections` and `gateSections` were intact and capable — they were simply starved of content and mis-gated.

## Backend fix (this unit — reuse, no new engine)

`mig_337` extends `fn_product_page_strategy` (v2) to expose the **full claim-safe
copy** from the existing `fn_generate_page_copy` under `page_copy`
(`headline, subheadline, short_description, problem, solution, how_it_works[],
faq[], details, shipping_note, trust_note, announcement`) plus `market_label`,
and `fn_product_page_builder_context` (v3) now returns top-level `market_label`.
Nothing is fabricated — `fn_generate_page_copy` remains claim-safe
(no reviews/discount/urgency/guarantee/certifications). Country isolation and all
Product-step/strategy fields are preserved.

### Verified (Nightlight GB) — `fn_product_page_strategy_selftest` 22/22
`page_copy.problem`, `.solution`, `.how_it_works` (3 steps), `.faq` (3 Q&A),
`.details` all present; `market_label = "United Kingdom"`; fixture-leak guard
(no `hearth|fermentation|fixture|fictional editorial`) passes; claim-safety all
true; humidifier stays `CONCEPT_LEVEL_DRAFT` (`CONCEPT_ONLY`). Product step,
scorer (78.2), rights/PAL, store (humidifier + nightlight), RLS unchanged;
0 ERROR advisors.

## Frontend render delta required (Lovable)

The renderer already supports premium depth; it needs the correct spec. The exact
delta (gate fix + `page_copy`/`market_label` mapping + use the backend-selected
template family) is in the delivery message. No renderer redesign.

## Acceptance

With the delta applied, the real Nightlight page renders
Hero → Product intro → Benefits → How it works → Details → FAQ → Trust → Price →
CTA (evidence-safe omissions preserved: no reviews/shipping-promise/comparison),
on a premium template, with the real market label — at least as polished as the
old fixture while carrying substantially more real intelligence. An authenticated
browser smoke test remains.
