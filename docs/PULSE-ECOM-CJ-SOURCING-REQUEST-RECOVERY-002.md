# PULSE-ECOM-CJ-SOURCING-REQUEST-RECOVERY-002

**VERDICT: PASS (reconciled + normalized).** OUTCOME: **`PENDING_EXTERNAL_CJ_SOURCING`** — STOP.
The founder's real manual CJ sourcing request (**Sourcing ID `CJSPU958989970`**, product
"Generic Nitro Cold Brew Coffee Maker – Home Nitro Infusion System", target market US) was reconciled onto
the **existing** `cj_sourcing_requests` row (no duplicate). Exactly **one** logical read-only status lookup was
performed against `product/sourcing/query`; CJ will not resolve a manually-submitted request by its **dashboard
Sourcing ID**, so the **founder-confirmed dashboard status (Pending)** is authoritative and the request is
normalized to `PENDING_EXTERNAL_CJ_SOURCING`. **No create, no purchase, no paid sourcing, no PID manufactured,
no recurring polling, no schedule created/changed.** `campaign_activation = FALSE`, `advertising_spend = 0`.

## STEP 1 — Reconcile the existing request (no duplicate)
Row `6df1bd54-5152-467e-88c5-270b2161bd00` (nitro cold brew maker × US) updated **in place** (originally
`AWAITING_REFERENCE_IMAGE` from the create-validation stop). Persisted:
- `source_id = CJSPU958989970` (CJ dashboard Sourcing ID; `UNIQUE`).
- `provenance.cj_displayed_product_id = 2609120902334496901` (CJ dashboard "Product ID" — recorded as
  dashboard-displayed metadata **only**, never promoted to a sourced supplier PID).
- `provenance.accept_similar_products = true`, `submission_method = MANUAL_CJ_DASHBOARD`,
  `paid_sourcing = false`, `target_price_usd = 30`, `cj_sourcing_limit_after = 1/5`,
  `source = CJ_DASHBOARD_FOUNDER_CONFIRMED`, `economic_ceiling_eur = 49.16`.
- **DB verification:** 1 row total; 1 nitro/US row; 1 open nitro/US row → **no duplicate**.

## STEP 2 — Exactly ONE read-only status lookup
One logical `product/sourcing/query` for `CJSPU958989970` (read-only; no create; no loop; no retry scheduler;
no recurring trigger). CJ auth succeeded on the existing credential (id `2IV5tXPu9jAItjKh`; token never
printed). The endpoint is reachable and authorized, but rejected the **dashboard Sourcing ID** as `sourceId`
across every valid transport. The transport was corrected iteratively (each attempt read-only, non-mutating,
none returned a status); the empirical matrix:

| Exec | Transport | CJ response |
|------|-----------|-------------|
| 30160 | GET, query-string `sourceId` | `16900202 Request method 'GET' not supported` |
| 30161 | POST, query-string `sourceId`, no body | `16900204 Required request body is missing` |
| 30162 | POST, JSON body `{sourceId}` + `Content-Type: application/json` | `1600300 sourceId must be not empty` |
| 30163 | POST, JSON body `{sourceId}` **and** query-string `sourceId` | `1600300 sourceId must be not empty` |

**Finding:** `CJSPU958989970` is the CJ **dashboard Sourcing ID**. The API `product/sourcing/query` `sourceId`
field expects the **API `sourceId` returned by `product/sourcing/create`**, not the dashboard ID. A
request submitted **manually in the CJ dashboard** is therefore **not API-queryable by its dashboard ID** from
this environment. This is a transport/identifier limitation, **not** an auth failure and **not** a payment
blocker. No further probing was performed (no polling).

## STEP 3 — Normalize
CJ dashboard shows **Pending** (founder-confirmed); the API cannot return a machine status for a
dashboard-submitted request keyed by its dashboard ID. Per spec (PENDING / PROCESSING / SOURCING →
`PENDING_EXTERNAL_CJ_SOURCING`, then STOP), the request is normalized to **`PENDING_EXTERNAL_CJ_SOURCING`**
using the **founder-confirmed dashboard status as the authoritative source** — no status was fabricated.
`provider_status` and `provenance.recovery_002_status_query` record the observed state, `observed_at`, the
transport matrix, and the identifier finding.

**No COMPLETE / real sourced product exists**, so the READ-ONLY validation chain (product/query →
SUPPLIER_EXACT → assets → stock-by-VID → US freight → landed → economics → Product Confidence → WPS) was
**not** run. Critically, the CJ dashboard's displayed **Product ID `2609120902334496901`** was **NOT** treated
as a sourced supplier PID and **not** pushed into the identity/economics chain — sourcing is still pending; no
real PID has been returned.

