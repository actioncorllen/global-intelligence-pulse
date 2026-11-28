# BE350 — Independent launch engineering: server-side route denial + Discovery plan config (18 Dec 2026)

**Executed:** 2026-11-28 · **Authority:** founder "BE350 INDEPENDENT LAUNCH ENGINEERING — GPD.09 launch-scope approval remains PENDING (the earlier optional-advertising approval is NOT operative); continue independent, technically actionable tasks. P1 frontend access restrictions; P2 billing preparation (reuse the BE348 engine); P3 launch QA. Record actual implemented changes, tests and remaining external dependencies as BE350 evidence. Do not mark preparation as implementation or implementation as production acceptance." **NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid provider/AI calls; no live subscriptions, no checkout, no paid transaction; no Lovable build (credits unavailable until 7 Dec — not consumed); GPD.09 PENDING; Meta advertising observations restricted; GPD.07 OFF; GPD.01 commercial rights release BLOCKED; historical GOLD 11/22 unchanged; founder-only Creative Studio / supplier automation / stores / campaigns preserved.**

**What is IMPLEMENTED (prepared, validated, version-controlled, deploy-gated — NOT deployed, NOT production acceptance):** two migrations closing the server-side half of P1 and the billing-config half of P2, each validated on a throwaway Postgres 16 (selftest 23/23). **What is PREPARED but NOT implemented (credit-gated):** the P1 frontend nav/route restrictions (the authoritative server-side denial already covers these routes; the frontend hiding is defense-in-depth and needs 7 Dec Lovable credits). **The frontend source lives only in the Lovable project (this repo is the Supabase backend), so frontend implementation requires Lovable credits; the server-side enforcement is implementable here and was done.**

---

## P1 — Frontend access restrictions: server-side denial IMPLEMENTED; frontend hiding PREPARED (credit-gated)

**Directive P1.5 is the load-bearing one: "Preserve existing server-side denial; frontend hiding alone is insufficient."** BE350 strengthens the server-side denial so the founder-only routes deny non-founders at the API, not merely in the UI.

**Already enforced (verified live, unchanged — BE346 + pre-existing):** every creative/campaign/store **mutation** is founder-gated — `fn_creative_studio_generate`, `fn_creative_production_request`, `fn_creative_format_apply`, `fn_cb_build_campaign`, `approve_marketing_campaign_draft`, `fn_creative_campaign_handoff`, `fn_ad_studio_campaign_handoff`, `fn_marketing_director_to_creative_request`, `fn_create_free_store`, `fn_create_pulse_store_draft`, `fn_product_card_create_store`, `fn_store_*`, `fn_storefront_publish/change_country/set_destination/transition_state`, and the three generation edges (image/concept/video, BE346). A subscriber cannot create any creative, campaign or store.

**Gap found + closed (BE350, `mig_383`, PREPARED+validated):** the user-facing **read/action** entry points behind the founder-only routes were owner-scoped (`WHERE user_id/tenant_id = auth.uid()`) but **not founder-denied** — a subscriber calling them directly received `status:ok` with their own (empty) data instead of an explicit denial. `mig_383` adds the same fail-closed `fn_is_founder_uid` gate (from BE346 `mig_382`) to exactly five RPCs:
- **My Campaigns:** `get_own_marketing_campaign_drafts`, `fn_ecommerce_campaign_executions`, `reject_marketing_campaign_draft` → `founder_only` for non-founders.
- **Creative Studio artifacts:** `fn_creative_image_job_result`, `fn_creative_studio_design_family_result` → `founder_only` for non-founders.

**Deliberately NOT gated (documented, with reason):**
- **Store reads** (`fn_hosted_store_get`, `fn_store_website`, `fn_store_website_publish_context`, `fn_storefront_publish_context`, `fn_store_connection_status`, `fn_storefront_ad_addressable`) are entangled with the **public storefront render path** (verified: `touches_public_store=true`); founder-gating them would risk breaking published storefronts for anonymous shoppers. Store **creation/management mutations are already founder-gated**, so a subscriber has no store to read.
- `fn_creative_studio_product_preview` reads a product card the subscriber may **legitimately view in Discovery**; its generation path is already founder-gated. Gating it would risk Discovery.
- Product Discovery / Research / Compare / Save / Monitoring RPCs are **untouched** (subscriber-open).

