# PULSE-ECOM-STAGE2-CJ-SUPPLIER-SEARCH-001

**Stage 2E — Permanent parameterized, SEARCH-ONLY CJ product-search operation.**

## Root cause (production gap)

The only CJ product-search path was `Pulse — Research Executor: CJ (013K)`
(`vjVn6gILqw4lGYpG`), which:

1. **Hardcodes** `productNameEn = "star projector night light"` — no runtime product-search input.
2. Has a bare **manual trigger** that accepts no parameters.
3. Is **coupled to Stage-1** `fn_research_ingest_source` under a fixed research-run id.

During the Krippen Stage-2D search this forced a temporary mutate → disable-ingest → run → restore
cycle on a production workflow. That is not a safe, reusable Stage-2 supplier-search interface.

## Fix

New workflow **`Pulse — Stage-2 CJ Supplier Search (search-only)`** (`nnoDjxtEeTqwC6q6`), INACTIVE/unpublished.
Reuses existing architecture only — **no** new CJ integration, **no** new credentials, **no** edge function,
**no** new Supabase migration. The existing resolver `public.fn_resolve_concrete_supplier_identity` is
reused **unchanged**.

Flow (linear, one CJ call per invocation):

```
Webhook (runtime input)
  -> Validate Input      (fail-closed: uuid tenant_id+product_id, non-empty market+search_query)
  -> Verify Owner        (Supabase: commerce_products?id=eq&user_id=eq, reused supabaseApi cred)
  -> Assert Owned        (fail closed before any CJ call unless id == product_id)
  -> CJ Auth             (reused CJ httpCustomAuth credential)
  -> CJ Search           (CJ product/list, productNameEn = RUNTIME search_query)
  -> Build Candidates    (normalize to Stage-2 candidate shape; does NOT judge matches)
  -> Resolve Identity    (POST rpc/fn_resolve_concrete_supplier_identity, p_persist from input)
  -> Build Response      (echo request_id, candidate_count, resolver verdict, bound)
```

## Runtime input contract

| field | required | notes |
|---|---|---|
| tenant_id | yes | uuid; fail closed otherwise |
| product_id | yes | uuid; fail closed otherwise |
| market | yes | upper-cased |
| search_query | yes | non-empty; **never hardcoded** |
| request_id | no | idempotency key, echoed in response |
| persist | no | boolean, default **false** |

Malformed input → `STAGE2_INPUT_INVALID`. Tenant/product mismatch → `STAGE2_TENANT_PRODUCT_NOT_OWNED`
(thrown before any CJ call). The resolver independently re-checks tenant ownership
(`product_not_found_for_tenant`) as a second gate.

## Output candidate contract (Stage-2 shape)

```json
{ "supplier": "CJ", "supplier_product_id": "...", "sku": "... | null",
  "title": "...", "category": "... | null", "variant": null,
  "supplier_reference": "sku || supplier_product_id" }
```

n8n only **retrieves** candidates. **Supabase determines equivalence** via the unchanged resolver.
No match is declared inside n8n.

## Decision contract (resolver, unchanged)

- 0 qualifiers → `NO_VALID_CJ_MATCH`
- 1 qualifier → `EXACT_SUPPLIER_IDENTITY_RESOLVED`
- >1 qualifiers → `CONCRETE_PRODUCT_AMBIGUOUS`

Persistence: `p_persist=false` evaluates only (never binds); `p_persist=true` upserts on
(tenant, product, market) and binds **only** on EXACT.

## Hard boundaries (SEARCH != SOURCING)

Never: `fn_research_ingest_source`, `cj_sourcing_requests`, orders, payments, product import/publish,
supplier-asset retrieval, commercial-approval/economics. There are no nodes for any of these.

## Idempotency / cost safety

One CJ auth + one CJ product/list call per invocation; linear chain, no loops, no retry-on-fail fan-out;
`request_id` carried through and echoed. Cross-invocation persistent dedup is intentionally deferred
(not overengineered); the single-call-per-invocation guarantee plus caller-supplied `request_id` is the
minimum protection.

## Test results (fixtures / dry-run — zero live CJ calls)

| # | test | result |
|---|---|---|
| 1 | runtime query replaces hardcoded | PASS (Validate output carries request `search_query`; no hardcoded query in def) |
| 2 | two queries isolated | PASS (Test A vs Test D independent contexts) |
| 3 | context required | PASS (missing fields → STAGE2_INPUT_INVALID) |
| 4 | invalid context fails closed | PASS (execution errors, no downstream) |
| 5 | Stage-1 ingest never called | PASS (no such node) |
| 6 | no cj_sourcing_requests | PASS (no such node) |
| 7 | tenant isolation | PASS (not-owned → STAGE2_TENANT_PRODUCT_NOT_OWNED, CJ never runs) |
| 8 | candidate shape | PASS (exact Stage-2 shape) |
| 9 | candidates feed resolver | PASS (rpc_body p_candidates) |
| 10 | 0 qualifier → NO_VALID_CJ_MATCH | PASS (Krippen 38-candidate evidence) |
| 11 | 1 qualifier → EXACT (dry run) | PASS (p_persist=false, selected TEST-Q1, not persisted) |
| 12 | >1 qualifiers → AMBIGUOUS | PASS (p_persist=false) |
| 13 | p_persist=false cannot bind | PASS (Krippen row unchanged after EXACT dry run) |
| 14 | retry/idempotency protection | PASS (single CJ call per execution; retryOnFail off) |
| 15 | 013K unchanged + functional | PASS (restored verbatim; hardcoded term + ingest intact) |
| 16 | no secrets exposed | PASS (credential refs by id only) |

