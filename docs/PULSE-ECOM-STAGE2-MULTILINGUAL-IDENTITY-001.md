# PULSE-ECOM-STAGE2-MULTILINGUAL-IDENTITY-001

**Multilingual Product Identity → CJ search (`mig_301`), extending the B3 fix (`mig_300`). Generic,
deterministic, reuses existing architecture; NO new paid service / NO translation API. PASS
(8/8 multilingual + 10/10 B3 expansion + 10/10 Stage-2 boundary regression).**

## Root cause
Non-English terminology was converted to a language-independent canonical identity only when its exact
surface was in `fn_canonical_concepts`' lexicon, and that lexicon was (1) **accent-sensitive** — accented
French/Italian/Spanish/Portuguese/Polish spellings (e.g. "crèche", "éclairé", "iluminación",
"podświetlana") failed to match the unaccented surfaces — and (2) **narrow**. When canonicalisation
produced nothing, the supplier query fell back to the source-language phrase and failed against CJ's
English `productNameEn`.

## Changes
- **`fn_fold_accents(text)`** — deterministic diacritic folding (DE/FR/IT/ES/PT/PL/NL + Nordic) via
  `translate()` plus `replace()` for the ß/æ/œ digraphs. IMMUTABLE; no extension (`unaccent` is not
  installed, and there is no translation service in the stack — this reuses only built-ins).
- **`fn_canonical_concepts`** — folds the input before lexicon matching and broadens the multilingual
  recognition surfaces across the 18 markets' languages for the existing concepts, plus adds a second
  product family (**HUMIDIFIER**) to prove the mechanism is generic, not nativity-specific. Output
  contract (concepts / distinguishing / surfaces) unchanged, so `fn_market_supplier_match`,
  `fn_derive_concrete_product_identity` and `fn_supplier_search_terms` consume it unchanged. English
  titles are unaffected (folding is a no-op on ASCII).
- **`fn_stage2_supplier_search_queries`** (contract v2) — adds `language_coverage_gap` observability:
  when a non-English market yields `SOURCE_PHRASE_FALLBACK` (no canonical concept), the response flags the
  supplier query as a low-confidence source-language fallback, so the orchestrator does not treat a
  German/French query as a confident English search. Fail-safe and honest; it does not fabricate a
  translation.
- English query GENERATION is unchanged (`fn_supplier_search_terms`, mig_300): a newly-recognised concept
  with no explicit English surface is humanised there, so it flows end-to-end without a second lexicon edit
  (e.g. `HUMIDIFIER → "humidifier"`).

## How non-English → English now works (deterministic, no translation API)
`title (any language)` → `fn_fold_accents` → `fn_canonical_concepts` (surface→language-independent concept)
→ `match_spec.canonical_*` → `fn_supplier_search_terms` (concept→English supplier surfaces) → bounded,
deduped English CJ queries. Translation is **query expansion only**; it never becomes identity evidence,
and matching strictness / form-conflict detection are unchanged.

## Verification (no CJ calls; $0.00; no writes)
- **`fn_stage2_multilingual_selftest()` → 8/8**: accent-fold (FR/ES/PL/DE); French "Crèche de Noël
  lumineuse décoration murale" → `NATIVITY_SCENE+ILLUMINATED+FORM:WALL_DECORATION`; Spanish "Belén
  iluminado"; Italian "Presepe illuminato decorazione da parete"; French spec → English queries
  (`nativity scene`, …); German "Luftbefeuchter mit LED" → `HUMIDIFIER` → English `humidifier` (generality);
  English title unchanged; a French supplier title matches a German-sourced nativity spec
  (`STRONG_SAME_PRODUCT`, cross-language).
- **`fn_stage2_query_expansion_selftest()` → 10/10** (B3, mig_300): no regression.
- **`fn_stage2g_boundary_integrity_selftest()` → 10/10**: Krippen history, country isolation (DE✓/JP✗),
  tenant isolation, branded-exclusion, one-family guard, Stage-2E fail-closed all intact.

## Preserved
Original product names and source evidence; per-country (18-market) independent intelligence and isolation;
tenant isolation; exact matching strictness and form-conflict detection; Product Asset Lock. No change to
CJ pagination; no live CJ/Apify calls.

## Remaining blocker
Coverage is **lexicon-bounded**: a non-English product noun with no `fn_canonical_concepts` entry still
falls back to the source-language phrase (now flagged `language_coverage_gap`). Fully general translation
of arbitrary product terminology would require a translation service or LLM step (out of scope — no new
paid service). The mechanism is extensible one row at a time; the gap is observable, not silent. CJ
retrieval window (`pageNum=1/pageSize=20`) remains the separately-tracked next unit.