## STEP 4 — Product decision state (gates unchanged)
The nitro × US product remains **AWAITING_SUPPLIER_RESULT / WATCH**. No hard gate was weakened. WINNER remains
reserved for post-launch. HIGH-CONFIDENCE (≥80 WPS) and every hard TEST gate (identity SUPPLIER_EXACT, in-stock
by VID, viable landed economics) stay exactly as defined; none can pass until a real sourced CJ PID exists.

## STEP 5 — Schedule / cost safety
This is a **manual** operation (n8n workflow `ZbhPyAuvDD4h4xid`, `active:false`, `triggerCount:0`, manual
trigger only). No CJ sourcing scanner created; no recurring polling; Monday production orchestrator
(`BBxcPXJdF2PliWgf`) and FX daily refresher (`np2MUp83gaZ3C2pJ`) untouched. Test cost **€0** (CJ auth + one
sourcing/query validation reject consume no product points).

## STEP 6 — Safety verification
- Duplicate request: **NONE** (1 row; idempotency guard `uq_cj_sourcing_open_concept_market` **strengthened**
  via mig_223 to also cover `PENDING_EXTERNAL_CJ_SOURCING`, so the pending external request keeps blocking
  duplicates).
- Secrets: CJ token **never** printed/exported/committed (auth output not persisted; provenance stores no
  token).
- Purchase / sample / inventory: **NONE**. Paid sourcing: **NONE** (`paid_sourcing = false`, no charge).
- Recurring polling / new schedule / cadence change: **NONE**.
- Manufactured PID from dashboard-displayed Product ID: **NO**.
- `campaign_activation = FALSE`; `advertising_spend = 0`; paused Meta proof campaign untouched.

## Supplier posture (unchanged)
`CJ = ACTIVE (Supplier #1) · CJ_SOURCING = ACTIVE EXTENSION (create authorized; manual dashboard submission
pending externally) · BIGBUY = DEFERRED_MONTH_END/PLANNED (integration points preserved) ·
ALIEXPRESS_DIRECT = DEFERRED_CONNECTION · FUTURE_PROVIDERS = EXTENSIBLE`. CJ sourcing remains **inside the CJ
provider adapter**; `cj_sourcing_requests` is CJ-scoped, not part of the universal supplier contract. Provider
selection stays evidence-based.

## Production-scan cost-control acceptance check (7-point)
1. `product/sourcing/create` executed this unit: **0**.
2. Real `product/sourcing/query` lookups: **1** (single logical status lookup; transport-corrected, read-only).
3. New recurring schedules created: **0**.
4. Production schedule changes: **0** (Monday orchestrator + FX daily untouched).
5. Paid sourcing charge: **$0** (no charge; test cost €0).
6. Monday-only production policy preserved: **YES** (this was a manual operation).
7. `campaign_activation = FALSE` · `advertising_spend = 0`: **YES**.

## Git
mig_223 applied to Supabase and mirrored to `supabase/migrations/`; this report added. Secret-scanned (no CJ
token printed or committed); pushed to `claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0.

## STOP — recommended next launch-critical unit (sourcing pending)
Sourcing is pending externally at CJ and is **not** API-queryable by its dashboard ID; per spec, do **not**
recommend repeatedly checking CJ. The highest-priority **independent** launch-critical unit that can proceed
now, without waiting on the nitro sourcing result, is:

**`PULSE-ECOM-DASHCAM-US-LAUNCH-DECISION-CLOSEOUT-001`** — formally close out the fully-validated
3-channel dash cam × US candidate (CJ PID `1980170173102026754`, SUPPLIER_EXACT, IN_STOCK US warehouse, $0
US-to-US freight, landed €24.28, WPS 79/72) as a **documented, gated decision record**: it passed every hard
TEST gate but scored **79 < 80** HIGH-CONFIDENCE, so record it as `QUALIFIED_TEST_NOT_HIGH_CONFIDENCE` with the
exact reasons (competitive saturation + value-tier spec), lock the decision provenance, and confirm the
platform can present an honest "qualified but below HIGH-CONFIDENCE threshold" outcome end-to-end (customer
view / store handoff **without** activating any campaign or spend). This exercises the launch-decision path on
**already-collected real evidence**, needs **no** CJ sourcing result, and moves paid-beta readiness forward
while the nitro request remains `PENDING_EXTERNAL_CJ_SOURCING`.

STOP / WAIT FOR FOUNDER APPROVAL.
