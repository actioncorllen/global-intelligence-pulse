# BE346 — Ad Creative Studio FOUNDER-ONLY (server-side enforcement, prepared + tested)

**Executed:** 2026-11-28 · **Authority:** founder "NEW FOUNDER ACCESS DIRECTIVE — the entire Ad Creative Studio must remain FOUNDER-ONLY until the founder explicitly authorises subscriber access; enforce server-side (RPCs, edges, storage, creative-job execution), not merely by hiding frontend buttons; reuse existing founder-role infrastructure." **Enforced server-side as prepared, locally-validated artifacts. NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid AI/provider calls; no subscriber download; no rights promotion; no quarantine restoration; no GPD.07; GOLD 11/22 unchanged. This scope change does not authorise production deployment or paid AI calls. Future subscriber access requires a new explicit founder decision + fresh security/licensing/release acceptance.**

---

## What was reused (requirement 1)
The authoritative, deployed founder mechanism — **`fn_is_founder()`** + the **`founder_principals`** table (one active founder principal). No new role system was invented. A key subtlety was handled: `fn_is_founder()` returns TRUE for the **service role** (when `auth.uid()` is NULL and `auth.role() <> 'anon'`), which an edge runs as — so edge-level gating must check the **resolved signed-in user**, added as `fn_is_founder_uid(p_auth_user_id)` (the same `founder_principals` check, keyed by an explicit uid), mirroring the existing `fn_edge_onboarding_allowed(p_auth_user_id)` pattern.

## Already founder-gated (verified live, unchanged)
Store creation + management (`fn_create_free_store`, `fn_store_*`, `fn_storefront_*`), advertising campaigns (`fn_cb_build_campaign`, `fn_creative_campaign_handoff`, `approve_marketing_campaign_draft`, `fn_marketing_director_to_creative_request`), and ad-studio creative production (`fn_creative_studio_generate`, `fn_creative_production_request`, `fn_ad_product_card_select_creative_asset`, `fn_creative_format_apply`) **already call `fn_is_founder()`**. So the directive's store-creation + advertising-campaign + ad-studio-creative items were already enforced; BE346 closed the remaining CS.05 gaps.

## What BE346 added — server-side enforcement (requirements 2, 4, 6) — prepared, not applied
Migration `supabase/migrations/mig_382_be346_creative_studio_founder_only.sql`:
- **`fn_is_founder_uid(p_auth_user_id)`** — canonical edge-side founder check (EXISTS active `founder_principals`); `GRANT EXECUTE` to `service_role`.
- Fail-closed founder gate added to the user-JWT creative RPCs (bodies otherwise unchanged; owner-scoping + PAL + quarantine gates preserved):
  - `fn_product_generated_assets` — **read** generated creative → `founder_only` for non-founders.
  - `fn_commercial_generated_asset_use` — **select/use** a generated creative asset → `founder_only`.
  - `fn_product_image_import_register` — **import a product image for creative generation** → `founder_only` (keyed on `p_tenant`, since this RPC is called via the service role with an explicit tenant).
- Rolled-back selftest.

Edges — explicit FOUNDER-ONLY gate via `fn_is_founder_uid(resolved userId)`, fail-closed, added to **`commercial-image-generate`**, **`commercial-concept-generate`**, **`commercial-video-generate`**. So a subscriber cannot invoke image / Original AI Concept / Hybrid / lifestyle / video generation directly, and cannot spend provider budgets (requirement 4). The gate sits after authentication + the onboarding gate, before any readiness/spend/provider logic.

## Storage, downloads + job execution (requirements 2, 4)
- **Creative asset storage/retrieval:** `pulse-generated-media` is a **private bucket with no permissive policy** → subscribers cannot read it directly; generated-asset signed URLs are **edge-minted (service role) only on the now founder-gated generation edges**. With generation founder-gated, subscribers never possess creative assets to retrieve, and the generated-asset read/select RPCs are founder-gated above.
- **Creative downloads/exports:** gated transitively (no subscriber creative to export) + the founder-gated select RPC; the `media-asset-url` edge should additionally founder-gate `PULSE_GENERATED_*` source types at deploy (research media stays open) — documented deploy-time hardening.
- **Creative-job execution:** the video executor only runs behind the founder-gated `commercial-video-generate` edge + the fail-closed cost-authorization gate (BE344).

