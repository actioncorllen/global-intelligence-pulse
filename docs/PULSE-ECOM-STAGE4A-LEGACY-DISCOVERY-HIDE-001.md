# PULSE-ECOM-STAGE4A-LEGACY-DISCOVERY-HIDE-001

**Founder decision executed: 21 legacy / research-concept products are now hidden from the active
customer-facing Product Discovery experience, reversibly and without deleting anything. The genuine 57
recent FastMoss/Kalodata discoveries remain visible and keep progressing. No paid calls; tenant/country
isolation preserved; existing store/publishing references preserved and untouched.** (mig_321)

## Classification (req 1) — verified source + timestamp + lifecycle
- **GENUINE recent discoveries (KEEP, 57):** `source_store IN ('fastmoss','kalodata')` — the live
  TikTok-Shop discovery lanes, each with a `COMMERCE_PRODUCT_NATIVE` signal, first seen 2026-10-12/19.
- **LEGACY research-concepts (HIDE, 21):** `source_store IN ('dataforseo','reddit','industry_blog')` or
  NULL — generic keyword seeds first seen Sept–early Oct, with no native discovery signal.
- Hiding is by **lane only** — never by researched-ness or source date — so a genuine recent FastMoss
  product is never hidden merely for having been researched or for an older publication date (req 3).
  Verified: **0 fastmoss/kalodata products are in the hide-list.**

## Mechanism (reqs 2, 4) — reversible hide-list, no deletes
- New table `commerce_discovery_hidden` (tenant_id, product_id, reason, source snapshot, hidden_at) — one
  audit row per hidden product; RLS-on, service-role only. Reverse by deleting a row.
- Predicate `fn_discovery_product_hidden(tenant, product)` applied to the customer-facing discovery reads:
  - **`fn_monday_top_opportunities`** (recommendation feed) — the primary leak: **26 legacy rows before → 0 after**.
  - **`fn_project_discovered_candidates`** (feeder) — never re-projects a hidden product into decisions.
  - **`fn_product_explorer`** (belt) — already excluded legacy (needs a native signal); predicate future-proofs it.
  - `get_own_discovery_intelligence` → commerce_opportunities was already clean (**0 legacy**, run-scoped), so it was left unmodified.
- **Nothing deleted.** commerce_products, signals, supplier bindings (incl. the nightlight's bound CJ
  supplier), audit rows, product pages and store-product rows are all intact.

## Exactly which products were HIDDEN (21)
- **Named:** `kids nightlight projector` (reddit) ✓, `cool mist humidifier` (dataforseo) ✓.
- **dataforseo (9):** vb cable, porter cable, coaxial cable, cable pull-through, cable tray, overhead
  extensions cable, cool air humidifier, humidifier for room, cool mist humidifier.
- **reddit (10):** kids nightlight projector, digital picture frame, cordless ring light, over door shoe
  organizer, red light therapy led mask, reusable cooler ice pack, side lying support pillow, side
  sleeper bed pillow, side sleeper sleep mask, travel neck pillow.
- **industry_blog (1):** magnetic keyboard case.
- **NULL source (1):** 3 Channel Dash Cam.

## Which products REMAIN VISIBLE
- **57 genuine active products** (all fastmoss/kalodata). The recommendation feed now returns **8
  genuine watchlist products, 0 legacy** — e.g. Illuminated Snowman Door Hanger, Beleuchtete Krippen
  Wanddekoration, Herren-Fleecejacke (fastmoss); ESN Proteinriegel, Makita/More/Ankerkraut
  Adventskalender, Hit the Slab (kalodata). The Explorer continues to show the fastmoss/kalodata set.

## Active store references (req 4) — reported, NOT affected
The discovery-hide only filters discovery READS; it does not touch product pages or store products.
Current state of the hidden products' store references (all PRESERVED):
- **2 legacy products have PUBLISHED product pages with live URLs: `3 Channel Dash Cam` and `kids
  nightlight projector`.** These pages remain PUBLISHED and live — the hide does **not** unpublish them.
- 4 more have UNPUBLISHED pages (red light therapy led mask, digital picture frame, cool mist humidifier,
  over door shoe organizer).
- 5 archived store-product rows, **0 storefront-visible**; 0 campaign-builder drafts.
- **No active store reference is changed by this task.** If the founder wants the 2 live published pages
  taken down as well, that is a separate, explicitly-approved action (it alters a live outward-facing
  store reference) — not done here.

## Preservation & isolation (reqs 4, 5, 6) — PASS
- **Tenant/country isolation:** the hide-list and every predicate are tenant-scoped; only this tenant was
  seeded; other tenants unaffected; no country relabelling.
- **New FastMoss discoveries unaffected (req 5):** they are not in the hide-list and flow normally through
  discovery → supplier verification → Product Intelligence.
- **Accurate counts (req 6):** 57 active / 21 hidden; recommendation feed legacy leak 26 → 0; 0 genuine
  products wrongly hidden.

## Verify (req 7) — fix → test → re-test → deploy → verify
Deployed mig_321; verified live: feed returns 8 genuine watchlist products and **0 hidden-product leaks**;
both named products test hidden; 0 fastmoss/kalodata wrongly hidden; store references intact (2 PUBLISHED
pages still live, 0 storefront-visible).

## Status
| Req | Verdict |
|---|---|
| 1 — identify legacy vs genuine (source/timestamp/lifecycle) | **PASS** |
| 2 — exclude legacy (incl. nightlight + humidifier) from Explorer / recommendations / discovery lists | **PASS** (feed 26→0) |
| 3 — don't remove genuine recent FastMoss (researched/older-date) | **PASS** (0 wrongly hidden) |
| 4 — preserve evidence/bindings/audit/store refs; no delete | **PASS** (hide-list, no deletes) |
| 5 — new FastMoss discoveries still progress | **PASS** |
| 6 — tenant/country isolation, accurate counts, no stale legacy | **PASS** |
| 7 — fix → test → re-test → deploy → verify | **PASS** |

**Overall: PASS.** 21 legacy products hidden from customer-facing discovery (reversibly); 57 genuine
discoveries remain; no deletions; 2 legacy products retain live published store pages that are preserved
and unaffected (flagged for a separate decision if take-down is wanted).

**STOP at Stage 4A.** No supplier expansion, saturation or country recommendations; no paid calls; Stage
4B not started.
