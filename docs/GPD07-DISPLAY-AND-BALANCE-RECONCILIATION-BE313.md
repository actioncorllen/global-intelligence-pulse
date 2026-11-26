# BE313 — GPD.07: spend-control exception closed + gated display prepared (not released)

**Executed:** 2026-11-26 · **Follows:** BE312 (2 genuine Product Detail calls). **Authority:** founder BE312 follow-up (26 Nov) — close the spend-control exception with a verified live balance; prepare the smallest gated display; **no further paid Kalodata calls** (the unused 3-call / 0.3-credit allowance stays unused). **Outcome:** balance reconciled provider-side (no discrepancy); gated reader + frontend built and tested; **nothing released, nothing deployed, no flag flip, GOLD 11/22 unchanged.**

---

## TASK 1 — Free balance reconciliation (read-only)

**Broker deployed:** `kalodata-credit-balance` (Supabase edge function). Security properties:
- Server-side; `verify_jwt=true` at the gateway; gated by **service_role OR single-use nonce** (same gate as the product-detail broker — no new trust surface).
- Kalodata auth = canonical **X-API-Key** read from env only (`KALODATA_API_KEY`/`KALODATA_SECRET_KEY`); the key is **never logged, returned or echoed** (every outbound response passes through `redact()` + `safeJson()`).
- **Only two hard-coded credit endpoints are reachable** — `GET /openapi/v1/credit/balance` and `POST /openapi/v1/credit/logs`. The URLs are constants; there is **no code path to any chargeable endpoint** (no product/detail, no product/rank). `op` only selects balance/logs/both; `logs_body` is a date-range/pagination pass-through that cannot change the endpoint.
- Source committed: `supabase/functions/kalodata-credit-balance/index.ts`.

**Results (all free, read-only):**

| Item | Value |
|---|---|
| **Current provider balance** | **13.8 credits** (`totalRemain: 13.8`, `mainRemain: 13.8`) |
| Implied balance **before** BE312 | **14.0 credits** (13.8 + 0.2) |
| November credit log | 5 lifetime `OPEN_API_CALL` entries, each **−0.1** |
| **Charges in the BE312 window** | **exactly 2** |

**Charge ↔ run reconciliation (exact):**

| Provider charge (UTC) | Qty | `discovery_run` | Δ |
|---|---|---|---|
| 2026-11-26 **21:23:50.158** | −0.1 | **US** recorded 21:23:51.307Z | ~1.1 s |
| 2026-11-26 **21:22:03.941** | −0.1 | **DE** recorded 21:22:04.563Z | ~0.6 s |
| 2026-11-20 11:13:12 | −0.1 | earlier (pre-BE312) | — |
| 2026-11-10 10:11:44 | −0.1 | earlier (pre-BE312) | — |
| 2026-11-08 22:40:02 | −0.1 | earlier (pre-BE312) | — |

**Conclusion:** BE312 spend = **0.2 credit, provider-confirmed**. Exactly two charges, −0.1 each, aligned to the second with the two recorded runs. **No discrepancy, no hidden or extra charge.** The three older deductions predate BE312.

## TASK 2 — Gated internal GPD.07 display (NOT customer-released)

### Backend chokepoint (the rights + isolation enforcement)
`fn_gpd07_social_attention_display(p_product_id uuid, p_market text, p_user_id uuid)` — `mig_369` + present-flag fix `mig_369b` (SECURITY DEFINER, `search_path=''`). Enforces:
- **Tenant access** — `auth.uid()` pins an authenticated caller to their own tenant; `p_user_id` is honoured only in the service_role/test context.
- **Source rights** — KALODATA `display_derived_cleared` must be TRUE, else `RIGHTS_BLOCKED` (no counts).
- **Country isolation (two guards)** — the product's stored market AND the stored detail's own `product_region` must both equal the requested market, else `UNAVAILABLE_*` with **no counts and no borrowing** from another market.
- **Genuine zero vs missing** — a present numeric count (incl. **0**) → value + `*_present:true`; an absent key → `null` + `*_present:false`.
- **Honest unavailable** — product/market with no applicable detail → `UNAVAILABLE_NO_EVIDENCE` (covers GB/IE/IT).
- **No raw media** — returns no image/media URLs, descriptions or video; no media reuse.

