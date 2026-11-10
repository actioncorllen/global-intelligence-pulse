# Post-Live-Test — Image CX & Modal Accuracy (2026-11-10)

Follow-up to the passed bounded live test. No paid provider call, no rebuild. Audit, isolation, market isolation
and Product Asset Lock preserved; budgets/allowances remain inactive.

## 1. Image-resolution findings for the 3 new products
The 3 new DE products from the test:
- `cee549c3…` "Ninja CrushBOSS 3-in-1-Küchensystem…"
- `4e6acd83…` "XXL Adventskalender"
- `e45a427a…` "1x Pokemon Flash Fire Booster EN"

All three have **no image asset** (`product_image_assets = none`; `fn_product_card_display_image → no_product_image`).

**Root cause (verified, not a defect):** the Kalodata `tiktok/product/rank` response **does not return a product
cover image**. `fn_extract_cover_url` already scans 16 cover-field variants (`cover`/`image`/`thumbnail`/… ,
https-only, excludes `/default/` placeholders) and is correct; the rank rows simply contain no image URL, so
nothing is persisted. The edge's own promoted output (net request 181) carries name/price/id but **no image
field**. This matches the known pattern: **FastMoss discovery returns reference images (those products are the 9
visible DE cards), but Kalodata rank discovery is image-less.** The raw rank rows are not retained, so there is
nothing to re-extract for these 3.

## 2. Can any of the 3 become display-eligible without additional expenditure?
**No — 0 of 3 via a verified non-chargeable path.** The only ways to obtain a permitted display image are **paid or
rights-unsafe**, and both are excluded by this directive:
- **Kalodata Product Images API** — 0.01 provider credit/product (≈ $0.001 each at the reference rate). An
  already-authorised provider, but **chargeable** → needs founder approval (the founder said no additional credits).
- **CJ / supplier match** — chargeable and requires an exact supplier identity match.
- **TikTok Shop / marketplace scrape** — **excluded**: marketplace images are not assumed to carry commercial
  rights (Product Asset Lock), and exact-product fidelity must be preserved (no similar-looking substitutes).

The image gate is **working as designed**: it correctly hides the 3 image-less products (stored, not deleted) until
a permitted image exists, so nothing without rights is ever shown. This is a **commercial decision** (approve a tiny
Kalodata Images API spend, or a supplier path), not a technical defect or a non-chargeable fix.

## 3. Refresh modal accuracy
The async result the modal consumes (`fn_discovery_refresh_status`) returned: `new_total=3`, `new_visible=0`,
`new_image_pending=3`, `duplicates=7`, settlement `"1 credits used"`. The unified modal (`c1a6afa`) renders these as
four tiles + settlement: **"New candidates" = 3**, **"New visible products" = 0**, **"Already known" = 7**,
**"Waiting for an image" = 3**, and **"1 credit used"**. "Ten products examined" = New candidates (3) + Already known
(7), shown as its two components. **The modal is accurate and does not suggest the 3 new products are immediately
available** (New visible = 0, Waiting for an image = 3). No change required. *(Optional, not built: an explicit
"examined: 10" total — purely additive; current tiles already convey it and the safety bar is met.)*

## 4. Readiness & blockers
- **Technically ready** for founding-member activation (the paid lifecycle passed end-to-end live; image gate + PAL
  correct; modal accurate).
- **The image CX is a commercial decision, not a technical blocker:** Kalodata-discovered products need a small,
  separate (chargeable) image-acquisition step to become customer-visible. Decide per product/market whether to fund
  the Kalodata Images API (≈0.01 credit each) or a supplier path, budget-gated like the rank call.
- Remaining launch gates are unchanged: confirmed $/credit purchase price + subscription price; founder-device
  live-UI acceptance; competitive + legal gates.
