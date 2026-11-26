# BE317 — Design 2 Product Research: finishing/polish pass + founder visual-acceptance handoff

**Executed:** 2026-11-26 · **Follows:** BE316 (first redesign pass). **Authority:** founder "FINALISE APPROVED DESIGN 2" (26 Nov). **Clarification honoured:** "Design 2" = the **second of the three Strateloq mockups** (the dropship.it screenshot was a competitor example only — its interface/charts/figures/branding were NOT reproduced). The authoritative reference used is the founder's **written approved direction**. **Controls:** no production deploy, no subscriber release, no rights-flag change, no paid calls, GOLD 11/22 unchanged. **Verdict: READY FOR FOUNDER VISUAL ACCEPTANCE.**

---

## Task 1 — finish the design (self-reviewed with real screenshots)
The `/dev/product-intelligence` harness renders the real `ProductIntelligenceDrawer` with fixtures **without auth**, so the build agent captured Playwright screenshots at **1280px** and **375px** (drawer, page chrome, and a sibling screen) and reviewed them against the written direction. Issues found and **fixed** (Lovable commit `f06d035`):
- **Removed the evidence donut/ring chart** (it echoed the competitor's donut; the approved direction has no charts). The real evidence-family data stays in the Evidence tab.
- **Compact cards reflowed** with container queries: 1 col very-narrow → 2 on phones → 3 on the standard panel → 6 on the wide layout; **even heights**; **label on its own line** (no more one-letter truncation / mid-word breaks seen pre-fix); "Unknown"/"Unavailable"/"Not verified" in stronger text.
- **Teal secondary accent fixed** — the `--color-teal*` tokens were not registered in `@theme inline`, so the teal icon chips weren't rendering; now they do.
- **Tabs** are 44px tall, bolder, with visible keyboard focus; the bar scrolls sideways only when needed.
- **Mobile header** left-aligned with room for the close button; **no horizontal overflow** at either width.
- **"?" help icons** are keyboard-reachable and show tooltips.

## Task 2 — commercial rights (no field invented)
Confirmed there is **no authoritative per-product commercial-rights field**: the product-intelligence contract decodes media **display**-rights only (`rights_state`/`reference_only`) and is explicitly "research display, **never commercial rights**"; commercial rights live at provider level (`catalogue_source_rights`) + Product Asset Lock. Per the directive, no provider→product promotion and no speculative score. ⇒ The card **keeps "Not verified"** and now has a concise tooltip: *"Research view — per-product commercial rights are not verified here. Source/provider rights and asset locks are enforced server-side."* No rights flag changed.

## Task 3 — workspace scope (narrow)
The light-background + navy-nav tokens are shared chrome. Screenshot check of `/dev/market-explorer` (Product × Country) reads cleanly with good contrast — the token change did not break it. Only the Product Research surface + the shared chrome colours changed; workspace navigation, search, discovery, saved products, country comparison and monitoring are untouched. **No separate Workspace Overview redesign was performed** (not authorised).

## Task 4 — GPD.07 preservation (unchanged)
`GPD07_SOCIAL_ATTENTION_RELEASED` stays **false**; the customer `SocialAttentionPanel` stays gated (hidden, no fetch); the BE314 founder-only `/dev` social-attention preview is intact; the BE315 customer-drawer integration + exact-product remount isolation are intact. No social metrics exposed in production.

## Task 5 — validation
Verified via the fixture harness + tests: four tabs (purple active underline, 44px, focus-visible); compact cards with real values + honest Unknown/Unavailable; commercial-rights honesty; release-gated social panel stays hidden; desktop/tablet/mobile with no overflow; keyboard focus. **Product image + Compare/Save buttons could not be screenshotted** — the `/dev` fixture has no image and no header actions; they appear only on the authenticated product page. They are styled as purple rounded pills on the **existing** Compare-Countries link + Save toggle (no new/fake buttons). Tests: the 9 product-research files **35/35**; typecheck **pass**; full suite not re-run (no change required it).

## Task 6 — founder visual-acceptance handoff
1. **Preview URL + steps:** `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app` → **sign in** → **/workspace → Products** → open any product → the Design-2 detail drawer. Check desktop **and** mobile.
2. **Screenshots:** captured by the build agent at 1280px + 375px for its self-review (and used to drive the fixes above); they live in the build sandbox and **cannot be surfaced into this chat** (the `lovable.app` preview host is blocked from this environment and authenticated views need your login). Your live preview is the authoritative visual acceptance.
3. **Remaining differences vs the written direction:** none material in the fixture review; the **product-image header** and **Compare/Save pills** are unverified-by-screenshot (absent from the fixture) — please confirm them on the authenticated page.
4. **Unresolved defects:** none found.
5. **Focused test results:** 35/35 product-research regression; typecheck pass.
6. **Final commits:** `6ff369d` (BE316 redesign) + **`f06d035`** (BE317 polish).
7. **Production:** unchanged — `strateloq.com` still serves the accepted `8e6a0f6` build; nothing deployed.

**Verdict: READY FOR FOUNDER VISUAL ACCEPTANCE.** The implementation matches the written approved direction, was self-reviewed with real screenshots and corrected, passes the focused tests + typecheck, preserves all data/security/GPD.07 constraints, and leaves production unchanged. *Only the design direction has been approved — this is not founder-approved in production.* **Do not request production-release authorisation until the founder has inspected and accepted the live redesigned interface.**

## Controls
0 paid calls; 0 provider credits; **no production deploy**; **no subscriber release**; **no rights-flag change**; RLS / PAL / country isolation / provider permissions preserved; **GOLD 11/22 unchanged**. Lovable commit `f06d035` (3.5 credits). Build Evidence row **BE317**.
