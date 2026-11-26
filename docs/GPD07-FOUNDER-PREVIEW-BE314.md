# BE314 — GPD.07 founder-only preview connected (inspection path delivered)

**Executed:** 2026-11-26 · **Follows:** BE313 (gated reader + unmounted panel). **Authority:** founder "NEXT STEP AFTER BE313" — connect the existing panel to an **isolated, authenticated, founder-only preview** showing the two genuine observations; **no production deploy, no public/subscriber release, no paid calls, no rights-flag changes.** **Outcome:** founder-only preview route built, verified (build/tests/gate on desktop+mobile), **not deployed**; production unchanged; the founder performs the final authenticated sighting via the path below.

---

## 1. Production & subscriber experience preserved
- `strateloq.com` still serves **`data-commit-sha=8e6a0f6…`** (the BE299/BE300 production build) — **unchanged**. That build predates the GPD.07 panel entirely, so the preview code is **not on production** and **not on any subscriber route**. No `deploy_project` / publish was called.
- The global release flag `GPD07_SOCIAL_ATTENTION_RELEASED` **remains `false`** (unchanged). The preview enables the panel only via an explicit, founder-gated route prop — never globally.

## 2. Backend RPC re-confirmation (step 2)
`fn_gpd07_social_attention_display` (unchanged since BE313; selftest **8/8**):
- **Authenticated tenant access** — `auth.uid()` pins the caller to their own tenant; cross-tenant read → `NOT_OWNED_OR_NOT_FOUND` (selftest check 6).
- **Country-specific identity** — product's stored market **and** the detail's own `product_region` must both equal the requested market (two guards; checks 3–5).
- **Provider rights server-side** — KALODATA `display_derived_cleared` gate → `RIGHTS_BLOCKED` when false (check 8).
- **Zero ≠ unavailable** — present numeric (incl. 0) → value + `present:true`; absent → null + `present:false`; no evidence → `UNAVAILABLE_*` (check 7).
- **No cross-market fallback** — isolation guards return `UNAVAILABLE` with **no counts** (checks 3–4).
- **No raw payload / no other-tenant data** — the RPC returns only a **curated projection** (the 3 counts + `*_present` + market + product name + kalodata id + observation window + acquired-at + label); it does **not** return the raw `kalodata_detail` (no revenue, shop id, category ids, prices, image URLs), and the `user_id = tenant` filter blocks other tenants.

## 3. The founder-only preview (step 3–5)
New isolated internal route **`/dev/gpd07-social-attention-preview`** (matching the existing `/dev/*` convention: `ssr:false`, `robots: noindex,nofollow`, not in any navigation/sitemap). Founder-gated via `useSession()`:
- loading → "Loading…"; signed-out → "Sign in required — restricted to the founder account" + link to `/auth`; non-founder → "Restricted to the founder account"; **founder only** → the preview body.
- The gate matches the founder's **Supabase auth user id** (an opaque UUID constant; the founder's email is **not** embedded in the bundle).

Preview content (uses the live RPC with the founder's own session — the panel is enabled here via `previewEnabled`, the global flag stays off):
- **Live genuine observations:** Shark BlastBoss · DE and Insignia 40″ F40 TV · US (these render **109/220/124** and **424/341/1223** when the founder is signed in, via the live RPC).
- **Country isolation:** Shark BlastBoss requested as **US** and as **GB** → honest `UNAVAILABLE` with **no borrowed DE counts**.
- **Zero vs missing:** an **explicitly-labelled illustrative example** (genuine 0 for creators vs a missing "—" for videos) — clearly marked "not live Kalodata data" so nothing fabricated is presented as real.
- Each panel shows the explicit **Kalodata attribution**, the **observation period** (last 7 days + acquired timestamp), and the label **"TikTok social attention / promotional activity — not verified market demand."**

## 4. Verification (step 6)
- **Unit tests:** `social-attention-panel.test.tsx` = **7/7 pass** (adds: `previewEnabled` renders while the global flag is off; without it still renders nothing and never fetches).
- **Typecheck:** passed (no production build forced).
- **Rendering (desktop + mobile):** the signed-out founder gate was rendered via Playwright at **1280px and 375px** — **no horizontal overflow**, `robots noindex,nofollow` present. (Build-server verification; the authenticated data view is the founder's sighting — see §6.)
- **Scope:** only `social-attention-panel.tsx`, `social-attention-panel.test.tsx`, and the new route file changed (route registry `routeTree.gen.ts` updated automatically); **no other route or subscriber page touched**. Committed in Lovable `90f8d752`. **Not deployed.**

## 5. Inspection path for the founder (step 7)
**URL:** `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app/dev/gpd07-social-attention-preview`

Steps:
1. Open the **Lovable preview** for this project (the `id-preview--…lovable.app` address above), or the Preview pane inside the Lovable editor.
2. If prompted, **sign in with the founder account** at `…lovable.app/auth` (the same account that owns the two products). The preview uses your live session.
3. Go to **`/dev/gpd07-social-attention-preview`**.
4. You should see:
   - **Shark BlastBoss · Germany:** 109 creators · 220 videos · 124 livestreams.
   - **Insignia F40 TV · United States:** 424 creators · 341 videos · 1,223 livestreams.
   - Kalodata attribution, "last 7 days" observation period + acquired timestamp, and the "not verified market demand" label on each.
   - The isolation panels (US/GB on the DE product) showing **no counts** (no cross-market borrowing).
   - The illustrative zero-vs-missing card.
5. Check the same page on a phone-width window — the layout stacks to one column with no horizontal scrolling.

*(This container's network policy blocks the `lovable.app` preview host, so I could not load the public URL from here; the route was verified on the Lovable build server instead, and the authenticated sighting is intentionally the founder's.)*

## 6. GPD.07 acceptance status (step 8)
**GPD.07 is NOT accepted merely because the social metrics display.** The original gate has **separate requirements** assessed independently:
- **Social-attention ≠ search-demand.** This preview shows TikTok **promotional activity** (creators/videos/livestreams), truthfully labelled as *not* verified market demand. The gate's **search-demand** requirement is a separate signal (DataForSEO Google-Ads search volume; GPD.06), unaffected by this work and still subject to the unresolved Google-upstream display clearance (counsel legs, pending).
- **Remaining criteria for GPD.07 acceptance:** (a) a **founder release decision** — flip `GPD07_SOCIAL_ATTENTION_RELEASED` to true and mount the panel on the real subscriber product-research view, then deploy; (b) **production acceptance sighting** by the founder on that released surface; (c) the gate's own social-demand + search-demand criteria assessed against the original definition (social-attention alone does not satisfy a demand claim); (d) optional GB/IE/IT breadth once those products are mapped (no speculative spend).

## 7. Controls
0 paid Kalodata calls; 0 API credits; **no production deployment**; no public/subscriber release; **no rights-flag change** (`GPD07_SOCIAL_ATTENTION_RELEASED` stays false; KALODATA source-rights unchanged); RLS / Product Asset Lock / country isolation / provider budgets preserved. **Historical GOLD 11/22 unchanged.** Build Evidence row **BE314**.