### Deterministic selftest — `fn_gpd07_social_attention_selftest()` = **8/8 PASS**
1. DE available (creator 109 / video 220 / live 124, market DE, attribution Kalodata, label present).
2. US available (424 / 341 / 1223, market US).
3. DE product requested as US → UNAVAILABLE, no counts (no fallback).
4. US product requested as DE → UNAVAILABLE, no counts (no fallback).
5. GB on a real product → `UNAVAILABLE_NO_EVIDENCE` (honest).
6. Foreign tenant → `NOT_OWNED_OR_NOT_FOUND` (cross-tenant blocked).
7. Genuine-zero vs missing (creator 0/present, video removed/missing, live 7) — via a **rolled-back savepoint** (no persisted test data).
8. Rights-blocked branch — via a **rolled-back savepoint** (the flag flip does not survive).

Post-test verification: DE counts intact at **109/220/124**; KALODATA `display_derived_cleared` still **TRUE** (`updated_at 2026-11-20`, untouched).

### Frontend (Lovable preview — NOT deployed)
Four new files (committed in Lovable `3aae7a7`, 2.1 credits; no route/backend/dependency change):
- `src/lib/gpd07/release-flag.ts` — `GPD07_SOCIAL_ATTENTION_RELEASED = false` (founder release decision to flip).
- `src/lib/gpd07/social-attention-api.ts` — typed `fetchSocialAttention()` over the RPC.
- `src/components/business-discovery/social-attention-panel.tsx` — `SocialAttentionPanelView` (pure, renders the 6 fields: creator/video/live counts with genuine-0-vs-"—", country, "Source: Kalodata", the explicit label "TikTok social attention / promotional activity — not verified market demand", observation period last-7-days + acquired timestamp; honest UNAVAILABLE / RIGHTS_BLOCKED states) and `SocialAttentionPanel` (**gated wrapper**: returns `null` and does not even fetch while the flag is false).
- `src/components/business-discovery/social-attention-panel.test.tsx` — **5/5 pass** (available counts + label + attribution + market; genuine-zero vs missing; GB no-borrow; rights-blocked; hidden-by-default no-fetch).

**Doubly non-released:** the release flag defaults OFF **and** `SocialAttentionPanel` is referenced only in its own files (mounted on no route). No deploy, no publish.

## TASK 3 — Acceptance readiness

| Check | Result |
|---|---|
| Provider-verified balance | **13.8 credits** now; **14.0** before BE312 |
| BE312 charges (provider) | **2 × −0.1 = 0.2**, aligned to the second with the 2 runs |
| Balance discrepancy | **None** |
| Backend selftest | **8/8 PASS** |
| Frontend unit tests | **5/5 PASS** |
| Rights gate | enforced (RIGHTS_BLOCKED when cleared=false) — verified |
| Country isolation | enforced (two guards; no cross-market borrowing) — verified |
| Tenant isolation | enforced (auth.uid() pin; foreign tenant blocked) — verified |
| Customer release | **none** — flag OFF, unmounted, not deployed |

**GPD.07 is NOT passed on two Product Detail responses.** The backing social-attention evidence now exists (DE+US) and the gated display is built and tested, but **customer-visible release and founder acceptance remain**, and **social-attention ≠ search-demand** — the original gate's search-demand and social-demand requirements are assessed separately (GPD.06 search-demand is unaffected by this work).

**Remaining steps for founder-visible acceptance:**
1. Founder flips `GPD07_SOCIAL_ATTENTION_RELEASED` → true **and** mounts `SocialAttentionPanel` on the product-research view (an explicit release decision; deploy to production).
2. Production acceptance sighting by the founder (counts shown, truthful label, correct per-market isolation).
3. (Optional) GB/IE/IT breadth once those products carry verified `kalodata_product_id` mappings — **no speculative spend**.

**Controls:** 0 new chargeable calls (unused 3-call / 0.3-credit allowance preserved); 0 flag flips (savepoints rolled back); 0 deploys/publishes; RLS / Product Asset Lock / country isolation / provider budgets preserved. **Historical GOLD 11/22 unchanged.** Build Evidence row **BE313**.