**Tests (P1.6 — founder / subscriber / anonymous / direct-API):** `mig_383` validated on a throwaway Postgres 16 (with `fn_is_founder_uid` + stub tables). Selftest **23/23 pass, 0 fail**:
- **Founder** passes the gate on all 5 (reaches `ok` / `invalid_request` / `no_job` / `request_not_found_for_tenant`).
- **Subscriber** → `founder_only` on all 5 (the direct-API denial the directive requires).
- **Anonymous** → `unauthenticated` on the four status-contract RPCs (null-check first) + `founder_only` on `design_family_result`.
- **Direct-API** = exactly this (the RPCs are tested directly, which is how a bypassing client would call them).

**Frontend half — PREPARED, not implemented (requires 7 Dec Lovable credits; not attempted, no credit spend):** the frontend lives only in the Lovable project (`12db6c84`); this repo is the Supabase backend. The exact change-list (grounded in the live Lovable source, BE349 §6) — founder-gate the **My Store** and **My Campaigns** nav (`app-sidebar.tsx` + `mobile-nav.tsx`), the **Create Ad** trio (`product-commerce-actions.tsx`), the "Create ads" entry (`product-country-explorer.tsx`), and add founder route-guards to `/workspace/creative`, `/workspace/my-campaigns`, `/workspace/store` — plus the subscriber/founder/anon regression spec. On 7 Dec: apply the patch, run the regression + full suite, then the member-journey + mobile sighting. The server-side denial above is the authoritative enforcement; the frontend hiding is defense-in-depth.

---

## P2 — Billing preparation: Discovery-only plan config IMPLEMENTED (prepared, validated); no price invented

**Reused the BE348 billing engine (36/36) — not rebuilt.** BE349 found the launch plan `ecommerce_monthly` ("Product Discovery — Monthly") inactive, `provider=NULL`, €0, no live price, **and no `plan_feature_allowance` rows** (entitlement controls undefined), while the three priced tiers (`strateloq_starter/growth/pro`) each have a complete 5-feature allowance set, and all four current entitlements on the launch plan are `COMP` grants (`billing_event=0`, no paid trading).

**`mig_384` (PREPARED+validated)** gives the launch plan the correct Product Discovery-only entitlement mapping, with no price and no activation:
- Sets `ecommerce_monthly.provider='stripe'` (declares the billing provider); keeps `active=false`, `provider_price_id_live` NULL, amount unchanged — **no price invented, plan not sellable**.
- Adds the Discovery-only `plan_feature_allowance` rows (idempotent upsert on the `(plan_code, feature)` PK): `research_actions` ENABLED, `tracked_products` ENABLED, `problem_journeys` ENABLED (limits mirrored from `strateloq_growth` as a **founder-adjustable default**), `product_images=0` (creative image generation is **founder-only** at launch), `video_metadata=0` (GPD.07 social **OFF**). This is the launch-scope-correct posture.
- End-state assertions fail the migration if the config drifts (provider≠stripe, active, a live price set, ≠5 features, images/video≠0, research disabled).

**Entitlement-mapping validation:** the three priced tiers' mappings are complete and **untouched** (selftest confirms the growth tier is unmutated); the launch plan's gap is now closed. The **price and plan activation remain founder decisions at 9-Dec registration** — not set here. Validated on throwaway Postgres 16 (assertion NOTICE + selftest pass).

---

## P3 — Launch QA: direct-API access regression IMPLEMENTED; member-journey regression PREPARED

