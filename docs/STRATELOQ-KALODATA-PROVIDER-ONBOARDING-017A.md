# STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A

**STATUS: `RESEARCH_IMAGE_LANE_IMPLEMENTED_AND_TESTED · LIVE_API_CLIENT_BLOCKED_ON_CREDENTIALS_AND_DOCS`.**

Additive onboarding of Kalodata as a **research-image** provider for authenticated Product
Discovery, under a commercial authorisation limited to analysed SaaS research displays — **not**
advertisements, storefront publication, or generated commercial creatives. No existing integration
(DataForSEO, CJ, eBay, TikTok, Meta) was changed or removed. No live Kalodata API call was made and
**no endpoint contract was invented**.

---

## 1. Verification before implementation (what is actually available)

| Item | Result | Evidence |
|---|---|---|
| Kalodata API credentials in this environment | **NOT PRESENT** | `grep -ri 'kalo' .` → 0 hits; no `KALODATA_*` env/secret anywhere. Existing providers use named edge-function secrets (`META_CAPI_ACCESS_TOKEN`, `TIKTOK_COMMERCIAL_CLIENT_KEY/SECRET`). |
| Kalodata API documentation / endpoint contracts | **NOT AVAILABLE** | Not in repo; not supplied. Product Rank / Product Images API request+response shapes are unknown to this session. |
| Prior Kalodata integration | **NONE** | 0 references in the working tree and across all git history. The discovery/image stack is DataForSEO + CJ/eBay supplier/marketplace. |
| Commercial authorisation email (Andrew Lin, 11 Nov 2026) | **NOT VERIFIABLE FROM HERE** | Gmail connector returned *"needs to sign in again"*. The pasted terms were taken as the scope definition (research-only), not independently confirmed. Re-authenticate Gmail to verify before go-live. |
| Supported countries / data coverage vs Strateloq's 18 markets | **UNVERIFIED** | Cannot be confirmed without API/docs. Must not be assumed; see §6. |

**Consequence (per the directive):** all independently-implementable work was completed; the live API
client is reported as a specific blocker without fabricating endpoint contracts.

---

## 2. Architecture decision — a separate RESEARCH-image lane (not `product_image_assets`)

`product_image_assets` is the **commercial** supplier/marketplace image store. It feeds the card hero
(`fn_resolve_product_image`), the gallery (`fn_resolve_product_gallery`), the storefront launch guard
(`fn_storefront_publish`, mig_264) and the ad-creative authority (`fn_ad_product_card_authority`,
mig_283). A launch-critical invariant — mig_273 `fn_product_gallery_selftest` case
`no_ai_or_web_sources` — asserts that **every** row in that table is `CJ_SUPPLIER` or `EBAY_BROWSE`.

Putting Kalodata rows there would (a) break that invariant and (b) risk a research image leaking into
hero/gallery/storefront/ad paths. The authorisation is explicitly research-only and the directive
requires research images be **distinguished** from commercially-authorised supplier images and kept out
of ads/storefronts. The minimal-blast-radius way to **guarantee** that is a parallel, research-only
store that none of the commercial paths read — reusing the same rights/provenance/attribution/caching/
RLS patterns.

### Preserved (unchanged)
Product Identity Resolution (`fn_resolve_product_image`), Product Asset Lock
(`fn_ad_product_card_authority` / `fn_ad_creative_identity_policy`), Supplier Product Asset Contract,
tenant isolation + RLS, commercial image provenance/attribution, existing caching/storage, and
country-specific opportunity analysis. The ad-creative authority already filters
`rights_state='SUPPLIER_PROVIDED'`, so a `RESEARCH_LICENSED` row can never be an authoritative product
pixel source — research images are excluded there **by construction**.

---

## 3. What was implemented — `supabase/migrations/mig_292_kalodata_research_image_provider.sql`

1. **`product_research_images`** — research-only, product_id-keyed image store. RLS deny-all; readable
   only by `SECURITY DEFINER` functions; no credentials stored. CHECK constraints make it
   **definitionally research-only**:
   - `rights_state = 'RESEARCH_LICENSED'`
   - `commercial_use_eligible = false` (cannot be set true)
   - `source_provider NOT IN (CJ_SUPPLIER, EBAY_BROWSE, CJ, EBAY)`
   - expiry + caching columns: `source_url_expires_at`, `storage_ref`, `cache_state`.
2. **`fn_capture_research_image`** (service-role) — idempotent writer; forces research-only rights;
   refuses commercial provider names; refuses credential-looking URLs; records expiry + cache state.
3. **`fn_resolve_product_research_images`** — attributed reader; returns `research_only=true`,
   `ad_eligible=false`, `storefront_eligible=false`; `display_ref` prefers the cached `storage_ref` when
   the source URL has **expired** (expiry-safe; the card never points at a dead URL).
4. **`fn_ecommerce_workspace_intelligence`** — additive fields only: `product_research_images`,
   `product_research_image_count`, `product_research_source` (attribution), `product_research_note`.
   Commercial hero/gallery fields and all other behaviour are byte-compatible with mig_273.
5. **`fn_kalodata_research_image_selftest`** — self-cleaning boundary test (runs on deploy).

---

## 4. Test evidence (executed in an ephemeral Postgres 16 against the real mig_273 functions)

Because this session has no connection to the live Supabase project, the migration was executed against
a stubbed schema loaded with the **current** mig_273 definitions of `fn_resolve_product_image` /
`fn_resolve_product_gallery` + mig_292. All three migrations compiled; the on-deploy self-test RPC still
runs against the full production schema.

**`fn_kalodata_research_image_selftest` → `all_pass: true` (10/10):**
`writer_captures_research_only`, `resolver_attributed_research_only`, `never_commercial_check_enforced`,
`writer_refuses_commercial_provider`, `research_not_commercial_hero`, `research_not_in_commercial_gallery`,
`research_not_in_commercial_store`, `research_cannot_unlock_storefront`, `expired_source_uses_cache`,
`no_credentials_in_research_assets`.

**Workspace scenarios:**
- No images → hero NULL (`PENDING_RESEARCH`), research count 0.
- Research image added → hero **stays NULL**; research shown separately, attribution `Kalodata`, note
  `research_only_authorised_display_not_advertising_or_storefront`.
- Commercial supplier image **and** research image on the same product → hero = commercial
  (`SUPPLIER_PROVIDED`) with the research image listed separately (commercial precedence preserved).
- Research rows in the commercial store: **0** (gallery invariant preserved).

---

## 5. API cost controls

- **Reuse / cache:** research assets persist in `product_research_images`; the display prefers the
  cached `storage_ref` so a re-render never re-hits Kalodata. Resolve-once / reuse, same as the
  commercial lane.
- **`need_image` on Product Rank:** when the live client is built, request the main image inline via
  `need_image=1|2` on the Product Rank call (no extra credits) rather than a separate call.
- **Product Images API is billable:** call it only when additional images are genuinely needed, and
  cache the result. (The sink supports multiple images per product via the unique index.)
- **No purchases:** no credits/subscriptions/services were bought; none should be without approval.

---

## 6. Remaining external blockers (ordered)

1. **Kalodata API credentials** — install a `KALODATA_API_KEY` edge-function secret (same pattern as the
   TikTok broker, which reports `..._SECRETS_MISSING` until installed). Do **not** paste secrets into
   chat or the repo.
2. **Kalodata API documentation** — Product Rank + Product Images API request/response contracts are
   required to build the live client (image field location, pagination, the ~5-minute URL expiry, rate
   limits). Endpoints were deliberately **not** invented.
3. **Country coverage** — confirm which of Strateloq's 18 markets Kalodata actually covers; do not assume
   full coverage. The research lane is market-aware (`market` column) and safely stores partial coverage.
4. **Authorisation email verification** — re-authenticate the Gmail connector and confirm the Andrew Lin
   (11 Nov 2026) email scope (research display; no ads/storefront/creative rights) before go-live.

## 7. Live-client acceptance gate (to run once §6.1–6.2 are satisfied)

An edge-function adapter (`kalodata-research-image`) that: authenticates with `KALODATA_API_KEY`; calls
Product Rank (`need_image`) for the main image and Product Images API for extras; **downloads and caches
each image into Pulse object storage before the source URL expires**, setting `storage_ref` +
`cache_state='CACHED'`; then calls `fn_capture_research_image(...)`. It must prove, through the existing
provider-adapter acceptance gate: product identity link, rights tagging (`RESEARCH_LICENSED`),
attribution, expiry-safe caching, tenant isolation, and cost accounting — recording any field the API
does not expose as unavailable rather than fabricating it.

**Not deployed by this change.** Migration + self-test are additive and must pass the repo's normal
deploy/advisor checks before activation.

---

# Phase 2 — Product-intelligence API research + provider registration (`mig_293`)

## 8. Verified Kalodata Open API facts (from Kalodata's own sources, 2026-11-11)

> `www.kalodata.com` is **not reachable from this build's network** (`ENOTFOUND` via the agent proxy),
> so the pages below were read through web search of Kalodata's own blog / knowledge base / Open API
> announcement, not fetched directly. Third-party wrappers (Nexscope, Glama/Cotlet MCP, XCrawl,
> ClawHub) are **not** treated as authoritative and were not used to define any contract.

- **Open API exists**, 6 modules: **Category, Shop, Creator, Product, Video, Livestream**.
- **Transport/auth:** HTTP **POST + JSON + API key**.
- **Base host:** `https://www.kalodata.com/openapi/v1/tiktok/…`.
- **Named product endpoints (verified):** `POST /openapi/v1/tiktok/product/rank`,
  `POST /openapi/v1/tiktok/product/detail`.
- **Access/credentials:** **Enterprise-gated**; API keys issued via Kalodata's **"Open Center"**;
  usage is **credit-metered (billable)**. Reported Enterprise entry ≈ $570/mo (second-hand; confirm on
  your account).
- **Market coverage (Kalodata knowledge base): 15 countries** — US, GB, DE, FR, ES, IT, MX, BR, ID, MY,
  TH, VN, PH, SG, JP. (A separate "24-country weekly product ranking" is a dashboard report, not the
  data-analysis coverage.)
- **Metric families (what Kalodata provides, at capability level):** sales, revenue, growth, price,
  ranking, market/category coverage.

**Not verified (gated / needs credentials) — deliberately NOT encoded as a callable contract:** exact
request parameter names, response field names, per-endpoint credit cost, and rate limits. These require
Kalodata's partner documentation + an Enterprise API key.

## 9. Coverage vs Strateloq's markets — do not assume full coverage

Strateloq's active provider-registry markets (18): US, CA, GB, DE, FR, IT, ES, NL, IE, AT, BE, CH, PL,
AU, HK, SG, MY, PH.

| Set | Markets |
|---|---|
| Kalodata **covers** within Strateloq's active-18 (9) | US, GB, DE, FR, IT, ES, SG, MY, PH |
| Strateloq active-18 **NOT** covered by Kalodata (9) | CA, NL, IE, AT, BE, CH, PL, AU, HK |
| Kalodata covers **beyond** the active-18 (in the wider universe) | MX, BR, ID, TH, JP (+ VN, not modelled by Strateloq) |

Consequence: Kalodata can enrich **9 of 18** active markets today; the other 9 must continue to rely on
existing providers. The integration must be market-gated, never global.

## 10. What was implemented (verified, credential-free, no fabricated contract) — `mig_293`

Registered Kalodata in the **existing** `provider_capability_registry` (the registry the market-
eligibility engine already uses for DataForSEO/eBay/CJ/Meta):

- `source='KALODATA'`, `evidence_category='PRODUCT_INTELLIGENCE'`, one row per **verified** market (15),
  `coverage_type='PRODUCT_PERFORMANCE'`.
- `availability='SOURCE_UNSUPPORTED'` for every row — we cannot source Kalodata yet (no credentials),
  mirroring how TIKTOK was staged (mig_259/267/268) before its broker connected. The *coverage* fact is
  recorded in the `capability` jsonb (`provider_market_covered=true`, metric families, the two verified
  endpoints, auth/billing/access, `field_schema_state=PENDING_PARTNER_DOCS_AND_CREDENTIALS`).
- `fn_kalodata_market_supported(country)` — gate returning `{provider_covered, availability,
  sourceable_now, connection_state}` so a future ingestion never requests an uncovered market and never
  assumes a live connection.
- `fn_kalodata_provider_selftest()` — **7/7 pass** (validated in ephemeral Postgres): exactly the 15
  markets registered; covered markets are `provider_covered=true` but `sourceable_now=false` (pending
  credential); the 9 uncovered active markets report not-covered; **no** Kalodata row is `AVAILABLE`
  without credentials; existing providers untouched; registered strictly as `PRODUCT_INTELLIGENCE`;
  field schema explicitly marked pending.

