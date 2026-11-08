# Germany Discovery Wave — Provider-Budget Verification (2026-11-08)

Read-only check of the live budget controls. **No chargeable discovery requests made.** Verdict: **BLOCKED** (fail-closed) —
the in-system spending controls are all OFF; no authorised allowance exists for any discovery provider.

## Actual state (production `nxaunmyihhjixxxljcqt`)
| Control | State | Meaning |
|---|---|---|
| `provider_call_budget` | Only 2 rows, both **inactive, expired, fully consumed** (TESTPROV/FASTMOSS GB selftests, 2026-10-19) | **No active allowance** for KALODATA, FASTMOSS, DATAFORSEO or CJ in any market, including DE |
| `research_budget_config` | `enabled=false`, `monthly_cap_micro=0`, `per_run_cap_micro=0`, `authorized_market=null` | DataForSEO / local-price research path **disabled with zero caps** |
| Vendor credit balances (Kalodata credits, FastMoss allowance, DataForSEO balance) | **Not recorded in the database** | Held on the vendor accounts / edge secrets; cannot be read from here. Only in-system note: Kalodata "0.1 credit / 10 products" verified in DE earlier (proves credits existed then; current balance unknown from DB) |
| `provider_call_ledger` | Empty | No logged chargeable calls |
| CJ provider (`commerce_supplier_provider_config`) | `CJDROPSHIPPING` enabled, `AVAILABLE` | Provider is live, but each call still needs an active `provider_call_budget` |

## Answers to the six checks
1. **Kalodata credits / consumption:** consumption rule = 0.1 credit / 10 products (per `product/rank`). **Remaining credit balance is not in the DB** (vendor-side) — founder must confirm.
2. **FastMoss allowance:** no active `provider_call_budget`; vendor plan/allowance not in DB.
3. **DataForSEO balance:** research budget disabled (caps 0); vendor balance not in DB.
4. **CJ request allowance:** provider AVAILABLE, but **no active `provider_call_budget`** → calls would be rejected.
5. **`provider_call_budget` controls:** present and **fail-closed**; currently hold **no active authorisation**.
6. **Does the DE wave need additional payment?** **Cannot be determined from in-system data** — the system has no provider balances. It definitely needs **additional PERMISSION** (authorising budgets); whether it needs new **money** depends on whether the vendor accounts already hold credits, which only the founder can confirm.

## Verdict: **BLOCKED** — not executable within already-authorised allowances (there are none active)
Precise blockers (all internal-authorisation, not code):
- **B1.** No active `provider_call_budget` for DE — needed for KALODATA, FASTMOSS and CJ (each: `approval_key`, `max_calls`, `market=DE`, short `expires_at`).
- **B2.** `research_budget_config` disabled with zero caps — needed for DataForSEO demand + local-price validation (enable + `authorized_market='DE'` + a per-run/monthly cap).
- **B3.** Vendor credit balances unverifiable from here — founder confirms Kalodata credits / FastMoss plan / DataForSEO balance exist (or tops up).

## Next executable action
Founder authorises the capped DE budgets (B1 + B2) and confirms vendor credits exist (B3). On that authorisation I create the
capped `provider_call_budget` rows (Kalodata ≤2 credits-worth of calls, FastMoss ≤15 calls, CJ ≤40 calls) + enable the
research cap (≤$3, market=DE), then run the DE wave strictly within them — no orders, ads, billing or AliExpress. I did **not**
create any budget row or spend, per the no-chargeable-requests rule. Canonical 79-product exclusion set preserved; no
substitution of prior products.

## Minimum founder-side confirmations for the proposed DE gate (2026-11-08)
Proposed limits (NOT yet authorisation): Kalodata ≤1 credit · FastMoss ≤5 calls · DataForSEO ≤$1 · CJ ≤10 calls · DE only · ≤20
new candidates. The **only remaining blocker is account-level vendor confirmation** (all read from each vendor's own
dashboard — **no API secret is needed or should be shared**):

| Provider | Minimum fact the founder confirms | Where to read it | Needed for |
|---|---|---|---|
| **Kalodata** | Remaining credit balance **≥ 1 credit** (+ DE/TikTok-Shop region active) | Kalodata account → Credits/Billing | ~1 credit ≈ 100 products of product-rank |
| **FastMoss** | Active plan allows **≥ 5** New-Listed rank calls (DE) | FastMoss account → Plan/Quota | 5 new-listed pages |
| **DataForSEO** | Prepaid account **balance ≥ $1.00** | DataForSEO dashboard → Balance | demand + local-price validation |
| **CJ Dropshipping** | **API access active** (app key valid/not expired), product query + detail endpoints available, within rate limits — no credit purchase (catalogue reads are order-billed, not per-call) | CJ → Developer/API settings | exact-SKU match + media/stock/freight |

On the founder's **explicit approval of the limits + a yes to all four** (or a corrected number), I will: create the DE-only,
short-expiry, approval-gated `provider_call_budget` rows at exactly those caps + enable `research_budget_config`
(`authorized_market='DE'`, cap $1), run the DE discovery wave, dedup against the 79 canonical identities, score via the
existing engine, and report the fresh candidates — all strictly within caps, no purchases/orders/ads/billing/signup.

## Read-only balance retrieval attempt (2026-11-08) — not possible in-platform
Checked whether the connected accounts expose read-only balance/allowance **without a chargeable call**. **They do not,
via any existing in-platform path:**
- The only provider edge functions are `kalodata-discovery`, `fastmoss-discovery`, `fastmoss-product-detail` — all make
  **paid, budget-gated** rank/detail calls (they are fail-closed with no active budget); **none is a free balance/account
  check.** CJ has **no edge function** (it runs via n8n). There is **no `*-balance` / `*-account` function** of any kind.
- Provider API **credentials are edge-function secrets** — not accessible here, and must not be exposed. I therefore
  cannot call any provider's own free balance endpoint (e.g. DataForSEO `/v3/appendix/user_data`) from this environment,
  and building a balance-check function would be new architecture (out of scope).
- **No provider call was made** (invoking a discovery function would be a chargeable, budget-gated call — not done).

**Conclusion: all four balances require founder dashboard confirmation** (read-only, no secret shared):
| Provider | Where the founder reads it | Needed |
|---|---|---|
| Kalodata | Kalodata account → **Credits / Billing** | credits ≥ 1 |
| FastMoss | FastMoss account → **Plan / API usage** | ≥ 5 New-Listed calls allowed |
| DataForSEO | DataForSEO dashboard → **Balance** (or the free `appendix/user_data` if they check it themselves) | balance ≥ $1 |
| CJ Dropshipping | CJ → **Developer / API** (app key active, not expired) | API access active |
