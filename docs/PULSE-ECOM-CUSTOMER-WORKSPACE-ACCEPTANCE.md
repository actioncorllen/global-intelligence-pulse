# Customer Workspace Acceptance — Production (2026-11-09)

Post-Stage-B acceptance of the production application. Verified against the **live production database + live
production HTML/bundle**. `strateloq.com` is founder-confirmed open; this cloud session's egress proxy blocks
`strateloq.com`, and there are no founder credentials here, so **authenticated in-browser interactions are
founder-device checks** (marked PARTIAL — backend/source verified, live UI unobserved). No PASS is claimed for an
unobserved browser interaction. **No paid API calls. No activation. Production data preserved.**

## Production website version
Unified **Strateloq** frontend. Live production HTML title: `Strateloq — Global Intelligence for What's Next`;
main bundle `index-D9LypSvy.js`; Lovable project `is_published: true`, `latest_commit_sha c1a6afa`. Banned terms
absent in the live bundle (`Strateloq AI` 0, `Global Intelligence Actions` 0, `globalintelligenceactions.com` 0);
`Pulse Intelligence` ×9 = MCP connector names (documented intentional exception, not website copy).

## Priority 1 — Authenticated workspace (verified behaviour, not just source)

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Homepage + Strateloq branding | **PASS** | Live production HTML title/description + bundle branding; founder confirms domain opens |
| 2 | Founder sign-in | **PARTIAL** | Supabase Auth configured; live sign-in = founder-device |
| 3 | Dashboard navigation | **PARTIAL** | `fn_ecommerce_workspace_intelligence` returns dashboard data live; live nav = founder-device |
| 4 | Product Discovery | **PASS (backend)** | Explorer v5 returns live products; UI interaction = founder-device |
| 5 | Country selector | **PASS (isolation)** | Market-scoped: DE 9 visible vs GB 20 visible, distinct sets; selector click = founder-device |
| 6 | Product Explorer cards | **PASS (data)** | 9 DE cards with image, identity, price (EUR), decision, honest metric labels; visual render = founder-device |
| 7 | Recommendations | **PASS** | Tiered (GOLD/PREMIUM/PLATINUM/watchlist); accurate product_id + full title; honest UNKNOWN/unverified labels |
| 8 | Product detail drawer | **PASS (backend)** | `fn_stage3b_product_card_authenticated` returns identity, asset_lock (PAL), economics, supplier, commercial_verification; live open = founder-device |
| 9 | Add to My Store | **PARTIAL** | `ADD_TO_STORE` action offered + enabled (`reason: ready`); existing active store with added product is evidence; live click = founder-device |
| 10 | Create Free Store | **PARTIAL** | `create_free_store` route; "Strateloq Test Store" already created (evidence); live click = founder-device |
| 11 | My Store navigation | **PASS (backend)** | `fn_hosted_store_get` returns active store + member product + history; live nav = founder-device |
| 12 | Mobile + desktop responsiveness | **PARTIAL** | Desktop preview render shows correct layout; responsive code verified; live mobile render = founder-device |
| 13 | Founding-member access restrictions | **PASS** | `fn_founding_access_control_selftest` 12/12 (expired/revoked/consumed/wrong-email rejected; apply creates no account; no self-provision; anon can't issue/accept; overbroad grants revoked) |
| 14 | Refresh Discovery modal | **PARTIAL** | Backend fail-closed + contract logic verified (below); live click = founder-device |

## Priority 2 — Refresh Discovery button

| Check | Result | Evidence |
|---|---|---|
| Clickable | PARTIAL (source) | Always-clickable control (`RefreshDiscoveryControl`) |
| Opens modal | PARTIAL (source) | `onClick` opens dialog |
| Identifies selected country | PARTIAL (source) | `countryDisplayName`; "Search for newly discovered products in {country}" |
| Correct unavailable state while pricing unconfigured | **PASS (backend + logic)** | `fn_discovery_refresh_quote` → `can_refresh=false / PRICING_NOT_CONFIGURED`; decoder → modal shows "Refresh pricing hasn't been set up yet, so a refresh can't run right now." + Confirm **disabled** |
| Prevents unauthorised credit reservations | **PASS** | `fn_discovery_refresh_reserve` → `denied / PRICING_NOT_CONFIGURED`; confirm disabled (`canRefresh=false`) |
| Does not initiate paid provider requests | **PASS** | Fail-closed; 0 provider budgets; reserve denied → no authorize/fire/edge |
| Cannot trigger automatic deep research | **PASS** | Edge v13 passes `p_suppress_auto_research=true` for refresh; and no refresh can run while fail-closed |

## Priority 3 — Product quality

| Check | Result | Evidence |
|---|---|---|
| Customer-visible products have genuine permitted display images | **PASS** | Explorer visible item: `rights_state=PROVIDER_DISCOVERY_REFERENCE`, `display_cleared=true`, `image_status=DISPLAY`; `image_authority.has_display_image=true` |
| Product Asset Lock enforced | **PASS** | `commercial_cleared=false`, `authority=REFERENCE_ONLY`; drawer carries `asset_lock` |
| No unrelated product imagery | **PASS** | Images tenant+product scoped; `display_image_count=1` for the product |
| Country-specific evidence isolated | **PASS** | Market-scoped reads; DE vs GB distinct sets |
| Recommendations preserve accurate identity | **PASS** | `product_id` + full product title in each rec |
| Hidden image-pending products stored internally | **PASS** | DE 20 hidden pending image; gate hides (not deletes) REFERENCE/NONE |
| No customer-facing false supplier/market claims | **PASS** | `growth_status=UNVERIFIED`, `market_price=UNKNOWN`, `supplier_match=unresolved`, `measured_roi=none` — honestly labelled |

## Defects fixed
**None required.** The only red signal (founding self-test 5/12) was a test-input artifact (a non-existent fixture
uid making `bound_email` NULL); re-run with a valid no-member user → **12/12 PASS**. No code defect, nothing
deployed.

## Remaining founder-device checks (small set; backend already verified)
In-browser at strateloq.com, signed in as founder: sign-in, dashboard nav, Product Discovery interaction, country
selector click, card visual render, drawer open, Add-to-Store click, Create-Free-Store click, My Store nav, mobile
render, Refresh Discovery modal click. All are backed by verified backend behaviour; they need founder eyes on the
live UI only.

## Exact next activation blocker
**Commercial activation** — founder supplies Kalodata $-per-call evidence + subscription price, then sets
price/allowance/provider-budget per `PULSE-ECOM-COMMERCIAL-ACTIVATION-PLAN.md`. The backend is deployed and
fail-closed; the domain is live (founder-confirmed). Target 18 Dec 2026 on track.