## Kept open to subscribers (requirements 5, 7)
Product Discovery, product research, Save, Compare, Monitoring, and CS.02 media discovery/verification (`fn_product_media_discovery`, `product-media-verify`) are **untouched** and remain available to appropriately-entitled subscribers. Ordinary research-image display is **not** confused with permission to generate or download advertising creatives — the founder gate is on generation/asset/import/store/campaign, never on research display.

## Deterministic tests (requirement 8)
Validated on a throwaway Postgres 16 with the real `fn_is_founder` + a seeded `founder_principals` — **selftest 8/8**:
- **Founder access:** `fn_is_founder_uid(founder) = true`; the founder passes the gate on `fn_product_generated_assets` (reaches `product_not_found`, not `founder_only`).
- **Subscriber denial:** `fn_is_founder_uid(subscriber) = false`; read, select/use and import all return `founder_only`.
- **Unauthenticated denial:** `fn_is_founder_uid(null) = false`; the read RPC returns `unauthenticated`.
- **Direct API access:** the tests exercise the RPCs **directly** (the direct-API path); the edges are gated by the same tested `fn_is_founder_uid`.
- **Cross-tenant storage isolation:** the owner-scoping (`v_owner <> v_tenant → cross_tenant_rejected`) is unchanged, pre-proven code; the selftest confirms the founder reaches that owner check after the gate. CS.02 (BE345) independently proved `cross_tenant_rejected` live on the same pattern.

Edge side: `deno check` clean on all three generation edges; the existing concept (9/9) and video (5/5) Deno suites remain green after the gate was added.

## Frontend (requirement 3) — deferred to Lovable credits (7 Dec)
Removing/disabling the Ad Creative Studio navigation + generation controls for subscribers in the preview is **defense-in-depth** and is deferred because Lovable credits are unavailable until 7 December. The **server-side gate above is the authoritative enforcement** (the directive's explicit priority); the frontend removal will follow once credits return.

## Creative Studio development continues toward CS.05 (requirement 9) — not released
CS.05 remains OPEN (no eligible authorised exact-product reference exists; BE345). This founder-only scope change does not release the Studio to subscribers and does not change the CS.05 completion path.

## Roadmap + GOLD (requirement 10)
Launch-critical roadmap + GOLD 11/22 unchanged. GPD.09 + the 18-December launch gates remain the higher priority. This scope change authorises no production deployment and no paid AI calls.

## Production deployment dependencies + rollback
Nothing deployed. Deploy-gated on a separate controlled approval: apply `mig_382`; deploy the founder-gated edges (`commercial-image-generate`, `commercial-concept-generate`, `commercial-video-generate`); optionally add the explicit founder-only `storage.objects` SELECT policy for `pulse-generated-media` and founder-gate `media-asset-url` generated types + the `product-image-import` edge wrapper. Rollback: `CREATE OR REPLACE` the three RPCs back to their pre-BE346 bodies and redeploy the prior edge builds (all changes are additive gates; no existing object's data or non-gate behaviour changed). Production remains `df1e2f6`.

## Evidence
This report, master-doc Addendum 117, Build Evidence row **BE346**, repo commit `578dd15` on `claude/sharp-archimedes-n0l0tl`. Next BE id: **BE347**.

## Strict controls — all honoured
Server-side enforcement prepared + validated; no production deployment; no production migration applied; 0 paid AI/provider calls; no subscriber download; no public release; no rights promotion; no quarantine restoration; no GPD.07; GOLD 11/22 unchanged. Future subscriber access = a new explicit founder decision + fresh security/licensing/release acceptance.
