# PULSE-ECOM-STAGE2-CANONICAL-SUPPLIER-QUERY-EXPANSION-001

**Launch-critical B3 fix (`mig_300`): resolved canonical Product Identity now expands into accurate,
product-specific CJ supplier-search queries. Generic, deterministic, production-safe. PASS (10/10 +
regression 10/10). No CJ calls; $0.00. Pagination intentionally out of scope.**

## Confirmed defect
The canonical identity (e.g. Krippen → `NATIVITY_SCENE` + `ILLUMINATED` + `FORM:WALL_DECORATION`,
derived correctly by `fn_derive_concrete_product_identity` / `fn_canonical_concepts`) was never converted
into supplier-catalogue search terms. The CJ query was a language-preserving phrase
(`fn_product_search_identity` → German) or a hand-supplied external term, so the distinctive
`NATIVITY_SCENE` concept never reached CJ `product/list`. The cross-language matcher
(`fn_market_supplier_match`) was already correct; the gap was purely at retrieval/query-generation.
Consequence: the prior Krippen `NO_VALID_CJ_MATCH` did **not** establish that CJ lacks the product.

## Fix (generic, not Krippen-specific)
- **`fn_supplier_search_terms(match_spec) → jsonb`** (IMMUTABLE, pure): maps the canonical distinguishing
  concepts to supplier-catalogue surfaces via a concept→surface lexicon; builds a bounded (≤8), deduped,
  ≤6-token query set. Defining **noun** concepts drive the query (recall-first bare surfaces), enriched
  with the primary attribute/form (precision variants). Generic season markers (`CHRISTMAS`) are never
  emitted standalone and can never replace the defining identity. Unknown concepts are handled gracefully
  (humanized noun / form). Falls back to the source-language `product_noun` phrase when no canonical
  concept exists (no regression for English-source or non-canonicalizable products).
- **`fn_stage2_supplier_search_queries(tenant, product, market) → jsonb`** (STABLE, SECURITY DEFINER):
  the production entry point. Verifies tenant ownership (fail closed → `not_owned`), derives the concrete
  identity, returns the bounded query set + the current (unchanged) `page_num=1/page_size=20` window.
  The Stage-2 orchestrator / n8n `stage2-cj-supplier-search` workflow should call this to obtain queries
  instead of a hand-supplied `search_query`.
- **`fn_resolve_concrete_supplier_identity`**: the internal SQL candidate fallback (`p_candidates IS NULL`)
  now pre-selects from `commerce_supplier_products` using the **expanded** supplier terms (cross-language)
  **UNION** the raw `product_noun` tokens (no recall regression). All other resolver logic — match spec,
  `fn_market_supplier_match`, qualify logic, exclusions, form-conflict, thresholds, persistence, tenant
  scoping, provenance — is unchanged. Matching strictness is **not** weakened; similar products are **not**
  promoted to exact identity.
- Least privilege: all three functions `EXECUTE` revoked from `PUBLIC`/`anon`/`authenticated`, granted to
  `service_role`.

## Krippen deterministic query output (after fix)
`source=CANONICAL_EXPANSION`, 8 queries:
`nativity scene` · `nativity set` · `christmas crib` · `creche` · `manger scene` ·
`nativity scene wall decoration` · `led nativity scene` · `led nativity scene wall decoration`
(primary: `nativity scene`).

## Verification
- **`fn_stage2_query_expansion_selftest()` → 10/10** (service_role only): nativity reaches query gen;
  ≥2 nativity surfaces; illumination + wall-decoration preserved; generic never replaces defining identity;
  no bare generic/attr query; bounded (8) + deduped + ≤6 tokens; unknown-concept genericity; source-phrase
  fallback; genuine nativity wall-decoration qualifies `STRONG_SAME_PRODUCT`; wall lamp rejected
  (`CATEGORY_ONLY`, form conflict).
- **Regression `fn_stage2g_boundary_integrity_selftest()` → 10/10**: Krippen history, country isolation
  (DE✓/JP✗), tenant isolation, branded-exclusion, one-family guard, Stage-2E fail-closed all intact.
- **Tenant isolation**: `fn_stage2_supplier_search_queries` with a non-owner tenant → `not_owned`.
- **End-to-end (read-only, persist=false)**: the internal cross-language fallback now surfaces a genuine
  nativity product (`"9FT Lighted ... Inflatable Nativity Scene ... LED Lights"`) previously invisible to
  the German-substring filter. It correctly stays `NO_VALID_CJ_MATCH` (qualifying 0) because it is an
  inflatable **yard** nativity, not a `FORM:WALL_DECORATION` — the exactness guard holds (no false positive).

## Remaining limitation (next stage)
CJ retrieval depth is still `pageNum=1 / pageSize=20` (one page per query). The exact product could exist
in CJ but rank beyond the top-20 window. Bounded CJ pagination / recall-depth is the next unit, to be
done before any authorized Krippen live revalidation — so that a negative revalidation is meaningful.

## Boundaries honored
No live CJ call; no provider spend ($0.00); no retrieval-depth change; no change to identity resolution,
Stage-1 qualification, supplier state, matching strictness, Product Asset Lock, or country/tenant isolation.
No production product-data writes (demonstration used `persist=false`; self-tests use rollback fixtures).
