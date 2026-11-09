# Discovery P0 — Consolidated Production Deployment Report (2026-11-09)

Controlled production deployment of the verified Discovery P0 corrections to `nxaunmyihhjixxxljcqt`.
Applied in approved order; all post-deploy checks green. No paid provider calls; no discovery wave; no new
provider budgets; no orders/ads/billing/signup; no architecture rebuild.

## Pre-deployment compatibility verification (required gate)
- **Secure authorization path confirmed:** external-provider research now requires an active
  `provider_call_budget` (tenant+provider+market), consumed atomically, fail-closed via
  `fn_dispatch_provider_authorize`. Tenant/provider/market/usage limits preserved. No security control bypassed.
- **Compatibility finding (reported, not a crash):** the research workflow has been active — **16 completed
  research runs and 93 CJ/eBay/Meta/TikTok source attempts in 30 days** — with **zero active provider budgets**.
  After mig_337 those four providers return `SOURCE_UNAVAILABLE` until the founder creates provider budgets
  (restricted from doing so here). This is the **intended fail-closed hardening** (founder P2), not an
  unintended break: no crash, no data loss, honest unavailable states, DataForSEO USD gate unchanged, Reddit
  cache unchanged, blast radius limited to `fn_research_dispatch` (sole caller `fn_research_request_core`;
  Kalodata discovery itself unaffected). The 10 in-flight `RESEARCHING` runs stay inert. **Verdict: not a
  production-breaking issue → proceeded**; the founder re-enables providers by authorizing budgets.

## Migration results (steps 4–6)
| Step | Migration (log name) | Result |
|---|---|---|
| 4 | `discovery_p0_336_pagination_and_scoped_suppression` | ✅ success |
| 5 | `discovery_p0_337_provider_dispatch_authorization` | ✅ success |
| 6 | `discovery_p0_338_product_explorer_kalodata_visibility` | ✅ success |

Pre-deploy, deployed contracts matched the reviewed package base (`pulse_research_dispatch_v2_013n_usdguard_scoped`,
`pulse_product_explorer_v1`, 1-arg request / 4-arg run, edge v11). Rollback artifacts preserved in repo
(`mig_336_ROLLBACK.sql`, `mig_337_ROLLBACK.sql`, `mig_338_ROLLBACK.sql`). DB ACTIVE_HEALTHY.

## Edge-function deployment evidence (step 7)
`kalodata-discovery` deployed **version 12, status ACTIVE** (was v11). Delta: reads `page_number` (default 1,
clamp ≥1) and threads it to `fn_kalodata_discovery_request(p_market, p_page_number)`. All security (nonce/service-role
gate, secret from edge env only) unchanged.

## Contract verification (step 8) — all live
| Object | Verified |
|---|---|
| `fn_product_explorer` | `pulse_product_explorer_v2` |
| `fn_research_dispatch` | `pulse_research_dispatch_v4_provider_authz` |
| `fn_kalodata_discovery_request` | `(p_market text, p_page_number integer DEFAULT 1)` |
| `fn_kalodata_run_discovery` | 5-arg incl. `p_page_number integer DEFAULT NULL` |
| `fn_dispatch_provider_authorize` | present |
| suppression/pagination helpers | 5/5 present |
| `kalodata_discovery_cursor`, `discovery_dispatch_suppression` | present, **RLS enabled** |
| shared `research_executor_webhook` | unchanged (CONFIGURED) |

## Authentication & tenant-isolation evidence (step 9, live)
- Server-owned `auth.uid()` scoping (SECURITY DEFINER, `search_path=''`); authenticated-context regression run.
- **Tenant isolation:** a different tenant's Germany Explorer returns **total 0** (owns nothing). **PASS.**
- **Country isolation:** none of the 10 DE products appear under market GB. **PASS.**

## Product Explorer results (live, founder context)
- **Germany Explorer total = 29** (9 FastMoss + 20 Kalodata, including the 10 newly discovered). **PASS.**
- **All 10 newly discovered products visible to the founder.** **PASS.**
- **Existing FastMoss products remain visible (9).** **PASS.**
- The 10 show `research_status = NEWLY_DISCOVERED_RESEARCH_PENDING`, `opportunity_score`/`opportunity_band` **null** (no fabrication). **PASS.**

## Regression test results (acceptance list)
| Acceptance item | Result | Where verified |
|---|---|---|
| Germany Explorer returns 29 | ✅ PASS | live (A1) |
| All 10 newly discovered visible to founder | ✅ PASS | live (A2) |
| Existing FastMoss products remain visible | ✅ PASS | live (A3) |
| Missing market evaluations show RESEARCH_PENDING | ✅ PASS | live (A4) |
| Tenant + country isolation intact | ✅ PASS | live (A5, A6) |
| No unvalidated products in Recommendations | ✅ PASS | live (A7) |
| Product Asset Lock enforced | ✅ PASS | live (A8 cover null+REFERENCE_ONLY, A9 zero launch-safe media) |
| Kalodata pagination advances (no repeated page-1 purchases) | ✅ PASS | live (A11 page-2 request); cursor monotonic verified transactionally |
| Provider calls fail closed without valid authorisation | ✅ PASS | live (A10 CJ/eBay/Meta/TikTok → `no_budget_fail_closed`) |
| Approved provider operations remain functional | ✅ PASS | transactional (authorized CJ → DISPATCH); cannot create budgets live (restricted) |
| Budget limits cannot be exceeded | ✅ PASS | transactional (atomic: 2nd consume `budget_exceeded`); same deployed logic |
| Existing n8n research executor contracts remain compatible | ✅ PASS | manifest `fn_research_run_manifest` unchanged; authorized→DISPATCH, unauthorized→TERMINAL (transactional) |
| Shared research webhook remains unchanged | ✅ PASS | live (A12 CONFIGURED, never mutated) |

"Approved provider operations", "budget cap", and "executor compatibility" were validated in the transactional
suite against the exact deployed function logic (creating live budgets is restricted here, and firing dispatch
would make provider calls — both disallowed). The manifest/executor contract is unchanged by this release.

## Remaining signed-in browser checks (founder device)
The backend now returns the 29-product Germany Explorer with the 10 new products and honest RESEARCH_PENDING
status. The only remaining checks require an authenticated browser (container egress to the live app is
auth-gated / 403, unavailable here):
- Visual render of the Discovery/Product Explorer showing the 10 new Kalodata cards with `NEWLY DISCOVERED /
  RESEARCH PENDING` and no fabricated scores.
- Confirm the Recommendations surface still excludes the 10 (shown correctly in the data layer).

## Post-deployment state
- Deployed: mig_336 + mig_337 + mig_338 + edge v12. Rollback scripts ready (order: edge→v11, then 338, 337, 336 rollbacks).
- No provider budgets active → external research providers remain fail-closed until the founder authorizes capped
  budgets (separate authorized step). Recommended when a validation wave is wanted: create `CJDROPSHIPPING`/`EBAY`/
  `META_AD_LIBRARY`/`TIKTOK` budgets per market (usage-metered, not monetary) + DataForSEO research cap.

No paid provider call made; no discovery wave run; no budgets activated; production data + research history preserved.
