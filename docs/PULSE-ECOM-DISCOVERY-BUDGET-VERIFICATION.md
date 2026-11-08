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
