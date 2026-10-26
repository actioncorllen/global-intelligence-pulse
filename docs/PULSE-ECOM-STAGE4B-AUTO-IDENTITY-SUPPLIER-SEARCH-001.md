# PULSE-ECOM-STAGE4B-AUTO-IDENTITY-SUPPLIER-SEARCH-001 — Automatic Identity-Aware Supplier Search

**The supplier search now recognises the same underlying product across different marketplace names,
descriptions and languages — without being handed the CJ product id. From the FastMoss "Novelty Old Man
Face Ski Mask" alone, the identity pipeline generated lexicon-driven, identity-preserving CJ search queries,
paginated the existing authorised CJ workflow, de-duplicated candidates by CJ PID, and the cross-supplier
resolver re-discovered CJ PID `2609290358281623700` (CJ title "Realistic Winter Ski Face Mask … Balaclava")
and classified it `SAME_PRODUCT_IDENTITY` / `MEDIUM` with 8 corresponding Old-Man-Face variants — proving
req 9 end to end. Generalisation and negatives pass: "red light therapy led mask" auto-resolves to a
different real CJ product; a wreath and a skull door-cover correctly return `UNVERIFIED` / `SIMILAR_ONLY`
with no false positive from mere keyword overlap. The mechanism reuses the existing 73-row identity lexicon,
the cross-supplier resolver, the CJ integration and the Stage-2 pipeline — no duplicate architecture. One
new migration (`mig_328`) replaces the Christmas-only query expander with a lexicon-identity expander.**

Continues the completed CJ supplier-media implementation (commit `c5d436d`). Stays within Stage 4B.
Tenant `7c8ddf9d…` · GB market · CJ API (free tier, points balance ~50000, unchanged).

---

## What was reused (req 1) — no duplicate architecture

| Existing asset | Role in this unit |
|---|---|
| FastMoss / Kalodata concrete identities | `fn_derive_concrete_product_identity` → the immutable discovered-product identity (canonical_name, concrete_phrase, distinguishing_attributes, match_spec, fingerprint) that every candidate is judged against. **Never mutated.** |
| 73-row `commerce_identity_lexicon` (9 families) | Source of cross-vocabulary surfaces. `fn_identity_families(text)` maps the discovered product's identity text to its families. |
| Cross-supplier resolver | `fn_resolve_cross_supplier_identity` — tiered recognition `SAME_PRODUCT_IDENTITY` / `SIMILAR_ONLY` / `DIFFERENT_PRODUCT` / `UNVERIFIED`, confidence `MEDIUM`/`LOW`/`NONE`, per-variant correspondence, `exact_variant_verified=false` gate. |
| CJ integration + Stage-2 pipeline | `fn_stage2_cj_retrieval_plan` → the n8n breadth-first paginator (authorised CJ `product/list`) → `fn_stage2_resolve_from_pages` → `fn_stage2_cj_finalize_candidates` (dedup by PID). |
| `media-asset-url` + media contracts | Automatic supplier image/video retrieval reused as-is for the supported candidate; copyright / Asset Lock untouched. |

**The only new code is `mig_328`** — a `CREATE OR REPLACE` of `fn_stage2_supplier_search_queries` that adds a
lexicon-identity expansion layer. Everything else is the pre-existing pipeline.

---

## The one gap that was fixed (req 2) — identity-preserving query generation

`fn_stage2_supplier_search_queries` previously derived CJ search terms only from `fn_supplier_search_terms`,
whose expansion vocabulary is hardcoded to the Christmas/nativity family. For any other lexicon-covered
product it fell through to `SOURCE_PHRASE_FALLBACK` = the raw sorted tokens — for the ski mask that was
`"face man mask novelty old ski"`, which CJ `product/list` does **not** rank the real supplier product for
(the near-exact title returns 47,444 noisy results and buries the target).

`mig_328` adds the lexicon layer. For the discovered identity it:
1. derives identity families via `fn_identity_families` over the immutable concrete identity;
2. pulls **form** surfaces (headwear_facemask → `balaclava`, `full face`; skincare_mask; wall_art_sign),
   distinctive single-word nouns first, English + market language;
3. pulls **character / novelty** surfaces, `novelty_character` synonyms first — these are what carry across
   marketplaces (FastMoss **"novelty"** ↔ CJ **"realistic"**);