**Safety:** the eligibility recompute reads only (DATAFORSEO,SEARCH_DEMAND), (EBAY,MARKETPLACE),
(CJ,SUPPLIER), (META_AD_LIBRARY,ADVERTISING). A KALODATA/PRODUCT_INTELLIGENCE row is read by none of
them, so no existing market's eligibility/score/decision changes.

## 11. Planned ingestion (BLOCKED on credentials + verified field schema — not built)

Following the DataForSEO adapter pattern (mig_255): server-side n8n fetch → idempotent SQL ingest →
candidate/evidence into the existing country-specific pipeline. Kalodata **never declares a winner**; it
contributes market-gated product-performance evidence that feeds the unchanged WPS / Product Decision.
This requires the verified request/response field schema (to map Kalodata metrics → Strateloq's
`product_market_evaluations` / `commerce_signals` without fabrication) and an API key. The research
image lane (mig_292) remains the only image path and stays research-only.

## 12. Credential + cost requirements to unblock the live client
1. **Kalodata Enterprise account + Open Center API key** → install as edge-function secret
   `KALODATA_API_KEY` (never in repo/chat).
2. **Kalodata partner API documentation** → exact params, response fields, per-endpoint credit cost,
   rate limits.
3. **Credit budget approval** → endpoints are billable; set a per-run credit cap + caching before any
   live call. No credits/subscriptions were or should be purchased without approval.

**Genuine external blocker reached:** without (1) and (2) the live product-intelligence client cannot be
built against a verified contract, and none was fabricated. Everything implementable without them
(provider registration + market-coverage gate + tests) is done and green.

---

# Phase 3 — Account active: confirmed cost model, cost controls, video research (`mig_294`)

## 13. Account status update (verified by the owner from the authenticated Open Center dashboard, 2026-11-11)
- **Open Center account is ACTIVE — no Enterprise subscription or new purchase is required.** (This
  supersedes the "Enterprise-gated / $570-mo" blocker reported in Phase 1–2.)
- **Balance:** 14.1 credits. **5 historical calls cost 0.5 credits total.**
- **Confirmed per-call cost: 0.1 credits/call** for Product Rank and Product Detail.
- **Key rotation warning:** generating a new API key **immediately invalidates the previous one** — the
  existing key must be reused, never regenerated.

`mig_294` refreshes the `KALODATA/PRODUCT_INTELLIGENCE` capability with the confirmed cost + active
account state (`enterprise_required=false`, `per_call_credits=0.1`, `connection_state=
ACCOUNT_ACTIVE_SUPABASE_SECRET_INSTALL_REQUIRED`). `availability` stays `SOURCE_UNSUPPORTED` because the
key is not yet installed as a Supabase secret and the field schema is not yet in hand.

## 14. Supabase secret configuration required to connect the existing account (deliverable)
Mirror the established trusted-server broker pattern (`supabase/functions/tiktok-commercial-token`,
`meta-insights-reader`) — secrets live **only** as Edge Function secrets, read via `Deno.env.get`,
`.trim()`-ed, never logged/returned, behind a `service_role` trusted-server gate, fail-closed.

1. **Secret name:** `KALODATA_API_KEY` (single API key; Kalodata auth is POST + JSON + API key).
2. **How to set (value never in repo, chat, or VCS):**
   - CLI: `supabase secrets set KALODATA_API_KEY=<existing key>` (do **not** regenerate the key), or
   - Dashboard → Project → Edge Functions → **Secrets** → add `KALODATA_API_KEY`.
3. **How the edge function reads it:** `const KEY = Deno.env.get("KALODATA_API_KEY")?.trim()`; include it
   in a `redact()` scrub of every response/log; require a `service_role` caller; return `424` if the
   secret is absent.
4. **Attachment to the request** (header name / placement of the key on each Kalodata call) must come
   from Kalodata's **verified auth spec** — not guessed. The secret *name* is fixed; the *placement* is
   pending the partner docs (see §16 blocker 2).
5. **Rotation:** if the key is ever rotated, update the Supabase secret in the same step, since the old
   key stops working the instant a new one is generated.

> No `KALODATA_API_KEY` is set in this repo and none should be; it is installed only in Supabase. This
> session did not request or receive the key value and made no Kalodata API call.

## 15. Cost controls implemented (`mig_294`) — fail-closed
- `kalodata_cost_policy` (singleton): `calls_enabled=false` by default, `per_call_credits=0.1`,
  `max_credits_per_run=2.0`, `last_known_balance=14.1`. **Default-deny** — no chargeable call is possible
  until an approved change sets `calls_enabled=true`.
- `fn_kalodata_budget_precheck(estimated_calls)`: fail-closed pre-call gate — denies when calls are
  disabled, over the per-run cap, or over last-known balance. A live call path must pass this first.
- `kalodata_api_usage_ledger` + `fn_kalodata_record_usage(...)`: per-call credit accounting (decrements
  last-known balance). RLS deny-all; service-role only.
- Self-test `fn_kalodata_cost_video_selftest` → **10/10** (ephemeral Postgres): default-deny holds;
  allow-within-limits / deny-over-cap / deny-over-balance all correct; ledger records; video gated.

## 16. Video research registration (`mig_294`) — media rights UNRESOLVED
- `KALODATA/VIDEO_RESEARCH` registered for the 15 verified markets. Video **performance intelligence**
  (metrics) may be used for research display under the same research-only terms as product intelligence.
- Video **MEDIA rights** (storing/displaying the actual video files or thumbnails) are **UNRESOLVED**:
  `media_ingestion=BLOCKED_PENDING_VIDEO_RIGHTS`, `ad_eligible=false`, `storefront_eligible=false` — the
  same research-only posture as the mig_292 image lane, and stricter (blocked) until rights are verified.
- Per-call cost for video endpoints is **UNCONFIRMED** (no video call observed) — not assumed to be 0.1.

## 17. Remaining blockers (accurate, as of Phase 3)
| # | Blocker | Owner action |
|---|---|---|
| 1 | `KALODATA_API_KEY` not yet installed as a Supabase Edge Function secret | Set the **existing** key as `KALODATA_API_KEY` (do not regenerate) |
| 2 | Verified request/response **field schema + auth header placement** (gated partner docs; `kalodata.com` unreachable from this build) | Provide the Product Rank / Product Detail / Video endpoint docs, or paste the relevant pages |
| 3 | **Video media rights** unresolved | Confirm whether video media (files/thumbnails) may be stored/displayed, and under what terms |
| 4 | **Chargeable-call approval** | Approve flipping `calls_enabled=true` with a per-run credit cap (0.1/call; balance 14.1) |

No longer a blocker: Enterprise subscription / new account purchase (account is active).

**Nothing deployed.** All Phase-3 changes are additive, verified-only, make no API call, and pass their
self-tests. The live client (edge function + n8n fetch + field mapping) is unblocked only when §17 items
1–2 are supplied.

---

# Phase 4 — CRITICAL: a complete Kalodata client already exists in production (repo drift)

> Found by **read-only** inspection of the Strateloq Technologies Supabase project
> (`nxaunmyihhjixxxljcqt`) — Edge Function source + `pg_proc`/`information_schema` introspection. No API
> call, no write, no deploy.

## 18. The integration is already built and deployed — and absent from this git repo
- **Edge function `kalodata-discovery`** (v14, `verify_jwt`, trusted-server **or** nonce gated): makes the
  single chargeable `product/rank` call and ingests candidates.
- **DB functions (9):** `fn_kalodata_discovery_request(market,page)`,
  `fn_kalodata_ingest_candidates(user,market,run,limit,products,dry_run,suppress_auto_research)`,
  `fn_kalodata_record_usage(p_run_id uuid, p_usage jsonb, p_endpoint text)`,
  `fn_kalodata_record_lane_outcome(user,market,lane_status,detail)`,
  `fn_kalodata_consume_invoke_nonce(token)`, `fn_kalodata_run_discovery(...)`,
  `fn_kalodata_next_page(...)`, `fn_kalodata_advance_page(...)`, `fn_kalodata_commerce_adapter_selftest()`.
- **Tables:** `kalodata_discovery_cursor`, `kalodata_invoke_nonce`.

**This git repo is NOT the source of truth for the production Kalodata integration.** It mirrors only a
subset of deployed functions/migrations.

## 19. Confirmed from the deployed client (authoritative — supersedes earlier unverified items)
- **Auth header:** `secret-key: <key>` (default; overridable via `KALODATA_SECRET_HEADER`). POST + JSON.
- **Secret env var:** **`KALODATA_SECRET_KEY`** (not `KALODATA_API_KEY`); also `KALODATA_SECRET_HEADER`,
  `KALODATA_BASE_URL`.
- **Endpoint:** `https://www.kalodata.com/openapi/v1/tiktok/product/rank`; request body built server-side
  by `fn_kalodata_discovery_request` (market-gated — `UNSUPPORTED_MARKET` short-circuit).
- **Non-exposing presence check:** `POST {probe:true}` → `{secret_present: boolean}` (no provider call,
  no charge) — this is the §1 "verify accessible without exposing" mechanism, already built in.
- **Cost controls already exist upstream:** exactly one paid call per request (authorize/reserve, set
  `dispatched_at` once), usage recorded via `fn_kalodata_record_usage`, nonce-gated invocation, beta
  refund on failure, reconcile sweep for lost callbacks.
- **Key validity: CONFIRMED** by the account's recorded `product/rank` usage — the function returns
  `424 server_secret_unavailable` without a valid secret, so recorded usage proves `KALODATA_SECRET_KEY`
  is set and valid. **Not re-tested here** (a fresh `product/rank` call is chargeable and unapproved).

## 20. Secret-name discrepancy to resolve
Your update referenced `KALODATA_API_KEY`; the deployed function reads **`KALODATA_SECRET_KEY`**. Since
production has recorded usage, `KALODATA_SECRET_KEY` is the one that is set and working. Confirm whether
`KALODATA_API_KEY` is a separate/stale secret — the function will not read it.

## 21. Phases 1–3 (mig_292/293/294) DUPLICATE the existing architecture — DO NOT DEPLOY as-is
Authored before the deployed code was visible; now superseded by what actually exists:
- `fn_kalodata_record_usage` (mig_294) **name-collides** with production
  `fn_kalodata_record_usage(p_run_id,p_usage,p_endpoint)` (different signature).
- `kalodata_cost_policy` + `fn_kalodata_budget_precheck` + `kalodata_api_usage_ledger` (mig_294)
  **duplicate** the existing upstream credit/budget/refund system.
- `provider_capability_registry` KALODATA rows (mig_293) are a **parallel** market gate; production gates
  markets inside `fn_kalodata_discovery_request`.
- `product_research_images` lane (mig_292) likely overlaps the existing image path
  (`product_image_assets` + `fn_kalodata_ingest_candidates` + `product-image-import`).
None are deployed, so there is no production harm yet — but they must be reconciled (revised or withdrawn)
before any deploy.

## 22. What was tested this phase, and remaining blockers
**Tested (read-only):** listed projects + Edge Functions, read `kalodata-discovery` source, introspected
Kalodata DB functions/tables + `provider_capability_registry`. **No** provider call, **no** write, **no**
deploy. The non-chargeable `probe` was **not** invoked (needs a trusted-server/service-role call).

**Remaining blockers / open items:**
1. **Repo ↔ production drift** — export the deployed Kalodata client + DB functions into this repo so it
   reflects reality (needed before any safe change).
2. **Reconcile mig_292/293/294** — withdraw or revise the duplicative/colliding parts.
3. **Confirm `KALODATA_SECRET_KEY` vs `KALODATA_API_KEY`** in Supabase secrets.
4. **`product/detail` + Video module** — not present among the deployed functions (only `product/rank`);
   the account's recorded Product Detail usage needs its path identified before planning those.
5. **Live billable test** — unnecessary for validity (already proven) and still requires explicit
   approval + a confirmed per-call cost if ever run.

---

# Phase 5 — Deployed Kalodata lane exported into the repo (source of truth)

Per the decision to make the repo reflect reality, the deployed Kalodata COMMERCE discovery lane was
exported **read-only** from production (`nxaunmyihhjixxxljcqt`) into this repo:

- `supabase/functions/kalodata-discovery/index.ts` — the deployed edge client, verbatim.
- `supabase/snapshots/kalodata_commerce_lane_production_snapshot_2026-11-11.sql` — the 9 `fn_kalodata_*`
  functions (verbatim `pg_get_functiondef`), the 3 tables (`kalodata_discovery_cursor`,
  `kalodata_invoke_nonce`, `discovery_provider_market_config`), the **authoritative Kalodata market
  coverage**, and grants. Syntax-validated in ephemeral Postgres (9 functions / 3 tables / 9 enabled
  markets load clean). It is a **reference snapshot**, not a numbered forward migration — the repo is
  many migrations behind production (prod references mig_336+; repo stops at mig_294), and the lane
  depends on other production-only objects (`discovery_runs`, `ingest_commerce_product`,
  `fn_persist_reference_image`, `fn_multi_lane_discovery_plan`, `net.http_post`, …) not exported here.