- **Implemented now (runnable, no credits):** the `mig_383` direct-API access-control regression (founder/subscriber/anon × 5 founder-only RPCs) = **23/23 pass**. This is the server-side half of "Test founder, subscriber, anonymous and direct-API access."
- **Reused (not repeated):** BE319 (production UI accepted authenticated 7/7), BE348 (discovery engines + billing 36/36 + access control), the existing discovery reader selftests. No existing passing test was re-run without a demonstrated regression.
- **Prepared (credit-gated, 7 Dec):** the remaining **signed-in Product Discovery member-journey** regression (discover → research → compare → save → monitor, for a subscriber) + the subscriber/founder/anon **frontend** access matrix (none of {Create Ad trio, My Campaigns nav, My Store nav, Creative Studio UI, "Create ads" entry} render for a subscriber; all render for the founder; Discovery/Research/Compare/Save/Monitoring visible for both). These are frontend tests that run in Lovable; they reuse the BE319/BE343 test harnesses and are added, not duplicated.

---

## Implemented vs prepared vs external (explicit — per "do not mark preparation as implementation or implementation as production acceptance")

| Item | State | Evidence |
|---|---|---|
| Server-side founder denial on 5 route reads (`mig_383`) | **IMPLEMENTED** (prepared file, validated 23/23) — **NOT deployed** | `supabase/migrations/mig_383_...sql` |
| Discovery-only plan config (`mig_384`) | **IMPLEMENTED** (prepared file, validated) — **NOT deployed**, no price, not active | `supabase/migrations/mig_384_...sql` |
| Direct-API access regression (founder/subscriber/anon) | **IMPLEMENTED** (23/23 on throwaway PG16) | selftest |
| Frontend nav hiding + route guards | **PREPARED** (exact patch) — **credit-gated (7 Dec), not attempted** | BE349 §6 / this report |
| Signed-in member-journey + FE access-matrix regression | **PREPARED** — credit-gated (7 Dec) | this report |
| Launch plan price + activation | **EXTERNAL/FOUNDER** — 9 Dec registration + go-live | — |
| Production deploy of `mig_382`+`mig_383`+`mig_384` + edges | **EXTERNAL/FOUNDER** — controlled deploy approval | — |

**Remaining external dependencies:** (1) 7 Dec Lovable credits → the frontend nav/route restrictions + member-journey regression; (2) 9 Dec CRO/Revenue registration → live Stripe keys/price for `ecommerce_monthly` + tax/invoicing + plan activation; (3) founder-approved controlled deploy of the prepared migrations (`mig_382` BE346 → `mig_383` BE350 must apply in that order, since `mig_383` depends on `fn_is_founder_uid`) + the prepared edges; (4) GPD.01 legal sign-off (unchanged, still blocks GPD.06/08/10/11 display); (5) GPD.09 scope decision (PENDING — not assumed).

## Deploy order + rollback
Deploy-gated, separate approval. Apply order: `mig_382` (BE346, defines `fn_is_founder_uid`) → `mig_383` (BE350, depends on it) → `mig_384` (BE350, independent). Rollback: `CREATE OR REPLACE` the five `mig_383` functions back to their pre-BE350 bodies (all changes are additive fail-closed gates; no data or non-gate behaviour changed); for `mig_384`, delete the five `ecommerce_monthly` allowance rows and set `provider` back to NULL (no price/activation was ever set). Production remains `df1e2f6` (BE336).

## Strict controls — all honoured
Independent technically-actionable engineering; preparation and implementation clearly separated from production acceptance; no production deployment; no production migration applied; 0 paid provider/AI calls; no live subscription / checkout / paid transaction; no Lovable build (credits not consumed); no deploy without authorisation; GPD.09 PENDING (earlier optional-advertising approval NOT treated as operative); Meta advertising observations restricted; GPD.07 OFF; GPD.01 commercial rights release BLOCKED; founder-only Creative Studio / supplier automation / stores / campaigns preserved and strengthened; Product Discovery / Research / Compare / Save / Monitoring preserved for subscribers; historical GOLD 11/22 unchanged. Evidence: this report, master-doc Addendum 121, Build Evidence row **BE350**, repo migrations `mig_383`+`mig_384` on `claude/sharp-archimedes-n0l0tl`. Next BE id: **BE351**. Production remains `df1e2f6` (BE336).