4. builds bounded, de-duplicated 2-word `character × form` queries + bare form queries, ≤ 6 words, capped at 12;
5. merges with the base terms; non-lexicon products keep the existing fallback unchanged (honest).

For the ski mask (GB) it now emits (source `LEXICON_IDENTITY_EXPANSION`):
`"funny balaclava"`, `"scary balaclava"`, `"realistic balaclava"`, `"novelty balaclava"`, `"character balaclava"`,
`"cosplay balaclava"`, + the `full face` variants + bare `balaclava` / `full face` — a bounded, deduplicated,
identity-preserving set in English (+ market language where applicable). This is the req-2 / req-3 deliverable.

Deployed via `apply_migration`. File: `supabase/migrations/mig_328_lexicon_identity_supplier_queries.sql`.

---

## Req 9 — automatic rediscovery of the CJ PID **without the PID supplied** (the core proof)

Driven entirely from the FastMoss product `56a6af36-68f7-4138-9d29-941245f266b2` (no CJ PID given):

1. `fn_stage2_supplier_search_queries` → lexicon queries above (`LEXICON_IDENTITY_EXPANSION`).
2. `fn_stage2_cj_retrieval_plan` → budget (page_size 20, ≤ 5 pages/query, ≤ 200 candidates, ≤ 40 calls).
3. n8n authorised CJ `product/list` paginator, exact/canonical queries first, alternatives only as needed,
   QPS-paced to respect CJ rate limits.
4. Target surfaced via query **`"scary balaclava"`, page 3** — **13 CJ API calls total**.
5. `fn_stage2_cj_finalize_candidates` de-duplicated by CJ PID.
6. `fn_resolve_cross_supplier_identity` evaluated the candidate against the immutable discovered identity →

| Outcome | Value |
|---|---|
| Rediscovered CJ PID | **`2609290358281623700`** (not supplied) |
| CJ title (different vocabulary) | "Realistic Winter Ski Face Mask … Balaclava" vs FastMoss "Novelty Old Man Face Ski Mask" |
| Tier | **`SAME_PRODUCT_IDENTITY`** |
| Confidence | **`MEDIUM`** |
| Corresponding variants | **8** Old-Man-Face variants (of 35 total), each `exact_variant_verified=false` |
| Basis | identity families + variant-level correspondence — **not** keyword overlap |

The lexicon's `novelty_character` family is what bridged FastMoss "novelty" ↔ CJ "realistic"; the CJ **title**
carries no "old man" (that phrasing lives only in its variants), so title-level resolution alone cannot bind
it — the **variant-level** cross-supplier resolver is what recognises it. **Req 9: PASS.**

---

## Req 10 — generalisation + negative tests (no false positives)

| Discovered product | Auto outcome | Verdict |
|---|---|---|
| "red light therapy led mask" (second genuine product) | `EXACT_SUPPLIER_IDENTITY_RESOLVED`, bound to real CJ PID `2113532057019973633`, qualifying_count 1/100 | **PASS** — generalises beyond the ski mask |
| Wreath (negative) | `UNVERIFIED` / `NONE` — no candidate met identity threshold | **PASS** — no false positive |
| "funny skull door cover" (negative) | `SIMILAR_ONLY` / `LOW` — related form, different product | **PASS** — keyword overlap correctly **not** treated as proof |

**Req 10: PASS.** Two genuine products auto-resolve to real CJ PIDs via distinct paths; two negatives are
correctly held below `SAME_PRODUCT_IDENTITY`.

---

## Req 11 — results reach the customer Product Intelligence Card

`fn_product_supplier_candidate` (signed-in simulation, tenant = `auth.uid`) returns for the ski mask:
tier `SAME_PRODUCT_IDENTITY`, confidence `MEDIUM`, 8 corresponding variants (`exact_variant_verified=false`),
the de-duplicated CJ gallery, and `commercial_use=NOT_CLEARED_REFERENCE_ONLY`. The card wiring, signed private
video playback and per-asset rights were already delivered and verified in
`PULSE-ECOM-STAGE4B-SUPPLIER-MEDIA-DISPLAY-001` / `…-CJ-VIDEO-PLAYBACK-FIX-001`. **Req 11: PASS** (data proven;
the literal in-browser pixel check remains the founder's one-click confirmation, as before — this container's
egress blocks the app + Supabase hosts).

---

## Preservation of the hard constraints (reqs 4–8)