## Deployment status

Built, validated (9 nodes), fixture-tested, saved as **inactive/unpublished draft**. The webhook endpoint
is NOT live until the founder explicitly publishes. Recommended before activation: add webhook auth
(e.g. header-auth credential) and run one authorized live smoke test against a genuinely Stage-1-qualified,
non-IP product.

## 013K production-gap classification

`Pulse — Research Executor: CJ (013K)` remains the **Stage-1** research executor (unchanged). The Stage-2
search path is now this separate workflow. 013K does not need changing for Stage-2 and should not be
repurposed; if Stage-1 ever needs a parameterized term, that is a separate change.

---

## Stage-2E hardening addendum (persistent idempotency + webhook auth)

The initial build relied on caller-side `request_id` echo, which does not guarantee that one logical request
cannot fan out into multiple CJ searches. This addendum closes that defect durably.

### Durable, concurrency-safe idempotency (`mig_292`)

New ledger `public.commerce_stage2_search_request` with `UNIQUE (tenant_id, opportunity_product_id, market,
request_id)` and two SECURITY DEFINER functions (mirrors the `social_publish_attempts.idempotency_key` pattern):

- `fn_stage2_cj_search_claim(tenant, product, market, request_id, search_query)` — atomic
  `INSERT … ON CONFLICT DO NOTHING`. Returns `proceed=true` to the single caller whose INSERT wins; every other
  caller for the same logical key gets `duplicate=true, proceed=false` with the stored result. Fails closed if the
  tenant does not own the product or any key field is missing. The unique index serializes concurrent identical
  claims, so two near-simultaneous duplicates can never both proceed.
- `fn_stage2_cj_search_complete(tenant, product, market, request_id, result, provider_called)` — records the
  result on the claimed row, enabling duplicate replays to return the cached result with no CJ call.

### Hardened flow

```
Webhook (header auth: x-pulse-webhook-secret)
  -> Validate Input      (request_id now REQUIRED; fail closed)
  -> Verify Owner -> Assert Owned
  -> Claim Request       (atomic idempotency gate)
  -> Assert Claim OK     (fail closed on claim rejection)
  -> IF Proceed
       true  -> CJ Auth -> CJ Search -> Build Candidates -> Resolve Identity -> Complete Request -> Build Response
       false -> Duplicate Replay Response   (cached result; CJ NEVER called)
```

### Webhook authentication

The webhook uses n8n header auth bound to the shared inbound credential `Header Auth account 4`
(header `x-pulse-webhook-secret`) — the same credential guarding existing production Pulse webhook workers.
The secret value lives only in the n8n credential store (never in repo, workflow JSON, query string, logs, or
response bodies). Auth is enforced at the webhook layer before any node runs, so it precedes CJ.

### Hardening test results (fixtures / SQL dry-run — zero live CJ calls)

| # | test | result |
|---|---|---|
| 1 | valid authenticated request accepted | PASS (proceed path, exec 30476) |
| 2 | missing/invalid auth rejected before CJ | CONFIG-ENFORCED (headerAuth bound); provable only by live probe post-activation |
| 3 | missing request_id rejected | PASS (STAGE2_INPUT_INVALID: request_id_missing_or_malformed) |
| 4 | first logical request allowed | PASS (claim proceed=true) |
| 5 | exact duplicate does NOT reach CJ | PASS (exec 30477: only Duplicate Replay Response ran; CJ Auth/Search/Resolve/Complete absent) |
| 6 | concurrent duplicate cannot both acquire | PASS (unique index + ON CONFLICT DO NOTHING; 1 row per key) |
| 7 | same request_id + different tenant cannot collide | PASS (distinct key; cross-tenant also fails closed) |
| 8 | same request_id + different product cannot collide | PASS (distinct key → proceed=true) |
| 9 | different request_id may execute independently | PASS (proceed=true) |
| 10 | p_persist=false cannot bind | PASS (resolver dry-run; persist passed through false) |
| 11 | Stage-1 ingest absent | PASS (no fn_research_ingest_source node) |
| 12 | sourcing/order absent | PASS (no such nodes) |
| 13 | existing 013K unchanged | PASS (not touched) |
| 14 | no secrets exposed | PASS (credential refs by id; secret in n8n store; header NAME is not a secret value) |

### Activation status (post-hardening)

Idempotency is deployed (`mig_292` live) and fully verified. Webhook auth is deployed (bound to the production
inbound-webhook credential). The workflow remains **INACTIVE/unpublished**: the auth *rejection* can only be
proven against a live endpoint, so activation + a one-shot live auth probe (missing header → 401; valid header →
200) is the single founder-gated remaining step before the first authorized live CJ smoke test.
