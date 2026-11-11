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