- **Immutable discovered identity (req 4/5):** candidates are judged against the original concrete identity;
  it is never rewritten. Keyword overlap is never accepted as proof — the resolver requires family + variant
  correspondence, which is exactly why the two negatives stayed below `SAME_PRODUCT_IDENTITY`.
- **Tiered outcomes with provenance (req 5):** every outcome carries source, families, queries attempted and
  confidence; honest `UNVERIFIED` when nothing qualifies.
- **Variants evaluated independently (req 6):** only the 8 corresponding variants surface as candidates;
  each is `exact_variant_verified=false`. Exact-SKU verification remains a separate, un-reached gate.
- **Media reuse preserves rights + Asset Lock (req 7):** the supported candidate's images/video reuse the
  existing retrieval path; all CJ media stays `REFERENCE_ONLY`, `advertising_cleared=false`; nothing unlocks
  store/ad/creative/publishing.
- **Attempt record (req 8):** queries attempted, source (`LEXICON_IDENTITY_EXPANSION`), present families,
  form/character surfaces, page/call counts, coverage and honest no-match are all emitted in the function
  payload and the Stage-2 diagnostics.

---

## Provider costs
CJ API only, **free tier**; points balance ~50000, unchanged (search is `product/list`, not a paid call).
No DataForSEO, no AliExpress, no BigBuy, no licence purchases, no scraping. **No unapproved paid calls.**

---

## Status per directive requirement
| Req | Verdict |
|---|---|
| 1 Reuse FastMoss/Kalodata identities, CJ, 73-row lexicon, cross-supplier resolver — no duplicate architecture | **PASS** |
| 2 Generate bounded, deduplicated, identity-preserving supplier queries from attributes/synonyms/languages | **PASS** — `mig_328` lexicon expander, deployed |
| 3 Search CJ via authorised workflow; exact/canonical first, alternatives as needed; respect rate limits | **PASS** |
| 4 Dedup by CJ PID; evaluate against the original immutable identity | **PASS** |
| 5 Tiered outcomes with provenance; never treat keyword overlap as proof | **PASS** |
| 6 Evaluate variants independently; only corresponding variants as candidates; exact-SKU a separate gate | **PASS** |
| 7 Reuse automatic image/video retrieval for supported candidates; preserve copyright/Asset Lock | **PASS** |
| 8 Record queries/sources/coverage/freshness/honest no-match | **PASS** |
| 9 Auto-rediscover CJ PID `2609290358281623700` from the FastMoss ski mask WITHOUT the PID | **PASS** — via `"scary balaclava"` p.3, 13 CJ calls → `SAME_PRODUCT_IDENTITY`/`MEDIUM`/8 variants |
| 10 Negative test + ≥1 additional genuine product; fix failures, re-test | **PASS** — LED mask resolves; wreath/door-cover correctly held |
| 11 Verify results reach the customer card with correct confidence/variants/rights | **PASS** (data proven; founder confirms pixels) |

**Overall: PASS.** The search automatically finds and recognises the same underlying supplier product across
different names, descriptions and languages, proven by auto-rediscovering the ski-mask CJ PID without it being
supplied, by generalising to a second genuine product, and by correctly refusing two negatives.

### Remaining Stage-4B blockers (honest coverage limits — not failures of this unit)
1. **Lexicon coverage** — strong recognition currently covers the novelty-face-mask / skincare-mask /
   wall-art families (9 families, 73 rows). Products outside these fall back to the base expander and may not
   surface a CJ match; this is reported honestly (source ≠ `LEXICON_IDENTITY_EXPANSION`), never faked. Growing
   the lexicon is the lever for broader coverage.
2. **CJ `product/list` relevance** — CJ's keyword ranking is weak (broad queries bury the target; narrow
   distinctive queries surface it), which is exactly why the lexicon expander emits narrow, distinctive 2-word
   queries. Target found at rank ~53/707 for a narrow query vs buried in 47,444 for a broad one.
3. **Stage-1 economic gate** — the ski mask passes only 1 of the 2 required demand-evidence families, so the
   *automatic Stage-2 claim* (`fn_stage2_cj_search_claim`) does not fire for it on its own. That is a
   deliberate, separate economic gate; the **identity mechanism** itself is proven by invoking the
   retrieval-plan → CJ paginate → recognition path directly. No change was made to the economic gate.

No paid calls, no roadmap advancement (no DataForSEO / AliExpress / BigBuy). **STOP within Stage 4B.**
