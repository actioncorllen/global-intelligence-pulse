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
