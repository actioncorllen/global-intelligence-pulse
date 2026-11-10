# Bounded Live Refresh Discovery Test — RESULT (2026-11-10) — PASS

Executed under explicit founder authorisation. One paid Kalodata call only. System returned to fully fail-closed
afterward; all audit records preserved. Product = Strateloq.

## Scope executed
Tenant `7c8ddf9d-172c-4a89-a402-bb7066228b61` (Founder Ecommerce Test) · market **DE** · provider **Kalodata**
`tiktok/product/rank` · request `3934bbe1-bc7c-4b81-b6e1-d04258edec2c` · net request `181`.

## Result: **PASS**

| Acceptance check | Result |
|---|---|
| Kalodata call count | **1** (net responses in window = 1; budget consumed 1/1; telemetry `call_count=1`) |
| Edge HTTP | **200**, not timed out, no error |
| Provider credits deducted | **0.1 provider credit** per the published rule (1 rank call, `page_size=10` ≤100 rows). The API response carried **no cost field** (`cost_field_present=false`), so the exact deduction is **not system-observable** — confirm on the Kalodata dashboard (≈14.2 → ≈14.1). |
| Candidates / products | Page returned **10 products → 3 new + 7 duplicates** |
| New customer-visible | **0** (`new_visible=0`) — all 3 new are **image-pending** (`new_image_pending=3`); the image gate correctly hides them |
| Image gate corroboration | 3 new Kalodata products ingested + stored; **0 with a permitted image**; DE Explorer visible **9** unchanged, hidden_pending **20 → 23** |
| Customer credit | Balance **1 → 0**; ledger GRANT +1 / RESERVE −1 / **SETTLE 0**; `SETTLED`, `charged=true`, "1 credit used" (SUCCESS → settle, not refund) |
| Provider-usage telemetry | Recorded: KALODATA / `tiktok/product/rank` / page 1 / `http_status=200` / `relationship=customer_refresh` / `refresh_request_id` matches / `monetary_amount=null` (never fabricated) |
| No deep-research cascade | In-flight research runs unchanged (10 → 10); **0** new research runs for the tenant; suppression held |
| No duplicate paid execution | Exactly one edge call; `dispatched_at` set once; budget 1/1 — a second call was structurally impossible |
| Tenant/market/provider isolation | Only the test tenant could refresh (the other founder tenant `can_refresh=false`); DE-scoped price; tenant-scoped budget |
| Product Asset Lock / image rights | New products display-only, hidden pending permitted imagery; nothing published |

## Close-out
- Temporary **price and provider budget deactivated** (`active=false`); rows preserved as audit (not deleted).
- `active_prices=0`, `active_allowances=0`, `active_kalodata_budgets=0` — **fully fail-closed again**; test tenant
  `can_refresh=false`.
- All evidence preserved: request (SETTLED), 3 ledger rows, `provider_usage` telemetry, discovery run
  `8c06d26b-a01f-4997-a4f1-97ec55209773`.
- **No failures occurred** — the path executed cleanly on the first attempt; no fix or second paid call was needed.

## Technical readiness
**Refresh Discovery is technically ready for founding-member activation.** The full paid lifecycle
(QUOTE → RESERVE → AUTHORIZE → FIRE → KALODATA → INGEST → COMPLETE → SETTLE → STATUS) works end-to-end in
production: one call per refresh, hard budget cap, no cascade, correct settlement, image gate + PAL intact,
idempotent, isolated, usage recorded. Remaining items are **commercial/acceptance, not technical**: confirmed
$/provider-credit purchase price + subscription price; founder sets founding-member pricing/allowance/budgets
(plan §B); founder-device live-UI acceptance; and the competitive + legal launch gates.
