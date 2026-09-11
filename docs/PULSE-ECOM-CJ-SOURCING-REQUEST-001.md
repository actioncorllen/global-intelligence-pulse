# PULSE-ECOM-CJ-SOURCING-REQUEST-001

**VERDICT: PASS (audit + read-only capability proven).**
**Automation class: `CJ_SOURCING_PARTIALLY_API_AUTOMATABLE`** — the sourcing **query/status** endpoint is
proven accessible and authorized on Pulse's existing CJ credential; the **create** endpoint is documented on
the same authorized module but was **intentionally not exercised** (mutation is founder-approval-gated per
§5/§12). CJ sourcing can extend Pulse's supply coverage for differentiated products missing from the normal
catalogue, **without** BigBuy or AliExpress. No mutation, no purchase, no store/ads/campaign/spend.

## 1–4. CJ sourcing capability found (evidence)
- Repo/n8n audit: **no** existing sourcing integration (only this arc's docs mention it) — clean baseline.
- Endpoints (CJ API v2, base `https://developers.cjdropshipping.com/api2.0/v1/`):
  - `POST /product/sourcing/create` — submit a sourcing request (documented).
  - `POST /product/sourcing/query` — query a sourcing request's status by `sourceId` (**proven live**).
- **Real read-only proof (exec 30156, existing credential):** `POST /product/sourcing/query` with
  `{pageNum:1,pageSize:5}` returned `code 1600300, result:false, message:"sourceId must be not empty"`.
  This is a **field-validation error, not 404/auth failure** → the sourcing module is **mounted and
  authorized on Pulse's current CJ credential**, and status is queried per `sourceId`.
- Docs domain (`developers.cjdropshipping.com/en/api/...`) is egress-blocked from this environment; the
  **API host is reachable via n8n** (which holds the credential) — that is the authoritative proof path used.

## 3. Existing credential compatibility
Reused **"CJ Dropshipping API"** (`httpCustomAuth`, id `2IV5tXPu9jAItjKh`). Token never printed/exported.
The sourcing module authorized on this credential (no new credential required).

## 5. Automation classification
`CJ_SOURCING_PARTIALLY_API_AUTOMATABLE`:
- query/status → **API-proven** on this credential.
- create (mutation) → documented API on the same authorized module; **not exercised** (safety §5). A single
  founder-approved create test would upgrade this to `CJ_SOURCING_FULLY_API_AUTOMATABLE`.

## 6. Read-only capability proof
See §1–4: `product/sourcing/query` validated input (endpoint live + authorized), quota healthy
(~2,980/50,000 points used today). Read-only; nothing created.

## 7–8. Mutation capability & authorization requirement
`product/sourcing/create` documented fields (from CJ public API): `productName` (req), `productImage`,
`productUrl` (reference link), `remark`/description, `price` (target), optional `quantity`,
`thirdProductId`/`thirdVariantId`/`thirdProductSku` (source refs). Returns a **sourceId** used by
`/query`. **Mutation authorization for THIS unit = founder approval** (not exercised).

## 9–18. Candidate ranking & recommended first sourcing product
Using existing evidence (no new discovery):
| # | Candidate × US | ASP € | Ceiling € | Saturation | Differentiation | Sourcing feasibility | First-beta risk |
|---|---|---|---|---|---|---|---|
| **A** | **nitro cold brew maker** | 86.0 | **49.2** | **LOW (201)** | **STRONG (viral nitro cascade, no dominant brand)** | high (real mfd product) | moderate (kitchen gadget) |
| C | phone thermal camera | 154.1 | 111.8 | MOD (1,202) | STRONG | medium | **high (technical/returns)** |
| B | phone teleprompter | 64.6 | 29.4 | LOW (240) | PROMISING | high | low–moderate |
| D | roll-up piano | 61.5 | 26.6 | LOW (133) | PROMISING | medium (weight/quality variance) | moderate |

**RECOMMENDED_FIRST_CJ_SOURCING_PRODUCT = A. nitro cold brew maker × US** — best balance of strong ceiling,
LOW saturation, strong + demonstrable differentiation, no dominant DTC brand, feasible to source, and
acceptable first-beta risk. (Thermal camera has the highest ceiling but the highest technical/returns risk
for a first beta.)

## 12–15,19. Sourcing specification (nitro cold brew maker × US)
- **canonical concept:** countertop **nitrogen-infused cold brew coffee maker / dispenser**.
- **target market:** US.
- **required product noun:** nitro cold brew maker / nitro coffee dispenser / nitro brewer.
- **required subtype:** genuine **nitrogen infusion** (produces the nitro cascade) + cold-brew.
- **required features:** nitrogen infusion mechanism; dispense tap/spout; reservoir ≈ ≥1 L; reusable.
- **excluded subtypes (prevent cheaper substitute):** plain cold-brew bottle/carafe with mesh filter (no
  nitrogen); French press; ordinary drip coffee maker; N2O whipped-cream dispenser mislabelled; single-shot
  novelty. (**nitro cold brew maker ≠ ordinary cold brew bottle.**)
- **preferred mechanism:** electric/pump aerator (avoid pressurized N2 gas cartridges → hazmat/shipping risk).
- **max acceptable landed cost:** **€49** (reuse existing ceiling); **prefer ≤ €35** for ROBUST margin
  (ASP €86 / landed €34 ≈ 2.5×).
- **preferred weight:** < ~1.2 kg, compact.
- **risk restrictions:** no pressurized-gas-cartridge-only units; food-contact materials.
- **image/reference:** provide a generic spec + optional public reference URL to CJ; no fabricated claims.

## 16. Economic ceiling (unchanged policy)
`MAX_ACCEPTABLE_LANDED_COST` (US, no VAT) = ASP €86.04 − €15 acquisition stress reserve − €15 contribution −
~8% variable = **€49.16** (€44.16 at €20 contribution). €15 remains a **pre-launch stress reserve, not a
predicted CPA**. Policy unchanged.

## 20–24. Post-sourcing contract & compatibility with existing chain
Documented/expected behavior (to be proven end-to-end once a real sourcing completes): a successfully sourced
product is **added to the CJ catalogue under the account with a normal CJ PID + variant VID/SKU**, and
thereafter supports the **same endpoints already in production** — `product/query` (identity/images/variants),
`product/stock/queryByVid` (stock), `logistic/freightCalculate` (freight). It therefore flows unchanged into
the existing chain: **SUPPLIER_EXACT → fn_market_supplier_match → TEST identity gate → stock-by-VID → freight
→ landed economics**. No new supplier contract needed. (End-to-end unproven until a sourcing completes — flagged.)

## 25–27. Minimal Pulse orchestration, approval point, states (design only — not built)
Flow: `Opportunity → normal CJ category discovery → no viable exact product → SOURCING_RECOMMENDED (+ spec)
→ FOUNDER REVIEW/APPROVE → product/sourcing/create → store sourceId (SUBMITTED→PENDING) → poll
product/sourcing/query by sourceId → SOURCED ⇒ capture CJ PID → existing supplier validation → Product×Country
decision`. **Human approval point:** before `create` (mutation). Pulse never auto-submits arbitrary requests.
**States:** `NOT_REQUIRED · RECOMMENDED · AWAITING_APPROVAL · SUBMITTED · PENDING · SOURCED · REJECTED ·
FAILED · EXPIRED`. Not built this unit (audit-only; create is approval-gated; avoid premature architecture §13).

## 28. Manual fallback (if create later proves not API-authorized)
Pulse prepares the exact sourcing spec above → founder submits it in the CJ dashboard (1 paste) → Pulse
consumes the resulting CJ product by PID via the existing chain. Founder never redoes Pulse's research.

## 29. Founder action required
Approve **one bounded `product/sourcing/create` test** for the nitro cold brew maker spec (the only mutation),
to (a) upgrade automation class to FULLY and (b) prove the post-sourcing PID → existing-chain contract
end-to-end. Nothing is purchased by submitting.

## 30–32. Cost / limits / commitments
CJ sourcing-request **submission is free** per CJ public policy (CJ sources and quotes; you pay only if you
later buy). **No sample/inventory pre-purchase required to submit.** CJ imposes per-account concurrent
sourcing-request limits (small); exact numeric limit not confirmed via API this unit (docs egress-blocked) —
observable once the first request is submitted. **Nothing purchased.**

## 33. External blockers
None blocking the audit. The only external step is **founder approval to submit** the first create (mutation)
— expected and by design, not a blocker.

## 34–35. Supplier posture
`BIGBUY = DEFERRED_MONTH_END / PLANNED` (integration points preserved, not cancelled).
`ALIEXPRESS_DIRECT = DEFERRED_CONNECTION`. No supplier #2 integrated. CJ remains Supplier #1.

## 22 (architecture) — provider independence preserved
CJ sourcing lives **inside the CJ provider adapter** (CJ = Catalogue Discovery + CJ Sourcing Requests). It is
**not** added to the universal supplier contract and **no** CJ-specific sourcing fields are hardcoded into
provider-independent Product Intelligence. Sourced products, once they carry a CJ PID, map into the
provider-independent contract exactly like catalogue products (`provider, provider_product_id,
provider_variant_id, canonical identity, attributes, assets, supplier cost, stock, warehouse, destination
fulfilment, shipping cost, delivery, quality evidence, provenance, observed_at`). BigBuy/future providers
remain able to map into the same contract; sourcing is treated as a **CJ-adapter capability, not a universal
assumption**. Provider selection stays evidence-based (no automatic CJ preference).
STATUS: `CJ = ACTIVE · CJ_SOURCING = CURRENT_EXTENSION (query proven, create approval-gated) · BIGBUY =
DEFERRED_MONTH_END/PLANNED · ALIEXPRESS_DIRECT = DEFERRED_CONNECTION · FUTURE_PROVIDERS = EXTENSIBLE`.

## 36–37. Safety
No store/publication/Ad Studio/campaign/activation/spend, **no sourcing submission, no sample/inventory
purchase**. Paused Meta proof campaign untouched. `campaign_activation = FALSE`, `advertising_spend = 0`.

## 38. Tests
Live read-only probe of `product/sourcing/query` (exec 30156) proved endpoint existence + credential
authorization (validation error, not 404/auth). No mutation executed. Existing CJ chain (auth, freight,
stock) confirmed still healthy in the same run.

## 39. Git
Report doc committed; no schema/code change (audit unit; create is approval-gated). Secret-scanned (no token
printed), pushed to `claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0.

## 40. Paid-beta readiness
≈ **89%** (up from 88%): a credible, low-cost path to close the differentiated-supply gap **within CJ** is
proven (no supplier #2 spend needed now); only a founder-approved create test remains to make it fully
operational.

## 41. EXACT NEXT ACTION (for founder approval — not executed)
Approve a **single, bounded `product/sourcing/create`** for the **nitro cold brew maker × US** spec above
(free to submit, nothing purchased). On success: store the `sourceId`, poll `product/sourcing/query` to
`SOURCED`, capture the returned CJ PID, and run it through the existing SUPPLIER_EXACT → stock → freight →
landed-economics → WPS chain to a HIGH-CONFIDENCE decision — proving the post-sourcing contract end-to-end and
upgrading automation to `CJ_SOURCING_FULLY_API_AUTOMATABLE`. BigBuy remains deferred to month-end; no supplier
#2 needed to proceed.
