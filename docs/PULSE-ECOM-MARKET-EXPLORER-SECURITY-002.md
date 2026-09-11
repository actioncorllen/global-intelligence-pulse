# PULSE-ECOM-MARKET-EXPLORER-SECURITY-002

**VERDICT: PASS.** The launch-critical tenant-isolation defect in the Market Explorer RPCs is
closed. The authenticated browser can no longer choose a tenant; the authorized tenant is
derived server-side from `auth.uid()` using the repository's canonical `member.application_ref`
model. Least-privilege grants verified; cross-tenant and unauthenticated attacks proven
impossible. No customer publication; `campaign_activation=FALSE`; `advertising_spend=0`.

## Defect (root cause)
`fn_product_country_explorer` / `fn_market_comparison` / `fn_country_evaluation_state` accepted a
**client-supplied `p_tenant`** and were EXECUTE-granted to `authenticated`. A logged-in user
could read any tenant's Product × Country evaluations by passing another tenant's UUID. The core
also returned `is_fixture` rows into any tenant's result (fixture leak).

## Fix (mig_217)
- **Reused convention:** `auth.uid() → public.member (UNIQUE auth_user_id) → member.application_ref`,
  exactly as `get_own_business_profile` / `get_own_discovery_intelligence`. No new identity model.
- **`fn__own_tenant()`** — resolves the tenant; `count(*)<>1` fails closed (0 = no member, >1 =
  ambiguous); returns NULL when unauthenticated / no member / no application yet. Definer-only.
- **Hardened core** — strict `tenant_id = p_tenant` (dropped the `OR is_fixture` leak); EXECUTE
  **revoked from `authenticated`, `anon`, `PUBLIC`** (definer / service-role only).
- **`fn_own_product_country_explorer(p_product_id, p_selling_markets)`**,
  **`fn_own_country_evaluation_state(p_product_id, p_country)`**,
  **`fn_own_market_comparison(p_product_id, p_countries)`** — the ONLY market-explorer surface
  granted to `authenticated`. They derive the tenant from `auth.uid()`, delegate to the hardened
  core, and fail closed (`unauthenticated` / `not_found` / `temporary_failure`). They never fall
  back to a fixture, founder, first, public or client-supplied tenant.
- **SECURITY DEFINER safety** — `SET search_path TO ''`, every object schema-qualified,
  `auth.uid()` schema-qualified; blanket `EXCEPTION WHEN OTHERS → temporary_failure` (no leak).

## Product authorization
`product_market_evaluations` is the only tenant-sensitive surface and is filtered strictly by the
resolved tenant, so another tenant's private evaluation is never returned — a cross-tenant
product-UUID attack yields `evaluated_count = 0`. The global `ecommerce_market_universe`
(country capability, non-sensitive) is intentionally shared, keeping global market scope separate
from tenant authorization.

## Grants (verified least-privilege)
| Function | authenticated | anon | service_role |
|---|---|---|---|
| `fn_own_product_country_explorer` / `fn_own_country_evaluation_state` / `fn_own_market_comparison` | **EXECUTE** | – | EXECUTE |
| `fn__own_tenant`, `fn_product_country_explorer`, `fn_market_comparison`, `fn_country_evaluation_state`, `fn_market_candidacy_screen` | – | – | EXECUTE |

## Security tests (JWT-claim simulation; seed under two members' application_refs, then delete)
| Scenario | Result |
|---|---|
| Unauthenticated (no `sub`) | `status = unauthenticated` |
| Member with no `application_ref` | `status = not_found` |
| Member A (tenant `95bb5658…`) | sees only A's DE **TEST(88)**; `evaluated_count = 1` |
| Member B (tenant `dae30000…`) | sees only B's DE **AVOID(40)**; `evaluated_count = 1` |
| Cross-tenant **tenant** attack | impossible — own RPCs expose no `p_tenant` argument |
| Cross-tenant **product-UUID** attack (fixture product) | `evaluated_count = 0`, `global_opportunity = null` (no leak) |

Product × Country scoring, global-best, and best-within-selling behaviour are unchanged. Test
rows were deleted after verification (`product_market_evaluations` back to 27). Overall paid-beta
engineering readiness ≈ **84%** (unchanged; blocker cleared).
