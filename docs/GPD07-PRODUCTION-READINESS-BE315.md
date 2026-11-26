# BE315 — GPD.07 social-attention: production-ready behind the release flag (implementation READY)

**Executed:** 2026-11-26 · **Follows:** BE314 (founder-accepted preview). **Authority:** founder "GPD.07 PRODUCTION RELEASE READINESS" — finish the implementation so it is production-ready, fully tested, awaiting only a separate founder release decision. **Strict controls honoured:** no production deploy, no subscriber release, no rights-flag change, no Kalodata paid calls, no credit purchases, no source-data release, no weakening of RLS/PAL/country isolation; **historical GOLD 11/22 preserved.** **Outcome:** the social-attention implementation is **READY** (wired, gated, tested, no defects); the **original GPD.07 GOLD gate remains OPEN** (separate demand + legal requirements, below).

---

## 1. What was done (reuse-first, no rebuild)
Reused BE312 evidence, BE313 RPC/gates, the existing `SocialAttentionPanel`, the BE314 preview, and the existing `ProductIntelligenceDrawer`. Changes (Lovable commits **`be82eeb`** + **`f33ad85`**):

- **Structural bypass-proofing** — split `social-attention-panel.tsx` into:
  - `SocialAttentionPanel({ productId, market })` — **customer entry point with NO bypass parameter**; gates purely on `GPD07_SOCIAL_ATTENTION_RELEASED` (false → renders null and issues **no** social-data request).
  - `SocialAttentionPreviewPanel({ productId, market })` — **founder-preview only** (flag-independent), used solely by the `/dev` route. It is structurally impossible for the customer path to pass a bypass flag.
- **Wired into the real customer research view** — `SocialAttentionPanel` is mounted in **both** `ProductIntelligenceDrawer` layouts (detail + standard), gated on `open && researchProductId && market`, right beside the existing `ResearchImagesBlock`. Shared by `ecommerce-workspace` and `product-explorer`, so the whole customer research journey gains it — invisible while the flag is off.
- **Exact-product identity at the display layer** — restored a remount `key={productId:market}` on both wrappers so switching products never shows the previous product's counts under a new product (a cross-product/cross-market display leak). A test holds the next fetch pending and asserts the old counts are gone during the switch; verified it **fails without the key, passes with it**.
- **Founder `/dev` preview** updated to use `SocialAttentionPreviewPanel` — still works exactly as BE314.

Backend unchanged: the RPC `fn_gpd07_social_attention_display` remains the authoritative rights/tenant/country gate for **both** paths; frontend flags cannot weaken it.

## 2. Evidence integrity (what the panel shows)
Only: product-matched `creator_number`, `video_number`, `live_number`; selected country; observation period (last 7 days) + acquisition timestamp; **Kalodata** attribution. Labelled **"TikTok social attention / promotional activity — not verified market demand."** These counts are never substituted for verified search demand, revenue, growth or sales. Unavailable markets show honest UNAVAILABLE; no cross-country borrowing. The RPC returns a curated projection only (no raw provider payload).

## 3. Focused regression (step 4) — all green
| Check | Result |
|---|---|
| Founder/approved-member auth | RPC pins `auth.uid()`; `/dev` preview founder-gated — verified |
| Tenant isolation | `user_id = tenant`; foreign tenant → NOT_OWNED (selftest 8/8) |
| Country isolation | two guards; no borrow (selftest + drawer test) |
| Exact-product identity | remount key + response guard; stale-display test passes |
| Rights-gate enforcement | KALODATA `display_derived_cleared` server-side (selftest) |
| Release flag OFF | `GPD07_SOCIAL_ATTENTION_RELEASED = false` — confirmed |
| No preview bypass for subscribers | customer panel has no bypass param; drawer test asserts **no fetch** + panel hidden in both layouts |
| Genuine zero vs missing | 0+present vs null+not-present (unit tests) |
| Desktop & mobile | gate verified at 1280px + 375px, no overflow (BE314); drawer layout unchanged |
| Existing product-research behaviour | **19/19** drawer regression tests pass |
| No raw media access/download | panel returns no media/URLs; RPC omits image fields |
| No unauthorised source-data disclosure | curated projection only; other tenants blocked |

