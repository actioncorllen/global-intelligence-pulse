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