## 23. Authoritative facts now captured
- **Secret:** `KALODATA_SECRET_KEY` + header `secret-key` (overridable via `KALODATA_SECRET_HEADER`;
  base via `KALODATA_BASE_URL`). Key validity proven by recorded `product/rank` usage.
- **Coverage (enabled, 9):** US, GB, DE, FR, ES, IT, MY, PH, SG. IE is present but `supported/enabled
  = false` (and a self-test asserts it can't silently become supported). Gated by
  `discovery_provider_market_config`, **not** `provider_capability_registry`.
- **Images:** Kalodata cover → `fn_persist_reference_image(... 'KALODATA' ...)` as **REFERENCE_ONLY**;
  the self-test asserts the lane never touches `product_image_assets` / `fn_resolve_product_image`.
- **Cost:** one paid call/request, upstream authorize/reserve/refund; usage into `discovery_runs` via
  `fn_kalodata_record_usage(p_run_id, p_usage, p_endpoint)`.
- **Discipline:** Kalodata yields **candidates only** (never a winner/opportunity); UNKNOWN ≠ 0;
  country-isolated — the same reuse pattern as the DataForSEO adapter.

## 24. Reconciliation of my earlier migrations (next step, not yet done)
| My migration | Duplicates existing production mechanism | Recommended action |
|---|---|---|
| `mig_294 fn_kalodata_record_usage(5-arg)` | **name-collides** with prod `fn_kalodata_record_usage(p_run_id,p_usage,p_endpoint)` | **Remove** (collision) |
| `mig_294 kalodata_cost_policy / budget_precheck / usage_ledger` | upstream authorize/reserve/refund + `discovery_runs` usage | **Remove / do not deploy** |
| `mig_293 provider_capability_registry(KALODATA)` | `discovery_provider_market_config` (authoritative gate) | **Remove** or repurpose only if the eligibility UI needs a registry mirror |
| `mig_292 product_research_images` lane | `fn_persist_reference_image` REFERENCE_ONLY path | **Remove / do not deploy**; reuse the existing path |

None of mig_292/293/294 are deployed, so there is no production impact. Recommend reverting them from
this branch (leaving this doc as the record) once you confirm — that is the clean end state now that the
real lane is in the repo.

## 25. Genuinely open items (not duplicative)
- **`product/detail` + Video module:** not present in the deployed functions (only `product/rank`). If
  wanted, they are net-new against the real lane patterns (and Video carries the unresolved media-rights
  question). The account's recorded Product Detail usage still needs its path identified.
- **Broader repo drift:** many non-Kalodata production functions/migrations are also missing from this
  repo; a full reconciliation is a larger, separate effort.

---

# Phase 6 — Reconciliation executed + drift report + capability assessment

## 26. Redundant migrations reverted (done)
Dependency check first: `grep` confirmed **no** other repo file references the objects created by
mig_292/293/294 (only the snapshot's own reconciliation comment + the doc). Then reverted:
- `supabase/migrations/mig_292_kalodata_research_image_provider.sql` — removed (duplicated
  `fn_persist_reference_image` REFERENCE_ONLY path).
- `supabase/migrations/mig_293_kalodata_provider_registry.sql` — removed (duplicated
  `discovery_provider_market_config`).
- `supabase/migrations/mig_294_kalodata_cost_controls_and_video.sql` — removed (duplicated upstream
  credit/usage accounting; `fn_kalodata_record_usage` name-collision).

Kept (source of truth): `supabase/functions/kalodata-discovery/index.ts`, the reference snapshot, and this
doc. Removing mig_292 restores `fn_ecommerce_workspace_intelligence` to its mig_273 definition (no
research-image fields). **No production object was touched; nothing was deployed.**

## 27. Authoritative deployed migration history + drift (read from production)
`supabase_migrations.schema_migrations` on `nxaunmyihhjixxxljcqt`:
- **507 applied migrations**, earliest `20260628233418`, latest `20261110221932`
  (`mig_355b_webhook_reclaim`).
- Production uses **timestamp-versioned** migrations (Supabase CLI style:
  `20261110221932_mig_355b_webhook_reclaim`), with recent work on monetisation/PSP webhooks, onboarding
  gates, and Stage-B discovery refresh credit/allowance.

This local repo has ~95 `mig_NNN_*.sql` files (max `mig_294`, which was mine) using a **different,
non-timestamped** naming scheme. **Conclusion: `global-intelligence-pulse` is NOT the deployment source
for this Supabase project.** The authoritative source is a separate repo/process that applies the
507 timestamp-versioned migrations (standard `supabase db push`/CI). 
- **Action required (owner):** identify the canonical Supabase migrations repo / deployment pipeline.
- **Do NOT** replay this repo's `mig_*` files against production, and **do NOT** treat the snapshot as a
  deployable migration — both would diverge from / clobber the real 507-migration history.
- Safe continuation needs only the Kalodata lane, which is now captured here for reference.

## 28. Product Detail — already integrated (partially)
`fn_persist_kalodata_product_detail(p_tenant, p_product, p_market, p_detail)` exists in production
(now in the snapshot). It is tenant-isolated (owner check), persists detail REFERENCE_ONLY into
`commerce_products.extended->kalodata_detail`, reuses `fn_persist_reference_image` for the cover, and
pins the **verified product/detail response schema**: `product_id`, `master_image_url`,
`product_description` (array|string), `attributes[]`, `variants[]`, `pri_cate_id`/`sec_cate_id`/
`ter_cate_id`. Endpoint `.../tiktok/product/detail` (verified).

**Gap:** the persister has **no DB caller** and there is no deployed `kalodata-*-detail` edge function —
the product/detail **fetch/call path** is either in n8n or not yet wired, and the detail **request**
parameter schema (how a `product_id` is passed to `product/detail`) is **not verified** from any artifact
available here. So Product Detail is *persist-ready* but not *fetch-wired*.

## 29. Video — not integrated; genuinely blocked
No DB function references `video/rank` or `video/detail`; Kalodata's Video module is not wired. There are
**no verified video endpoint specifications** available here, and the **video media rights are unresolved**
(see Phase 3). Per the no-fabrication rule, video ranking / video detail / preview-playback were **not**
implemented. (Product-level video *revenue* is already captured from `product/rank`:
`live_revenue`/`video_revenue`/`showcase_revenue` via `fn_kalodata_ingest_candidates`.)

## 30. Extension plan (reuse the existing lane; build only when unblocked, no deploy here)
- **Product Detail enrichment:** add a `kalodata-product-detail` edge function + an RPC pair modelled on
  `kalodata-discovery` → `fn_persist_kalodata_product_detail` (nonce/trusted-server gate, `secret-key`
  header, `discovery_provider_market_config` market gate, upstream budget authorize/record, REFERENCE_ONLY
  image, tenant isolation). **Blocked on:** the verified product/detail **request** param schema + the
  owner's go-ahead to deploy + a chargeable-call approval.
- **Video intelligence:** net-new against the lane patterns. **Blocked on:** verified Kalodata **video**
  endpoint specs AND confirmed video media rights (preview/playback only where rights are confirmed).

## 31. Files changed, tests, blockers (this phase)
- **Removed:** `supabase/migrations/mig_292*.sql`, `mig_293*.sql`, `mig_294*.sql`.
- **Updated:** snapshot (added `fn_persist_kalodata_product_detail`), this doc.
- **Tests:** snapshot re-validated in ephemeral Postgres (loads clean). No Kalodata API call; no deploy;
  no production write.
- **Genuine external blockers:** (1) canonical migrations repo / deploy pipeline must be identified by the
  owner; (2) verified product/detail **request** schema to wire the fetch; (3) verified **video** endpoint
  specs + confirmed video media rights; (4) chargeable-call + deploy approval before any live run.

---

# Phase 7 — Deployment source identified · Product Detail fetch built · Video scoped

## 32. Authoritative deployment source (Part 1)
Evidence (read-only, from this repo + production):
- `supabase/billing-staging/README.md`: *"Production (`nxaunmyihhjixxxljcqt`) is a separate project and is
  **never** deployed from here,"* and the phase-08 migrations *"were applied directly to the project via
  the **Supabase Management API / MCP** and were **not** version-controlled in this repo."*
- This repo's only CI is `billing-staging-security-gate.yml` (scoped to `supabase/billing-staging/` +
  `scripts/security/`); there is **no** production deploy workflow. The repo carries `dr/` runbooks and
  security remediation — it is a **DR / security / documentation** repo.
- Production `supabase_migrations.schema_migrations` = **507** timestamp-versioned migrations (latest
  `20261110221932 mig_355b_webhook_reclaim`); the DR runbook deploys Edge Functions via
  `supabase functions deploy`. Frontend = separate **Lovable** project; automation = **n8n cloud**.

**Conclusion:** there is no single git "deployment repo" that this project is pushed from. Production is
changed **directly against the project via the Supabase CLI / Management API (MCP)**, with
`schema_migrations` as the authority — which is itself the root cause of the drift (direct-to-project
changes not fully version-controlled). *Unresolved:* whether a canonical app repo holds the 507 timestamp
migrations in source control (not visible here). **Recommendation:** adopt version-controlled
`supabase/migrations` applied via `supabase db push` from one canonical repo; treat this repo's `mig_*`
and the snapshot as reference only. **Safe-continuation requirement:** apply any new change through that
pipeline — never replay this repo's files or deploy the snapshot.

## 33. Product Detail — fetch did NOT exist; now built (non-deploying) (Part 2)
Inspection: no DB caller of `fn_persist_kalodata_product_detail`; no `kalodata-*-detail` edge function;
**n8n has 85 workflows, none matching "kalodata"**. So the recorded Product Detail API usage was a
dev/manual probe — **automated Product Detail fetching does not exist.**

Built (PROPOSED, not deployed), reusing existing infra only — **no duplicate provider / ledger / image
pipeline / persistence**:
- `supabase/drafts/kalodata_product_detail_fetch.sql`:
  - `fn_kalodata_detail_request(market, kalodata_product_id)` — market-gated via
    `discovery_provider_market_config`, secret-free; request assembled from **verified** field names
    (region/language/currency as product/rank; `product_id` = Kalodata's own verified id field); flagged
    `request_params_verified=false`.
  - `fn_kalodata_product_detail_selftest` — **7/7 pass** (ephemeral Postgres): request gating (enabled /
    disabled / uncovered market, missing id), secret never in request body, persister tenant-isolation
    guard, non-object rejection. Plus an ephemeral harness proved the verified detail response maps
    correctly through the existing persister (REFERENCE_ONLY; category ids; attributes/variants/desc).
- `supabase/functions/kalodata-product-detail/index.ts` — edge broker mirroring `kalodata-discovery`
  (secret-key auth, service_role/nonce gate, `fn_kalodata_detail_request` → provider call →
  `fn_persist_kalodata_product_detail` → `fn_kalodata_record_lane_outcome`+`fn_kalodata_record_usage`).
  **Fail-closed:** refuses the chargeable call unless `KALODATA_DETAIL_REQUEST_CONFIRMED=true` is set,
  so a guessed request can never be sent. Includes a non-exposing `probe` mode.

**Still blocked for go-live:** confirm the exact product/detail **request** params against Open Center
(then set the env flag), chargeable-call approval, and deploy via the canonical pipeline.

## 34. Video Intelligence — contracts not officially verifiable; nothing built (Part 3)
Only **third-party** sources describe the Video module; Kalodata's own field schema was not obtainable
(kalodata.com unreachable here; Open Center gated). Reported-but-**unverified** shapes:
- `POST /openapi/v1/tiktok/video/rank` — up to 100 videos for a product; filters region/dateRange/
  language/currency/sortField; rate limit ~10 req/10s.
- `POST /openapi/v1/tiktok/video/detail` — full metrics for one video; rate limit ~100 req/10s.
- Reported field *areas* (not names): identity, engagement, revenue, ad-performance, creator (rank);
  engagement, monetization, advertising, creator identity, region, duration, linked-product count (detail).

Per "build only where sufficient documentation exists" + "stop for genuine inaccessible contracts" +
"unresolved media rights," **no video code or field mapping was written** (that would be fabrication).
Research-only treatment stands: when built, video metrics follow the REFERENCE_ONLY research posture;
**no** customer-facing playback, **no** permanent video storage, **no** advertising reuse until rights
are confirmed. Playback URLs, if ever stored, are expiring and must be cached under confirmed rights only.
**Blocked on:** official Kalodata Video API field/param schemas **and** confirmed video media rights.

## 35. Files changed, tests, blockers (Part 5)
- **Added:** `supabase/drafts/README.md`, `supabase/drafts/kalodata_product_detail_fetch.sql`,
  `supabase/functions/kalodata-product-detail/index.ts`. **Updated:** this doc.
- **Preserved (untouched):** product/rank lane, 9 enabled markets, cost controls, country isolation,
  Product Identity Resolution, Product Asset Lock, FastMoss/DataForSEO/CJ and all other providers.
- **Tests:** product-detail draft self-test **7/7** + persist-mapping proof in ephemeral Postgres. No
  Kalodata API call, no production write, no deploy.
- **Genuine external blockers / approvals outstanding:**
  1. **Deployment pipeline:** identify/confirm the canonical versioned-migrations repo + `supabase db
     push` process (this repo is not it).
  2. **Product Detail request params:** confirm against Open Center, then set
     `KALODATA_DETAIL_REQUEST_CONFIRMED=true`.
  3. **Video:** official video endpoint/field specs + confirmed media rights.
  4. **Approvals:** chargeable-call approval and production deploy approval before any live run.

---

# Phase 8 — Documented contracts applied: Product Detail finalized + Video Intelligence built

Reference: `kalodata_official_api_contracts_2026-11-11.md` (documented Open Center fields; the file itself
says "confirm against live docs before production deployment"). No live/paid call; nothing deployed.

## 36. Product Detail adapter finalized (documented contract)
`supabase/drafts/kalodata_product_detail_fetch.sql` — `fn_kalodata_detail_request` now emits the documented
request: `region, language, currency, date_range, product_id` + optional `need_image` (default **1** =
official URL, image rights confirmed; **2** = Kalodata-hosted = **PAID**, requires approval). The response
fields already match the deployed persister. The provisional `KALODATA_DETAIL_REQUEST_CONFIRMED` fail-closed
flag was **removed** from `supabase/functions/kalodata-product-detail/index.ts` (contract now documented);
secret-key auth, market gate, tenant isolation, and the upstream budget reservation remain. Self-test
**8/8** (ephemeral Postgres).

## 37. Video Intelligence built (research-only) — `supabase/drafts/kalodata_video_intelligence.sql`
- **`kalodata_video_research`** store: research-only (`CHECK rights_state='RESEARCH_ONLY'`), RLS deny-all,
  **no playback/url/media/download column** (no permanent video storage). Metrics kept under their
  documented verbatim names (incl. `sales_volumn` [sic]).
- **`fn_kalodata_video_rank_request`** / **`fn_kalodata_video_detail_request`** — market-gated, secret-free,
  documented params (rank: region/language/currency/date_range/sort_field/page_size/page_number + optional
  product_id; detail: + video_id/need_extra).
- **`fn_kalodata_video_url_request`** — **HARD-BLOCKED** (`VIDEO_RIGHTS_UNCONFIRMED`, `invocation_blocked`);
  reference contract only; **no edge function invokes it**; the 5-min signed CloudFront URL is never stored.
- **`fn_kalodata_ingest_video_rank`** — stores videos research-only; keeps the **requested {product_id,
  country} as provenance only** (`association_basis=REQUESTED_FILTER_PROVENANCE`); **invents no per-video
  product link** (video/rank has none). Tenant-isolated when a canonical product is named.
- **`fn_persist_kalodata_video_detail`** — stores `product_number` as a **count** (never a product list).
- Edge brokers: `supabase/functions/kalodata-video-rank/index.ts`, `kalodata-video-detail/index.ts`
  (mirror the discovery lane; reuse secret-key auth, nonce gate, market gate, usage accounting). **No**
  `kalodata-video-url` edge. Self-test **10/10** (ephemeral Postgres).

## 38. Preservation (Part 7) — unchanged
product/rank lane, 9 enabled markets, `discovery_provider_market_config` gate, cost/credit accounting,
country isolation, Product Identity Resolution, Product Asset Lock, FastMoss/DataForSEO/CJ and all other
providers were not modified. Video media rights remain **unconfirmed** → no customer-facing playback,
download, permanent media storage, or advertising reuse.

## 39. Exact changes required for a controlled deployment
1. **Confirm** the documented contracts against the live authenticated Open Center pages (the reference
   file is from indexed copies).
2. **Apply DB objects** via the canonical Supabase migration pipeline (`supabase db push`, as a new
   timestamp-versioned migration) — the detail request builder, the `kalodata_video_research` table + RLS,
   the video request builders, ingest/persist functions, and self-tests. **Do not** replay this repo's
   `mig_*` or the snapshot.
3. **Deploy edge functions** `kalodata-product-detail`, `kalodata-video-rank`, `kalodata-video-detail`
   (`supabase functions deploy`). **Do not** deploy any `video/url` function.
4. **Wire callers** that reserve one budget unit per call and invoke the edge with a single-use nonce
   (reuse the `fn_kalodata_run_discovery` pattern + the existing credit authorize/reserve/refund) — this
   caller wiring hooks production-only budget functions and is the one piece left to wire.
5. **Run self-tests** on the live project (`fn_kalodata_product_detail_selftest` 8/8,
   `fn_kalodata_video_selftest` 10/10).
6. **Confirm per-call credit cost** from the account pricing/consumption page (rate limits ≠ price) and
   **approve a chargeable budget** before the first live call; keep the 9-market gate.
7. **Video media rights:** keep `video/url` uninvoked and playback/storage disabled until Kalodata confirms
   video rights.

## 40. Outstanding external approvals / blockers
- Confirm contracts against live docs; **chargeable-call + production-deploy approval**; **video media
  rights** confirmation (for `video/url`/playback); caller↔budget wiring (step 4, production-only functions).
- Everything implementable without a paid call or deployment is complete and green (8/8 + 10/10).

---

# Phase 9 — Caller wiring + full lifecycle tests + deployment plan

## 41. Production-compatible caller wiring (Part 1) — reuses the credit workflow, no new ledger
Inspected the live workflow: `fn_discovery_refresh_quote → reserve → authorize → fire → settle/refund`
over `discovery_credit_ledger` + `provider_call_budget` (`fn_provider_budget_try_consume`, KALODATA
**fail-closed**). `authorize`/`settle`/`is_refund`/`quote`/`try_consume` are **operation-agnostic**, so they
are reused unchanged. `supabase/drafts/kalodata_caller_wiring.sql` adds only the thin operation-generic
pieces:
- `ALTER discovery_refresh_request ADD COLUMN operation` (additive; default `DISCOVERY_REFRESH` keeps
  discovery byte-for-byte).
- `fn_kalodata_op_reserve(operation, market, idempotency_key)` — 9-market gate + reuse `fn_discovery_refresh_quote`
  + ledger `RESERVE` (same table, same credit math). Idempotent by `(tenant, idempotency_key)`.
- `fn_kalodata_op_complete_from_edge(request_id, outcome)` — service-role-safe settle/refund (tenant from
  the row, like the discovery edge's complete_from_edge); same `is_refund` logic + same ledger.
- `fn_kalodata_op_fire` (nonce + `net.http_post`) and `fn_kalodata_run_product_detail / _video_rank /
  _video_detail` (reserve → **reuse** `fn_discovery_refresh_authorize` → fire).
- The three edges now thread `refresh_request_id` and call the completion: **SUCCESS settles, any failure
  refunds** (`PROVIDER_FAILED_PRE_CHARGE` before the provider call, `..._POST_CHARGE` after) — mirroring the
  discovery edge. One-time nonce, tenant isolation, the 9-market gate and fail-closed budget are inherited.

## 42. Integration tests (Part 4) — mocks, no paid calls
`fn_kalodata_caller_lifecycle_selftest` drives the full internal lifecycle against the **real** production
credit functions (loaded into ephemeral Postgres with mocked tables): **10/10** —
`happy(reserve→authorize→settle)`, `duplicate(idempotent)`, `malformed/failure→refund`,
`credit_exhaustion→denied`, `unsupported_market→denied`, `provider_budget exhausted at reserve→denied`,
`provider_budget race at authorize→fail-closed+auto-refund→REFUNDED`, `cross_tenant→REQUEST_NOT_FOUND`,
`expired_nonce→rejected / fresh→accepted`, `run_* dry-run→authorized`. All three drafts also load together
and pass: product_detail **8/8**, video **10/10**, caller **10/10** (28 checks). No Kalodata API call, no
production write, no deploy.

## 43. Contract validation (Part 2) — live docs not reachable from this environment
The live Open Center pages remain **unreachable from this build** (`ENOTFOUND www.kalodata.com`; the docs
are also login-gated), so a live diff could not be performed here. Implemented strictly from the supplied
`kalodata_official_api_contracts_2026-11-11.md`, which is itself "from indexed copies… confirm against live
docs before production deployment." **Remaining unverified items to confirm against live docs before go-live:**
- **`need_extra` (product/detail):** shown in the docs' debug example but **absent from the param table** —
  treated as unsupported; our request does **not** send it. Confirm.
- **Per-call credit cost:** documented rate limits are request limits, **not** prices. The real per-endpoint
  credit cost must be read from the account pricing/consumption page (affects `discovery_credit_price`).
- **Live market coverage:** the API region list is not proof of live coverage — the 9-market gate is kept.
- **Response shapes under real data:** the docs' Mock Responses show `success:false`; a passing mock test
  does **not** prove live compatibility. First live smoke call per operation must be verified.
- `sales_volumn` spelling, `product_number` as a count, and no per-video `product_id` are handled as documented.

## 44. Media rights (Part 3) — unchanged
`video/url` stays hard-blocked (no edge invokes it); no playback/download/permanent media storage/ad reuse.
Video research metrics + attribution are prepared independently (research-only).

## 45. Exact minimal deployment sequence (Part 5) — via the canonical Supabase CLI/MCP, not this repo
Deployment is **direct-to-project via Supabase CLI (`supabase db push`) / Management API (MCP
`apply_migration`)** — the authority is `supabase_migrations.schema_migrations`. **Do not** replay this
repo's `mig_*` or the DR snapshot. Minimal controlled sequence:
1. **Confirm** the four contracts against the live authenticated Open Center pages.
2. **One new timestamp-versioned migration** (authored in the canonical repo/pipeline), applied in order:
   `fn_kalodata_detail_request` → `ALTER discovery_refresh_request ADD operation` → `kalodata_video_research`
   (+RLS/indexes) → video request builders → `fn_kalodata_ingest_video_rank` / `fn_persist_kalodata_video_detail`
   → `fn_kalodata_op_reserve/op_fire/op_complete_from_edge` → `fn_kalodata_run_product_detail/_video_rank/_video_detail`
   → self-tests → grants. (`fn_persist_kalodata_product_detail` already exists in prod — do not recreate.)
3. **Deploy edges** `kalodata-product-detail`, `kalodata-video-rank`, `kalodata-video-detail`
   (`supabase functions deploy <slug>`). **Not** `video/url`. Secret `KALODATA_SECRET_KEY` already set.
4. **Pricing + budget:** confirm/add `discovery_credit_price` for detail/video (may differ from the discovery
   "refresh" price), and provision `provider_call_budget` (KALODATA, per tenant/market, approved `max_calls`)
   — this budget IS the chargeable approval gate; without it `authorize` fails closed (no paid call).
5. **Run self-tests on prod:** `fn_kalodata_product_detail_selftest` (8/8), `fn_kalodata_video_selftest`
   (10/10), `fn_kalodata_caller_lifecycle_selftest` (10/10 — writes+cleans sentinel rows).
6. **Smoke:** one authorized call per operation for one market (budget approved), verify reserve→settle and
   the real per-call credit cost; keep the 9-market gate.
7. **Video rights:** keep `video/url` uninvoked and playback/storage disabled until Kalodata confirms rights.

## 46. Remaining contractual uncertainties + approvals outstanding
- Confirm contracts live (esp. `need_extra`, per-call credit cost, live coverage).
- **Pricing decision:** detail/video credit cost vs the discovery refresh price.
- **Chargeable budget + production deploy approval.**
- **Video media rights** (for `video/url`/playback).
- Deployment executes through the canonical CLI/MCP pipeline (this repo is DR/docs only).

---

# Phase 10 — Final deployment-readiness gate

1. **Edge type-check (Deno-compatible):** Deno install is blocked by the proxy (`deno.land` 403), but Node
   is available; type-checked all three edges with `tsc --strict --lib ESNext,DOM` + a Deno ambient shim
   (edges have no remote imports, so this is complete): **all three clean, 0 errors** → nothing to fix.
2. **`operation` column safety (read-only prod inspection):** `discovery_refresh_request` has **no triggers**,
   the status CHECK only permits `RESERVED/EXECUTING/SETTLED/REFUNDED/FAILED` (all our values), `page_number`
   is nullable, the unique `(tenant_id, idempotency_key)` index is intact, and **no existing function reads
   `operation`**. The additive `NOT NULL DEFAULT 'DISCOVERY_REFRESH'` column changes nothing; existing
   discovery reserve inserts get the default. Verified in the bundle: default is `DISCOVERY_REFRESH`.
3. **Ledger reuse — no double settle/charge/missing refund:** `fn_kalodata_op_complete_from_edge` is
   idempotent on `SETTLED/REFUNDED`; reserve is idempotent by `(tenant, idempotency_key)` (function check +
   DB unique index); authorize consumes the provider unit atomically (`FOR UPDATE`) and only from `RESERVED`.
   Tests prove **exactly one SETTLE and one REFUND per request** under repeated completion (double_settle /
   double_refund idempotent cases).
4. **Atomicity / failure handling:** reserve (ledger RESERVE + request row) and fire (nonce insert + queued
   `net.http_post` + `dispatched_at`) are each single transactions under a per-tenant advisory lock; the
   edge settles on SUCCESS / refunds on any failure (PRE/POST-charge); a dropped completion leaves the row
   `EXECUTING` for the existing `fn_discovery_refresh_reconcile` sweep (goodwill refund) — never a missing
   refund or a duplicate provider call.
5. **Product Ranking unaffected (Part 6):** no `fn_discovery_*` function was redefined; the `kalodata-discovery`
   edge and `fn_kalodata_run_discovery` are untouched; only new `fn_kalodata_op_*/run_*` were added.
6. **Isolation / limits (Part 7):** cross-tenant rejection, 9-market gate, and provider-budget fail-closed
   (at reserve and the authorize race) are enforced and tested.
7. **Video URL hard block (Part 8):** no edge references `video/url`; the builder returns
   `VIDEO_RIGHTS_UNCONFIRMED` / `invocation_blocked`; `kalodata_video_research` has no url/playback/media
   column. Playback, downloads, permanent media storage and ad reuse remain disabled.

**Test evidence:** edge type-check 3/3 clean; the bundled production migration applies in one transaction
and self-tests from it pass **product_detail 8/8 · video 10/10 · caller 12/12 (30 checks)**. No Kalodata API
call, no production write, no deploy.

**Deliverables:** `supabase/drafts/migration/20261111000000_kalodata_detail_video_caller.sql` (proposed,
unexecuted) + `supabase/drafts/migration/DEPLOYMENT_MANIFEST.md`.

**Unresolved risks / approvals (unchanged):** confirm contracts live (`need_extra`, per-call credit cost,
live coverage, live response shapes); detail/video **pricing** decision; **chargeable budget + production
deploy approval**; **video media rights**. Deployment runs through the canonical Supabase CLI/MCP pipeline,
never this repo.

---

# Phase 11 — Staging-readiness verification

**Verdict: STAGING-READY (internal integration) — gated on external approvals + the absence of a
schema-complete staging project.** No production change, no deploy, no chargeable call.

1. **Reconcile handles the new operations.** `fn_discovery_refresh_reconcile(ttl)` (read from prod) is
   **operation-agnostic**: it refunds **any** `RESERVED/EXECUTING` request older than the TTL purely by
   `status`+`updated_at` (`FOR UPDATE SKIP LOCKED`), reads tenant from the row (cron-safe), sets `REFUNDED`
   (`CANCELLED_PRE_CHARGE` / `UNRESOLVED_POST_DISPATCH`), and **never re-dispatches**. So abandoned
   PRODUCT_DETAIL / VIDEO_RANK / VIDEO_DETAIL `EXECUTING` rows (interrupted provider calls) are refunded
   exactly like discovery. Proven by e2e cases D + E (abandoned→refunded; a late completion is idempotent,
   exactly one REFUND).
2. **No incorrect refunds / duplicate calls / inconsistent usage.** `is_refund` maps outcomes; reserve is
   idempotent by `(tenant, idempotency_key)` (function check + unique index); authorize consumes the provider
   unit atomically (`FOR UPDATE`) only from `RESERVED`; completion + reconcile are both idempotent on terminal
   status; reconcile never calls the provider. Tested: double_settle / double_refund = exactly one entry;
   provider fail-closed at reserve and the authorize race; failure→refund.
3. **Migration applies safely vs the actual (production) schema — no overwrite.** Read-only checks confirm
   **0 function-name collisions, `kalodata_video_research` absent, `operation` column absent**, no triggers on
   `discovery_refresh_request`, status CHECK compatible. The migration is purely additive (`CREATE OR REPLACE`
   only on **new** names, `ALTER … ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`) and applies in one
   `BEGIN…COMMIT`.
4. **Staging environment.** The only staging project (`strateloq-billing-staging`) carries **4 public tables
   and none** of the discovery/credit/kalodata dependencies — it cannot host this migration. Rather than
   create new infrastructure, verification used an ephemeral Postgres loaded with the **real production
   function definitions** + real schema shapes. **Genuine limit:** no schema-complete staging exists, so a
   true staging apply isn't possible here; first real application is production via the canonical pipeline
   (needs deploy approval).
5. **Native Deno validation.** Deno install is blocked by the environment proxy (`deno.land` 403); Node is
   available, so the three edges were type-checked with `tsc --strict --lib ESNext,DOM` + a Deno ambient shim
   (edges have no remote imports) — **3/3 clean**. Native `deno check`/`deno lint` is **not available** here.
6. **Full lifecycle with mocked provider responses.** `fn_kalodata_e2e_mock_lifecycle_selftest` **5/5**:
   VIDEO_RANK success (reserve→authorize→ingest mock videos→settle, row stored research-only, ledger net −1),
   PRODUCT_DETAIL success (persist mock detail→settle), VIDEO_DETAIL provider-failure→refund (nothing
   persisted), abandoned EXECUTING→reconcile refund, late-completion idempotent.
7. **Video URL / playback / storage disabled.** No edge references `video/url`; the builder returns
   `VIDEO_RIGHTS_UNCONFIRMED`/`invocation_blocked`; `kalodata_video_research` has no url/playback/media column.

**Test evidence (from the applied bundle):** product_detail **8/8** · video **10/10** · caller lifecycle
**12/12** · e2e mock lifecycle **5/5** = **35 checks**; edge type-check **3/3**.

**Genuine blockers (none self-resolvable):**
- No schema-complete staging project (a true staging apply needs one, or production-deploy approval).
- Native Deno runtime unavailable in this environment (tsc strict used instead).
- External: live-doc confirmation (`need_extra`, per-call credit cost, live coverage/response shapes);
  detail/video **pricing**; **chargeable budget**; **production-deploy approval**; **video media rights**.

---

# Phase 12 — Product Imagery Integration: already built; verified; one blocked gap

Per "first determine whether changes are necessary / do not duplicate the image architecture," I inspected
production (read-only) before building. **The research-image handling is already built and production-tested**
— no new architecture is needed or appropriate. No production change, deploy, or chargeable call was made.

## 47. What already exists in production (reuse, do not rebuild)
- `fn_persist_reference_image(tenant, product, market, provider, source_entity_id, url)` writes the Kalodata
  cover into the **existing** `product_image_assets` with `rights_state='PROVIDER_DISCOVERY_REFERENCE'`,
  provenance `authority=REFERENCE_ONLY` ("never unlocks store/ad/creative/publishing"), first image
  `is_primary`, idempotent on `(product_id, image_url)`. Called by `fn_kalodata_ingest_candidates`
  (product/rank cover via `fn_extract_cover_url`) and `fn_persist_kalodata_product_detail`
  (`master_image_url`, `need_image`).
- Display: `fn_product_media_state` (tenant-isolated; surfaces `source_provider` for attribution) +
  `fn_resolve_product_image` (serves reference images).
- Rights separation: `fn_asset_rights_class` / `fn_product_commercial_rights` classify Kalodata research
  images as **non-publishable**; `fn_resolve_storefront_assets` gates storefront/ad by rights_state.
- Already tested in prod by `fn_discovery_media_integrity_selftest` (extractor genuineness, idempotency,
  rights-state, asset-lock separation) — for the identical FastMoss path.

## 48. Verification (ephemeral Postgres, REAL production functions) — 6/6
`extract_genuine_vs_default` (accepts genuine cover, rejects `/default/`) · `persist_reference_primary_attrib`
(Kalodata → `PROVIDER_DISCOVERY_REFERENCE` primary, `authority=REFERENCE_ONLY`, provider `KALODATA`) ·
`duplicate_idempotent` (second persist = same id, one row) · `kalodata_not_publishable`
(`publishable_present=false` → never unlocks ad/storefront) · `research_and_commercial_separate`
(CJ `SUPPLIER_PROVIDED`→`SUPPLIER_AUTHORIZED` publishable; Kalodata stays non-publishable) ·
`tenant_recorded`.

## 49. Requirements status
| Req | Status |
|---|---|
| 1 reuse `REFERENCE_ONLY` / `fn_persist_reference_image` | ✅ already the path |
| 2 Product Rank main image + Kalodata attribution | ✅ built (provider surfaced); **0 Kalodata rows today** — needs a live product/rank call (budget) to populate |
| 5 reuse tenant isolation / identity / provenance / storage / credit controls | ✅ existing |
| 6 keep research separate from commercial | ✅ `rights_state` + rights class |
| 7 never let research unlock ad/storefront | ✅ non-publishable (verified) |
| 9 preserve CJ / FastMoss / DataForSEO / Product Ranking | ✅ untouched |
| 3 separate **Product Images API** (multiple images) | ⛔ **blocked — no documented contract** |
| 4 five-minute URL expiry secure caching | ⛔ **blocked** (ties to the Product Images API; no `storage_ref`/`cache_state` exists) |
| 8 avoid unnecessary calls via caching | ⛔ depends on (4) |

## 50. Genuine blocker + the one safe design (not built)
The **Product Images API** (multi-image) contract was **not** in `kalodata_official_api_contracts_2026-11-11.md`
(it covers product/detail + video only), and `kalodata.com` is unreachable from this build — so its endpoint,
response shape and 5-minute-expiry semantics are **unverified**. Building it (and the caching) would fabricate
a contract, so it is **blocked pending the Product Images API docs**.
- Note: the main image via `need_image=1` is a TikTok CDN URL (e.g. `s.500fd.com/…~tplv…`), which is stable;
  the 5-minute expiry is specific to the Product Images API.
- **Proposed caching (when unblocked), reusing — not duplicating — the architecture:** add additive
  `storage_ref` + `cache_state` + `source_url_expires_at` columns to `product_image_assets`; a secure
  server-side cache edge (same private-bucket + signed-URL pattern as `product-image-import` /
  `pulse-generated-media`) that fetches the expiring image once and stores it; `fn_product_media_state` /
  `fn_resolve_product_image` prefer the cached `storage_ref` when the source has expired. Reuse the Kalodata
  credit workflow (the Product Images API is billable) + the existing nonce/tenant controls.

## 51. Minor observation (safe; recommend, don't change unilaterally)
`fn_asset_rights_class` maps `PROVIDER_DISCOVERY_REFERENCE` to `RIGHTS_UNKNOWN` (correctly **non-publishable**),
not to `RESEARCH_REFERENCE_ONLY`. It's safe for req 7 either way, but adding `PROVIDER_DISCOVERY_REFERENCE`
(and providers `KALODATA`/`FASTMOSS`) to the `RESEARCH_REFERENCE_ONLY` branch would classify them precisely
as research rather than "unknown."

## 52. Deployment readiness
The main-image integration is **already live and verified** (needs only a populated run). Nothing to deploy
for it. The multi-image + caching piece is **not deployable** until the Product Images API docs are provided;
then the additive caching above goes through the canonical Supabase pipeline with chargeable-call approval.
**Files changed this phase:** this doc (verification + findings). No new production code — the feature exists;
a second image pipeline would violate "do not introduce a duplicate image architecture."

# Phase 13 — Product Images multi-image integration (contract supplied; built + tested; no paid calls)

The account owner supplied the official **Product Images API** contract (2026-11-11), unblocking the multi-image
work scoped in Phase 12. Confirmed contract:
`POST https://www.kalodata.com/openapi/v1/tiktok/product/images` · header `secret-key` ·
request `{ "product_id": "<kalodata product id>" }` · response data `{ product_id, images: string[] (signed),
expires_at }` · rate limit **10 req / 10 s** · signed image URLs **expire in ~5 minutes**.

Built as **non-deploying drafts** (no deploy, no chargeable call). All 10 requirements met by reusing the
existing architecture — no new image store, no second billing system.

## 53. What was built (reuse-first)
- **Migration draft** `supabase/drafts/kalodata_product_images.sql` (+ standalone migration
  `supabase/drafts/migration/20261111010000_kalodata_product_images.sql`, applies **after** the Phase 9 bundle):
  - Additive columns on `product_image_assets`: `storage_ref`, `source_url_expires_at`, `cache_state`,
    `content_hash` + a `cache_state` CHECK and two partial UNIQUE indexes `(product_id, content_hash)` and
    `(storage_ref)`. Existing rows default to NULL/`EXTERNAL`; hotlinked-image display is byte-for-byte unchanged.
  - `fn_kalodata_images_request(market, kalodata_product_id)` — market-gated; documented body is only `{product_id}`.
  - `fn_persist_kalodata_research_image(...)` — reuses the **exact** `fn_persist_reference_image` rights model
    (`rights_state='PROVIDER_DISCOVERY_REFERENCE'`, provenance `authority='REFERENCE_ONLY'`, lane `DISCOVERY`,
    is_primary = NOT exists-primary), adds the durable-cache columns, enforces ownership, and **requires** a
    durable cached copy + content hash (never registers a row whose only reference is an expiring source URL).
  - `fn_kalodata_research_image_exists(...)`, `fn_kalodata_product_images_cached(...)` (tenant-authorised gallery),
    `fn_kalodata_run_product_images(...)` (cache reuse → reserve → authorize → fire), `fn_kalodata_op_reserve`
    widened to accept `PRODUCT_IMAGES`, and `fn_kalodata_product_images_selftest()`.
- **Edge** `supabase/functions/kalodata-product-images/index.ts` — mirrors `kalodata-video-detail`
  (secret-key auth, service-role/nonce gate, market gate, settle/refund via `fn_kalodata_op_complete_from_edge`)
  and `product-image-import` (private-bucket upload + durable signed URL). It downloads each signed URL
  server-side before expiry, sha256-hashes, dedups (in-batch + DB), uploads bytes to the **private**
  `pulse-research-reference` bucket (service role never leaves the edge), mints a durable signed URL, and
  registers each image as REFERENCE_ONLY research media.

## 54. Requirements → how each is satisfied
1. **Reuse `product_image_assets` + `fn_persist_reference_image`** — same table; persister reuses the identical
   rights/provenance/primary logic (additive cache columns only).
2. **Multi-image retrieval** — `fn_kalodata_images_request` + the edge iterate the documented `images[]` array.
3. **Cache before expiry** — the edge fetches + stores bytes server-side immediately; a durable signed URL
   becomes the display source, so the ~5-minute provider expiry no longer matters.
4. **Private storage + tenant-authorised delivery; never expose service-role** — private bucket; service role
   used only inside the edge; the durable URL is only ever returned to the owner via the existing
   `fn_product_media_state` / `fn_resolve_product_image` (auth.uid()+ownership) gates.
5. **Preserve product identity, attribution, PROVIDER_DISCOVERY_REFERENCE** — `source_entity_id` = Kalodata
   product id; `source_url` = original provider URL; `source_provider='KALODATA'`; rights unchanged.
6. **Never ad/storefront/commercial-creative eligible** — verified: `fn_product_commercial_rights`
   publishable/ai-reference gates still exclude the class; `fn_product_commercial_asset_readiness` gates on raw
   `rights_state` (research images → terminal UNKNOWN/NONE branch).
7. **Dedup + reuse cached to minimise credits** — content-hash dedup (signed URLs rotate per call, so URL is
   not a stable key); `fn_kalodata_run_product_images` short-circuits to `cache_reuse` **before** any reserve,
   so a product already cached consumes **no** Kalodata credit.
8. **Fail safe** — failed downloads / expired URLs / partial galleries: whatever cached is kept; nothing
   half-cached is registered; provider HTTP failure → refund; a successful API response (metadata + URLs) is a
   legitimate settle even if some downloads fail.
9. **Written research-display permission** — the cached copies are REFERENCE_ONLY, shown only to the owning
   tenant. **Remaining blocker:** obtain Kalodata's written research-display permission on file before go-live.
10. **Rights classifier** — `fn_asset_rights_class` now maps `PROVIDER_DISCOVERY_REFERENCE` + providers
    `KALODATA`/`FASTMOSS` to `RESEARCH_REFERENCE_ONLY`, **after proving fail-closed**: the only rights gates
    (`publishable_present`, `ai_reference_present`) exclude both research and unknown classes; no gate branches
    on the `research_only_count`/`unknown_count` counters; `fn_product_commercial_asset_readiness` reads raw
    `rights_state`, not the derived class. Confirmed a genuinely owned/supplier-authorised asset still yields
    `publishable_present=true` while a co-located Kalodata image stays in `research_only_count` (non-publishable).

## 55. Credits — reused, not re-architected
`fn_kalodata_run_product_images` uses the existing `fn_kalodata_op_reserve` (now accepts `PRODUCT_IMAGES`) →
`fn_discovery_refresh_authorize` → `fn_kalodata_op_fire`; the edge settles/refunds via
`fn_kalodata_op_complete_from_edge`. Same `discovery_credit_ledger` + `provider_call_budget` fail-closed gate —
no approved budget → no paid call. No new ledger or billing path.

## 56. Test results (ephemeral Postgres against real production function defs; edge type-checked)
- `fn_kalodata_product_images_selftest()` → **8/8 all_pass**: contract, caching (durable persist), dedup
  (content hash), tenant isolation, expiry (durable copy survives an expired source URL), rights-class
  fail-closed, Product Asset Lock (research-only product is non-publishable + non-AI), credit-reuse short-circuit.
- `fn_kalodata_caller_lifecycle_selftest()` → **12/12** (regression — widening `op_reserve` broke nothing).
- Publishable-path probe: owned + supplier-authorised images → `publishable_present=true`,
  `ai_reference_present=true`, with a co-located Kalodata image counted only in `research_only_count`
  (`unknown_count=0`) — fail-closed preserved, honest classification.
- The standalone migration file (`BEGIN…COMMIT`) applies as a transaction on top of the Phase 9 wiring; selftest
  8/8 after apply. Edge `tsc --strict` clean (Deno ambient shim).

## 57. Remaining deployment blockers (unchanged posture: no deploy / no paid call without approval)
1. **Approval to deploy** the images migration + edge via the canonical Supabase pipeline, and to create the
   private `pulse-research-reference` bucket.
2. **Approved chargeable budget** (`provider_call_budget` for `KALODATA`) + confirmation of the per-call credit
   cost for `product/images` from the authenticated Open Center account page.
3. **Kalodata's written research-display permission** on file (requirement 9) before any cached image is shown.
No production records, functions, edges, or storage were modified in this phase; no chargeable Kalodata call was made.

# Phase 14 — Imagery security correction: no durable credentials; short-lived signed delivery

Focused security correction to the Phase 13 caching design. The earlier draft stored a long-lived (~10-year)
signed URL as `product_image_assets.image_url` — a durable bearer credential (leak it once and it grants
private-object access for a decade, with no tenant check at fetch time). Corrected to store only a durable
object reference and mint short-lived signed URLs on demand through Strateloq's existing tenant-authorised
delivery mechanism. **No production deployment and no chargeable Kalodata call were made.**

## 58. What changed (focused; no redesign; no unrelated production function modified)
- **Persister `fn_persist_kalodata_research_image`** — now stores `image_url = storage_ref` (the durable
  PRIVATE-object reference, a non-http value), `source_url` = the original Kalodata URL as PROVENANCE ONLY,
  `storage_ref`/`content_hash`/`source_url_expires_at`/`cache_state='CACHED'`. **No signed URL is ever
  persisted.** Signature dropped `p_image_url`. `is_primary` is forced `false` (gallery angles never become
  the product cover and never lead any `is_primary`-ordered display path). Defense-in-depth: it refuses to
  store an http(s) value as the object reference.
- **New `fn_product_image_signed_ref(asset_id)`** — a faithful mirror of `fn_media_asset_signed_ref`:
  `auth.uid()` + product-ownership gate; returns only the bucket + object reference for an OWNED cached image
  (never a URL). Reuses the exact existing self-hosted-video signing authorisation pattern.
- **New edge `kalodata-research-image-url`** — a faithful clone of the `media-asset-url` mechanism: `verify_jwt`,
  ownership enforced by the RPC called WITH the caller's JWT, service role used ONLY to mint a **300s** signed
  URL for the owned object, never returned to the browser; CORS; REFERENCE_ONLY semantics. (media-asset-url
  itself is left untouched to avoid any regression to the live video delivery path.)
- **`fn_kalodata_product_images_cached`** — returns signed-delivery DESCRIPTORS (`asset_id` + object reference +
  `delivery_mode=SELF_HOSTED_SIGNED`), never a durable URL and never the raw provider URL.
- **Edge `kalodata-product-images`** — the durable-sign step is removed; it uploads bytes to the private bucket
  and registers only the object reference.
- **Unchanged:** `fn_product_explorer` and `fn_product_media_state` were **not** modified. Because `image_url`
  is now non-http and gallery rows are `is_primary=false`, Explorer's `image_url ILIKE 'http%'` gate and the
  media-state `is_primary DESC` ordering keep the public product-rank cover image and can never emit the
  private object reference as a URL. The private gallery is delivered only through the signed descriptor path.

## 59. Requirement-by-requirement (this correction)
1. Durable object reference stored in `storage_ref` (and as the non-credential `image_url`). ✔
2. Original Kalodata URL kept in `source_url` as provenance only; never surfaced as a delivery field. ✔
3. Short-lived signed URLs via the reused mechanism (`fn_product_image_signed_ref` + `kalodata-research-image-url`,
   300s), mirroring `media-asset-url`. ✔
4. Product Discovery + Product Explorer render without exposing credentials or bypassing isolation —
   **confirmed** in ephemeral Postgres: both select the public main CDN cover, the private refs are excluded by
   the `http%` gate / `is_primary` ordering, zero `http` credentials exist in `image_url`, and cross-tenant read
   is `forbidden`. ✔
5. `PROVIDER_DISCOVERY_REFERENCE` / REFERENCE_ONLY preserved. ✔
6. Research images never unlock ads/storefront/commercial creatives (rights gates unchanged; fail-closed). ✔
7. Expiry, unauthorised access, duplicate requests, legitimate owner access — all tested (below). ✔
8. API budget, content-hash dedup and caching controls preserved (credit workflow unchanged). ✔

## 60. Test results (ephemeral Postgres against real production function defs; edges type-checked)
- `fn_kalodata_product_images_selftest()` → **11/11 all_pass**: contract; caching (object reference, not a URL);
  dedup; tenant isolation; **no_durable_credential_stored**; **source_url_provenance_only**;
  **signed_delivery_owner_only** (owner ok / cross-tenant forbidden / anon unauthenticated); expiry (durable copy
  survives, still deliverable); rights-class fail-closed; Product Asset Lock (non-publishable); credit reuse.
- **Display-safety confirmation** (real image predicates of `fn_product_explorer` + `fn_product_media_state`):
  both select the public main CDN cover; `cached_refs_matching_http_gate = 0`; `http_credentials = 0`;
  cross-tenant gallery read `forbidden`.
- `fn_kalodata_caller_lifecycle_selftest()` → **12/12** (regression).
- Regenerated migration file (`BEGIN…COMMIT`) applies as a transaction on the Phase 9 wiring; 11/11 after apply.
- `kalodata-product-images` and `kalodata-research-image-url` edges → `tsc --strict` clean.

## 61. Deployment-readiness report (no deployment / no chargeable call authorised)
**Ready to deploy (pending approval), in order:**
1. Apply `20261111000000_kalodata_detail_video_caller.sql` (Phase 9 bundle) if not already applied.
2. Apply `20261111010000_kalodata_product_images.sql` (this correction is folded in).
3. Create the private bucket `pulse-research-reference`.
4. Deploy edges `kalodata-product-images` and `kalodata-research-image-url`.
5. Run the two self-tests (expect 11/11 and 12/12) — no paid calls.

**Remaining blockers (unchanged; require explicit approval / external confirmation):**
- Approval to deploy via the canonical Supabase pipeline + create the private bucket.
- Approved chargeable `provider_call_budget` for `KALODATA` + the confirmed per-call credit cost for
  `product/images` (from the authenticated Open Center account page) before any live fetch.
- Kalodata's written research-display permission on file before any cached image is shown.

No production records, functions, edges or storage were modified in this phase; no chargeable Kalodata call was made.

# Phase 15 — End-to-end customer-facing display path verified; frontend integration added

Verified the complete display path and fixed the missing frontend integration. The Lovable frontend had NO
consumer of the image signing endpoint: both existing image surfaces render only https URLs, so the corrected
cached research images (signed descriptors, no URL) could not render anywhere. Added the integration by
mirroring the EXISTING self-hosted reference-video signed-delivery pattern. No production deployment; no
chargeable Kalodata call; the Lovable change is on preview only (NOT published).

## 62. Findings (before the fix)
- Frontend project: Lovable "Pulse Implementation" (12db6c84-161b-4c23-aac4-e19e8cd24ab1), workspace Strateloq.
- `reference-video-gallery.tsx` already mints SHORT-LIVED signed URLs for self-hosted video via
  `fetchSignedMediaUrl` → the `media-asset-url` edge, with re-mint on expiry (the pattern to reuse).
- Both image galleries (`product-gallery.tsx`, `product-detail-media.tsx`) render only `isHttps` URLs, and the
  workspace RPC `fn_ecommerce_workspace_intelligence` does not emit the research gallery. So nothing consumed
  the image signing endpoint — the research gallery was unrenderable. This was the real missing integration.

## 63. Frontend fix (Lovable commit 57132e00; preview only, not published)
Reuses the reference-video mechanism exactly; existing https galleries + Product Explorer untouched.
- `product-media-contract.ts`: added `fetchSignedResearchImageUrl(assetId)` → invokes `kalodata-research-image-url`
  with `{ product_image_asset_id }`, maps 403→forbidden, reuses `decodeSignedMediaUrl` (requires https + ok).
  `decodeSignedMediaUrl` unchanged.
- `research-image-gallery-contract.ts` (+ tests): `fetchKalodataResearchGallery(productId, tenant)` calls RPC
  `fn_kalodata_product_images_cached`; `decodeKalodataResearchGallery` fails closed, dropping anything not
  `SELF_HOSTED_SIGNED` + endpoint `kalodata-research-image-url` + `REFERENCE_ONLY` + `CACHED`, and NEVER exposes
  storage bucket/object to the UI; sorts primary-first then position.
- `use-kalodata-research-gallery.ts`: passes the signed-in user's id as tenant; enabled only when authenticated.
- `reference-image-gallery.tsx` (+ tests): `SignedImage` mints a 300s signed URL (component state only),
  re-mints once on `<img>` error (expiry) then shows "Image unavailable" + Retry; forbidden → renders nothing.
  `ReferenceImageGallery` shows the multi-image set + thumbnails + an Enlarge dialog with REFERENCE_ONLY
  captions, reusing existing shadcn primitives (no redesign).
- `product-intelligence.tsx`: a `ResearchImagesBlock` (renders nothing without authorised cached images) under
  the video in the detail layout and as a side-panel section. `ecommerce-workspace.tsx`: passes the product id.
- UNTOUCHED: `product-gallery.tsx`, `product-detail-media.tsx`, `product-explorer.tsx`, `package.json` — the
  public main-image cover and Product Explorer display behaviour are unchanged.

## 64. Requirement-by-requirement (display path)
1. Authenticated Product Discovery user requests a cached gallery image — `useKalodataResearchGallery` →
   `fn_kalodata_product_images_cached` (tenant = auth uid) → `fetchSignedResearchImageUrl`. ✔
2. Signing edge returns a usable short-lived URL; never exposes service-role — `kalodata-research-image-url`
   mints a 300s signed URL with the service role server-side; the browser gets only `signed_url`; the object
   reference is never surfaced to the UI. ✔
3. Frontend gallery actually consumes the signing endpoint and renders multiple images — `ReferenceImageGallery`
   renders one `SignedImage` per image (each invokes the edge); a unit test asserts one mint per image and a
   multi-image thumbnail grid. Not a descriptor-only stub. ✔
4. Another tenant cannot request/retrieve — RPC enforces `auth.uid()=p_tenant`; the edge's
   `fn_product_image_signed_ref` enforces tenant+product ownership; the client passes the signed-in uid; the
   decoder fails closed on `forbidden`. ✔
5. Expired URLs cannot be reused — 300s TTL; URLs live only in component state; re-mint once on error then Retry. ✔
6. Public main cover + Product Explorer display preserved — the three existing gallery files are untouched. ✔
   (Note: the research block currently appears in the Product Discovery / workspace Overview product panel, not
   the Product Explorer's panel, because wiring Explorer would mean editing the preserved `product-explorer.tsx`.
   Optional one-line follow-up if Explorer parity is wanted.)
7. REFERENCE_ONLY + commercial restrictions preserved — decoder requires `authority=REFERENCE_ONLY`; captions
   state "not cleared for commercial/advertising use"; never fed to commerce/ads/creative/publishing/Asset Lock. ✔
8. Success / missing / expired / unauthorised all tested — see test results. ✔

## 65. Evidence
- Frontend (Lovable): full vitest suite **704/704 across 90 files passed**; TypeScript (tsgo --noEmit) passed;
  eslint on changed files 0 errors; production build passed. Code diff reviewed (above). Preview only; not published.
- Backend (prior phases, ephemeral Postgres against real production defs): `fn_kalodata_product_images_cached`
  returns signed-delivery descriptors with no durable URL; `fn_product_image_signed_ref` is owner-only
  (cross-tenant forbidden, anon unauthenticated); images selftest **11/11**; display-safety confirmation **4/4**;
  caller lifecycle regression **12/12**. Edges `kalodata-product-images` + `kalodata-research-image-url`
  type-check clean.
- Live end-to-end (rendering a real cached image in the browser) cannot run here: it requires deploying the
  backend migration + both edges + the private bucket AND one chargeable Kalodata call to populate a cache —
  both explicitly out of scope. Until deployed, the frontend fails closed (renders no block) and the page looks
  exactly as today.

## 66. Go-live checklist (pending approval; no deploy / no paid call done)
1. Apply migrations (Phase 9 bundle, then `20261111010000_kalodata_product_images.sql`).
2. Create private bucket `pulse-research-reference`.
3. Deploy edges `kalodata-product-images` + `kalodata-research-image-url`.
4. Publish the Lovable frontend (commit 57132e00) — currently preview only.
5. Approve a `KALODATA` provider budget + confirm per-call credit cost; obtain Kalodata's written
   research-display permission before any cached image is shown.
Optional: one-line `product-explorer.tsx` change to show the research block in the Explorer panel too.

# Phase 16 — Product Explorer research-gallery parity (one-prop reuse; preview only)

Closed the optional item from Phase 15 §64.6: the research gallery now also appears in the Product Explorer
detail panel, reusing the EXACT existing implementation — no new component, no duplicated signing.

## 67. Change (Lovable commit 1c8ca1b; preview only, not published)
- `src/components/business-discovery/product-explorer.tsx`: ONE prop added to the `ProductIntelligenceDrawer`
  call inside `ExplorerDrawer` — `researchProductId={item.productId}` (the canonical product id already in
  scope). This reuses the existing `ResearchImagesBlock` → `ReferenceImageGallery` → `useKalodataResearchGallery`
  → `fetchSignedResearchImageUrl` path. Nothing else in the file changed.
- `src/components/business-discovery/product-explorer.research-images.test.tsx` (new): renders the real
  `ExplorerDrawer`; the research block (`detail-media-research-images`) appears only when the hook returns
  cached images, and is absent otherwise.
- Verified clean/additive via the commit diff: no other file changed, no duplicated gallery/signing, the
  existing cover/gallery/actions and `product-detail-media.tsx`/`product-gallery.tsx` are untouched. Research
  images remain REFERENCE_ONLY, tenant-scoped (hook passes the signed-in user id), never a cover or gate input.

## 68. Regression results (this run)
- Tests: **682/682 passed (89 files)**, including the 2 new Explorer tests. (The earlier Phase-15 run reported
  704; the commit-1c8ca1b diff is purely additive — one prop + one new test file — so the difference is a
  vitest invocation/counting artifact between two separate runs, not removed tests.)
- TypeScript (`tsgo --noEmit`): clean. ESLint on changed files: 0 errors (6 pre-existing fast-refresh warnings
  in `product-explorer.tsx`, untouched). Production build: OK.
- Both Product Discovery (workspace Overview) and Product Explorer now surface the signed research gallery
  (whenever authorised cached images exist). Still preview only — no publish, no backend deploy, no paid call.

# Phase 17 — Coordinated release preflight + GO/NO-GO (no production change made)

Read-only preflight for the coordinated Kalodata release (Product Detail, Video Intelligence, multi-image
retrieval + caching, short-lived signed delivery, Discovery + Explorer gallery). STOPPED before any production
modification. No migration applied, no bucket created, no edge deployed, no paid call, no Lovable publish.

## 69. Verified production state (project nxaunmyihhjixxxljcqt)
- Applied-migration frontier: `mig_358` (20261111170431). Both release migrations
  (`20261111000000_kalodata_detail_video_caller.sql`, `20261111010000_kalodata_product_images.sql`) are NOT
  applied. Of all proposed functions, only `fn_persist_kalodata_product_detail` exists (pre-existing/reused).
- `fn_asset_rights_class('PROVIDER_DISCOVERY_REFERENCE','KALODATA') = RIGHTS_UNKNOWN` (req-10 not yet applied).
- `product_image_assets` cache columns: 0 present. `discovery_refresh_request.operation`: absent.
  `kalodata_video_research`: absent. (All awaiting deploy — nothing partially applied.)
- 9-market config correct: US,GB,DE,FR,ES,IT,MY,PH,SG enabled; IE disabled.
- Pre-existing infra present: Product Asset Lock (`fn_product_commercial_asset_readiness`),
  `fn_product_commercial_rights`, `fn_provider_budget_try_consume`, `fn_discovery_refresh_authorize/settle/
  reconcile`, `kalodata_invoke_nonce`, `fn_persist_reference_image`.
- FINANCIAL (fail-closed today): active KALODATA `provider_call_budget` = 0; active `discovery_credit_price` = 0
  (only one INACTIVE DE row). => reserve/authorize deny => NO paid call is currently possible. Both are deploy
  prerequisites for Phase D, not bugs.
- Deployed edges operational: `kalodata-discovery` (Product Ranking), `media-asset-url` (video signing),
  `fastmoss-*`, `product-image-import`, Stripe billing edges. Awaiting deploy (not present): kalodata-product-detail,
  kalodata-video-rank, kalodata-video-detail, kalodata-product-images, kalodata-research-image-url.
- Security advisors: 6 pre-existing INFO/WARN (RLS-no-policy INFO; mutable search_path; extension-in-public;
  SECURITY DEFINER executable-by-role; leaked-password-protection off). No ERROR. None introduced by this release.

## 70. Lovable preview commits (image galleries)
- `57132e0` — Product Discovery research gallery (signed delivery). `1c8ca1b` — Product Explorer parity (HEAD).
  Working tree clean; suite 682/682 passing.
- 704-vs-682 reconciliation (git-verified): the drop is from an UNRELATED interleaved commit
  `12fc3ab "Onboarding: retire the Preparing step"` that deleted two onboarding test files (~24 it.each cases);
  90−2+1=89 files, 704−24+2=682 tests. No gallery test lost. NOTE: other sessions commit to this Lovable project
  between edits — publish must pin commit 1c8ca1b and re-verify.

## 71. Confirmations still required (cannot be read via MCP; dashboard/owner)
- Edge secret `KALODATA_SECRET_KEY` present (the deployed kalodata-discovery and all 5 new edges read it; value
  never read by design). If stored as `KALODATA_API_KEY`, set/rename to `KALODATA_SECRET_KEY` before deploy. Do
  NOT regenerate the key.
- Current Supabase daily backup / PITR (Dashboard → Database → Backups) as a safety net before deploy.
- Per-call Kalodata credit cost per operation, from the authenticated Open Center account page (kalodata.com is
  unreachable from this environment; owner previously stated ~0.1 credits/call, balance ~14.1).

## 72. Proposed deployment sequence (additive; requires explicit approval; NOT executed)
1. Apply `20261111000000_...` (Product Detail + Video Intelligence + caller wiring).
2. Apply `20261111010000_...` (multi-image + req-10 classifier + signing authz).
3. Create private bucket `pulse-research-reference` (public=off; no public policy; service-role writes, signed reads).
4. Deploy edges kalodata-product-detail, kalodata-video-rank, kalodata-video-detail.
5. Deploy edges kalodata-product-images, kalodata-research-image-url.
6. Self-tests (no paid call): product_detail 8/8, video 10/10, caller_lifecycle 12/12, product_images 11/11;
   re-confirm fn_asset_rights_class reclass + publishable/ai gates fail-closed.
7. Verify Lovable frontend plumbing against the deployed backend (empty-state until a cache exists).
8. Publish Lovable commit 1c8ca1b ONLY after 6 is green.
Apply via the canonical Supabase pipeline (supabase db push / Management API apply_migration) — NOT by replaying
this DR repo and NOT the reference snapshot.

## 73. Financial safeguards (Phase C)
- Reuse existing `KALODATA_SECRET_KEY`; no key regeneration. No public paid usage; no wallet/Stripe-price activation.
- Smallest useful paid-test budget: one-market, founder-tenant `provider_call_budget` with `max_calls≈20`
  (≈2 credits at ~0.1/call) + one active `discovery_credit_price` for that market — enough to exercise each
  operation + dedup + refund once/twice; hard-capped and fail-closed. Everything else stays default-off.
- Provision the budget + price ONLY under separate Phase-D approval, after per-call cost is confirmed.

## 74. Backup & rollback readiness
- All DB changes additive/reversible without a restore: drop new fn_kalodata_* / fn_persist_kalodata_research_image /
  fn_product_image_signed_ref / kalodata_video_research; revert fn_asset_rights_class + fn_kalodata_op_reserve to
  their captured current bodies; `ALTER … DROP COLUMN` the 4 image cache columns + `operation`. Existing rows
  unaffected. Edge rollback: delete the 5 new slugs. Frontend: unpublish/republish prior version. Bucket: delete
  (empty). A current daily backup/PITR is the belt-and-braces safety net (confirm before deploy).

## 75. GO/NO-GO
- Backend code + migrations + edges + frontend: PREPARED and verified (self-tests 8/8+10/10+12/12+11/11;
  display-safety 4/4; frontend 682/682, TypeScript clean, build OK). Changes are additive and reversible.
- VERDICT: ready to proceed with the non-paid additive deploy (steps 1-8) upon explicit approval and the three
  §71 confirmations. HOLD on paid testing (Phase D) until per-call cost is confirmed and a capped budget + active
  price are provisioned — a SEPARATE approval. Video URL/playback/downloads/permanent storage/ad-reuse remain
  disabled pending written Kalodata video rights. STOPPED here before any production modification.

# Phase 18 — Independent resume re-verification (2026-11-12; no production change)

Read-only re-inspection on resume. Production has advanced since the Phase-17 preflight (frontier
`mig_358` → **`20261112152217` / mig_363**, 515 migrations — the interleaved billing/onboarding work), so
additivity was re-confirmed against the *current* database, not the preflight snapshot.

## 76. Production re-verified (project nxaunmyihhjixxxljcqt, read-only MCP)
- Both release migrations still **NOT applied**; all 5 new edges still **NOT deployed** (only `kalodata-discovery`
  + `fn_persist_kalodata_product_detail` pre-exist). `kalodata_video_research` absent; `product_image_assets`
  has only `source_url` (cache cols `storage_ref/cache_state/content_hash/cached_at` absent);
  `discovery_refresh_request.operation` absent → nothing partially applied; bundle is fully additive.
- `fn_asset_rights_class('PROVIDER_DISCOVERY_REFERENCE','KALODATA') = RIGHTS_UNKNOWN` (req-10 unapplied → fail-closed).
- 9-market gate intact: **US, GB, DE, FR, ES, IT, MY, PH, SG** enabled (IE disabled).
- Financial fail-closed: **0 active KALODATA `provider_call_budget`, 0 active `discovery_credit_price`** → no paid
  call is currently possible. No paid call was made during this verification.

## 77. Static validation performed here (no deploy, no paid call)
- **Edge TypeScript:** 5 functions type-checked locally (tsc, Deno global shimmed since deno.land is proxy-blocked).
  `kalodata-research-image-url` clean; the other four show only a shim-induced implicit-any on the `Deno.serve`
  handler param (typed under Deno itself) — no genuine type errors. Functions use **no external imports**, so the
  absent per-folder `deno.json` is correct, not a gap.
- **Edge security invariants re-read:** REFERENCE_ONLY + `NOT_CLEARED_REFERENCE_ONLY` on image delivery; video
  rank/detail persist **metadata only** ("no video media / playback URL fetched or stored"); 300s short-lived
  owner-authorised signing via `fn_product_image_signed_ref` (auth.uid + ownership, caller JWT); secret-key
  redaction in logs; no durable signed URL persisted.
- **Migrations:** balanced BEGIN/COMMIT; additive (`CREATE TABLE IF NOT EXISTS kalodata_video_research`, additive
  columns); least-privilege (service_role GRANT + anon/authenticated REVOKE on every fn incl. selftests). The
  selftest teardown `DELETE`s target hardcoded **synthetic sentinel tenants** (`ca11…` UUIDs that cannot collide
  with real v4 `auth.uid`), service_role-only — safe test fixtures, not destructive ops.

## 78. One deploy-time item (not a code defect)
- Draft version labels `20261111000000` / `20261111010000` now sit **behind** the live frontier
  `20261112152217`. Apply via the canonical Management API `apply_migration` with **fresh version timestamps
  greater than the frontier** (the version is operator-chosen at apply time; file labels are advisory). Files are
  intentionally **not** renumbered to avoid desyncing the extensive §-references above.

## 79. Resume verdict
- No code defect found; implementation matches the verified design. Backend selftests remain **defined and
  self-contained** but execute only post-apply (no isolated PG server here — `pg_ctl` absent, branching not on the
  free plan), so they run at deploy step 6, not during this read-only pass. Frontend 682/682 is a Lovable-sandbox
  result (not re-runnable from this ops repo). GO/NO-GO of §75 **unchanged**: ready for the non-paid additive
  deploy on explicit approval + the three §71 confirmations; paid Phase-D and video media remain held.

# Phase 19 — Final gate update: official provider pricing + release-readiness (2026-11-12; no production change)

## 80. Official Kalodata Open Center pricing (founder evidence; replaces earlier ~0.1 assumption)
Source: kalodata.com/open-center/pricing + /docs (founder screenshots; kalodata.com unreachable from this env).
**Units are PROVIDER CREDITS — not euros, not Strateloq customer discovery credits.** Observed balance: **14.1 credits**.

| Endpoint | Provider credit cost |
|---|---|
| Product Detail | 0.1 / call |
| Video Detail | 0.1 / call |
| Product Rank | 0.1 / applicable ranking unit (ceiling-based row rounding) |
| Video Rank | 0.1 / applicable ranking unit (ceiling-based row rounding) |
| Product Images | **0.01 / call** |
| Video URL | **0.5 / call** (BLOCKED — not invoked) |
| Product Comment Statistics | 1 / call (not in this release) |
| Credit Balance / Consumption Details | 0 |

`need_image=1` and `need_image=2` add no separate image-parameter charge. This matrix updates the Phase-D cost
model only; **nothing here activates budgets/prices or authorises a paid call.** A capped Phase-D test
(one market, founder tenant, `max_calls≈20`) is ≈2 credits at 0.1/call and remains a SEPARATE approval.

## 81. Secret validity — scope corrected (no overclaim)
`KALODATA_SECRET_KEY` is evidenced by prior successful authenticated usage (2 consumed provider calls on record;
`kalodata-discovery` deployed/operational; the 5 new edges read the same env name). This is **evidence of prior
working credentials, not proof of current validity**, and Supabase MCP exposes no secret-listing tool here.
**It is not on the critical path for this release:** the additive deploy and the step-6 self-tests make **no
Kalodata call**, so the secret is first exercised only at Phase-D (the first real paid call). Confirm the secret
in the dashboard (Edge Functions → Secrets) at Phase-D, or it surfaces on the first live call. Not a non-paid-deploy blocker.

## 82. Frontend revision reconciliation (action before publish)
Lovable project "Pulse Implementation" HEAD is now **`e2b7220`** (last edited 2026-11-12T20:06) — the intended
release commit **`1c8ca1b` is no longer HEAD** (other sessions committed since, as Phase-17 §70 warned). Before
step-8 publish: either verify `e2b7220` still carries the compatible Kalodata gallery wiring (and is otherwise
safe to ship) and publish it, or publish the pinned `1c8ca1b`. **Do not blind-publish HEAD.** Backend deploy
(steps 1-7) is unaffected. Branding note (not changed here, founder decision): the public hero still leads with
"Global Intelligence" positioning copy while the logo/brand is correctly STRATELOQ — this is not the legacy
company name and was not introduced by this work.

## 83. Durable rollback (no longer scratchpad-only)
Committed to the repo: `supabase/drafts/rollback/kalodata_release_rollback.sql` — reverts `fn_asset_rights_class`
to its captured pre-deploy body, drops only the new functions/table/indexes/constraint/columns (unique names →
clean no-arg drops), and guards the bucket (delete only if empty). Dropping the 4 cache columns removes cache
metadata only; the ~257 existing `product_image_assets` rows and all business data are preserved. No restore needed.

## 84. Availability impact (no overclaim)
Low-impact, not literally zero: PostgreSQL DDL still takes brief locks. `ADD COLUMN IF NOT EXISTS` is
metadata-only/instant; the guarded CHECK constraint validates on **257 rows** (sub-second ACCESS EXCLUSIVE);
`CREATE OR REPLACE fn_asset_rights_class` is instant and backward-compatible (only KALODATA/FASTMOSS reclassified).
New edges/bucket don't touch existing functions. Schedule during a quiet window; no endpoint is taken offline.

## 85. Release verdict (unchanged): GO for the non-paid additive deploy on explicit founder authorisation
Frontier re-confirmed `20261112152217` (recheck immediately before apply; if advanced, pick new increasing
versions keeping M1→M2). Hard holds remain: paid Phase-D (separate approval) and Kalodata video-media rights.

# Phase 20 — Frontend revision reconciliation (2026-11-12; no publish, no deploy)

Resolved the `1c8ca1b` vs HEAD `e2b7220` question on the Lovable-backed repo
`actioncorllen/https-www-globalintelligenceactions-com` (cloned read-only; no change pushed to it).

## 86. e2b7220 is a strict superset of 1c8ca1b (do NOT revert)
Intervening commits (1c8ca1b → e2b7220), via Lovable edit history: ecommerce workspace routing + header
wording (`4d30528`, `309aaee`); **tenant-scoped Product Asset Lock** `fn_product_commercial_asset_readiness_owned`
(`7672898` — the RPC is deployed in prod = mig_363); SEO robots/sitemap/JSON-LD (`a449a5e`, `e2b7220`); and
**canonical `www.strateloq.com`** alignment (`abbede5`). **None touch the Kalodata gallery.** Reverting to
1c8ca1b would discard the Strateloq branding/SEO/PAL/ecommerce launch work — so HEAD is the publish target.

## 87. Kalodata gallery + contracts intact at e2b7220
Present and compatible: `src/hooks/use-kalodata-research-gallery.ts`;
`src/lib/business-discovery/research-image-gallery-contract.ts` (+test) — enforces `authority:"REFERENCE_ONLY"`,
`deliveryMode:"SELF_HOSTED_SIGNED"`, validates `delivery_endpoint==="kalodata-research-image-url"`, calls RPC
`fn_kalodata_product_images_cached(p_tenant,p_product)`, **fails closed** (returns [] on bad authority/endpoint/
error); the `1c8ca1b` Explorer parity wiring (`product-explorer.tsx researchProductId={item.productId}`),
Discovery `ResearchImagesBlock` (`product-intelligence.tsx`), and `ecommerce-workspace.tsx` wiring. Tenant =
authenticated `user.id` (tenant isolation); display-only (never commerce/ads/publishing).

## 88. Frontend verification run (cloned HEAD e2b7220; npm install 582 pkgs)
- `vitest run` → **690/690 passed (91 files)** (supersedes the 682 at 1c8ca1b; +8 from later commits, no gallery test lost).
- `tsc --noEmit` → **clean**. `vite build` → **success**.

## 89. Backend contract readiness (frontend fails closed until deploy)
- `fn_product_commercial_asset_readiness_owned` → DEPLOYED (mig_363). ✔
- `kalodata-research-image-url` edge + `fn_kalodata_product_images_cached` RPC → pending the gated Kalodata
  backend deploy; until then the gallery RPC errors are caught → empty state (no customer-facing breakage).
  **The frontend can safely remain unpublished** (current published site keeps serving); publish e2b7220 only
  after the backend self-tests pass (deploy step 8).

## 90. Branding finding (flagged; NOT changed — out of Kalodata scope)
Site is Strateloq-branded (408 refs; canonical www.strateloq.com). Residual **"Global Intelligence Pulse™"**
persists in ~5 *marketing* components (`demo-preview-card.tsx`, `how-pulse-works.tsx`, `experience-pulse-modal.tsx`,
`global-pulse-visual.tsx`) — customer-facing but unrelated to the Kalodata gallery, and possibly intentional ™
feature naming. Left for a separate founder decision (per "do not initiate an unrelated rebranding exercise");
not a Kalodata-release blocker.

## 91. Reconciliation verdict: READY — publish revision `e2b7220`
Gallery intact, tests/TS/build green, rights fail-closed, Strateloq-branded, superset of 1c8ca1b. No correction
made. Publish `e2b7220` after the backend deploy + self-tests pass (step 8); hold the marketing-copy branding
cleanup as a separate item.