**Tests:** `social-attention-panel.test.tsx` **8/8**, `product-intelligence.social-attention.test.tsx` **2/2**, drawer regression suites **19/19**; project **typecheck passed**. No unresolved defects.

## 4. Final acceptance definition (step 5) — kept separate
- **A. Social-attention implementation readiness** — **READY.** Wired, gated, bypass-proof, tested, no defects, not deployed. Awaiting only a founder release decision.
- **B. GPD.07 original search-and-social-demand requirements** — **NOT met by this work.** Social-attention (TikTok promotional activity) is **not** verified consumer demand. The gate's search-demand signal (DataForSEO Google-Ads) and a genuine social-demand assessment are separate and unmet; displaying promotional counts does not satisfy them.
- **C. GPD.01/06 Google-upstream legal dependency** — **UNRESOLVED.** DataForSEO search-demand display remains gated on the Google-upstream clearance (counsel Leg 1/Leg 2; RDJ + UCC enquiries pending). Independent of this Kalodata work (Kalodata derived display is already cleared), but required before search-demand can be shown.
- **D. Optional additional market breadth** — GB/IE/IT have no verified `kalodata_product_id` mappings; broadening needs founder-budgeted ingest (no speculative spend). Optional, not required for A.

**Original GPD.07 GOLD is NOT accepted merely because social promotional counts display.** It stays OPEN pending B (and, for the search-demand half, C). GOLD remains **11/22**.

## 5. Report (step 6)
- **Files / commits (Lovable):** `social-attention-panel.tsx`, `social-attention-panel.test.tsx`, `product-intelligence.tsx`, `product-intelligence.social-attention.test.tsx` (new), `dev.gpd07-social-attention-preview.tsx` — commits **`be82eeb`** (wiring) and **`f33ad85`** (remount-key fix). Backend reader `fn_gpd07_social_attention_display` is the BE313 `mig_369`/`mig_369b` (this repo).
- **Test results:** 10 social-attention + 19 drawer regression tests pass; typecheck clean.
- **Release flag state:** `GPD07_SOCIAL_ATTENTION_RELEASED = false`.
- **Unresolved defects:** none.
- **Remaining legal/data limitations:** B (demand ≠ social-attention) and C (Google-upstream clearance, pending counsel) for the original GPD.07 gate; D (market breadth) optional.
- **Exact production deployment change proposed (a separate, founder-authorised action — NOT performed here):**
  1. In `src/lib/gpd07/release-flag.ts`, set `GPD07_SOCIAL_ATTENTION_RELEASED = true`.
  2. Deploy the Lovable project to production (`deploy_project`) — publishes the current commit (the wiring + fix) to strateloq.com.
  - No backend change (RPC already live), no rights-flag change (KALODATA display already cleared). After release, each authenticated subscriber sees the panel only for **their own** products that have Kalodata detail in the selected market; all others show honest UNAVAILABLE (currently only the founder tenant's 2 products carry detail).
- **Release candidate:** **READY** for the implementation — it builds, tests pass, it is correctly gated and bypass-proof, and it awaits only the founder's explicit release decision (flip flag + deploy). The **original GPD.07 GOLD acceptance remains BLOCKED** on B and C and is not changed by this release.

## 6. Controls
0 Kalodata paid calls; 0 credits; **no production deploy**; **no subscriber release**; **no rights-flag change** (flag false; KALODATA source-rights unchanged); RLS / Product Asset Lock / country isolation / provider budgets preserved. **Historical GOLD 11/22 unchanged.** Build Evidence row **BE315**.
