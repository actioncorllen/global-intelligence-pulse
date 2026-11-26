# BE316 — Product Research UI redesign to Design 2 (preview; founder visual acceptance pending)

**Executed:** 2026-11-26 · **Authority:** founder "APPROVED PRODUCT RESEARCH UI REDESIGN" (Design 2 selected of 3). **Controls honoured:** no production deploy, no subscriber release, no rights-flag change, no paid calls, GOLD 11/22 unchanged. **Outcome:** Design-2 restyle of the existing Product Research detail + shared chrome, **Lovable preview only**; full test suite green; awaiting the founder's visual acceptance.

---

## Design 2 reference (what it is)
The founder's Design 2 is a **third-party tool's dashboard screenshot (dropship.it)** used purely as a **visual-style reference** — clean white background, thin dark-navy nav, a top tab bar with a **purple active tab**, a grid of **compact white cards** (small coloured icon chip + label + "?" help + big bold value), pill action buttons with trailing icons, and **purple + teal/mint** accents with donut/area charts. Its demo numbers (5020%, eBay.com, "crazywitch_0", sales trend) are the reference tool's fake data and were **not** copied. Confirmed scope with the founder: build from the written requirements 1–10 in this style; **restyle the existing drawer in place** (not a new page).

## What changed (Lovable commit `6ff369d`; files: `src/styles.css`, `src/components/layout/top-nav.tsx`, `src/components/business-discovery/product-intelligence.tsx`, `src/components/business-discovery/product-explorer.tsx`, `AGENTS.md`)
- **Chrome (req 1–3):** the signed-in workspace now uses a **light/white background**, a **dark-navy top nav** (a scoped `.workspace-nav-navy` token layer so controls stay readable on navy), **purple** primary accent and **teal** secondary — via the existing design-token system (no hardcoded hex where tokens exist). The detail drawer (a portalled Sheet) now carries the light `workspace-design-3` scope so it no longer falls back to the old dark root tokens.
- **Product header (req 4):** the product's REFERENCE image sits prominently on the left with title + category + market + identity label beside it; existing image-rights gating / REFERENCE_ONLY / "No reference image available" fallback preserved (no unlicensed image).
- **Actions (req 5):** "Compare countries" and "Save" are now high-contrast **rounded purple pill buttons**, wired to their existing authorised handlers (the Compare-Countries route + the Save toggle). **No** new Export / Refresh / Scan / supplier-verification / paid-refresh buttons or fake handlers were added.
- **Compact cards (req 6):** six Design-2 stat cards — Opportunity stage, Evidence families (qualifying / checked), Freshness, Evaluation date, Price — from the **real** values; honest "Unknown"/"Unavailable" where a value is absent. **Commercial rights shows "Not verified"** honestly (the product-detail contract carries no rights field; it is not fabricated — see unresolved item 1).
- **Four tabs (req 7):** Overview, Evidence, Market Intelligence, Supplier Match, with a purple underline on the active tab; the existing sections were reorganised under them (inactive panels stay mounted, hidden with CSS, so every gated section keeps its data source + empty/UNKNOWN state). Opening the drawer on the supplier focus now lands on the Supplier Match tab. Two inner sections were renamed to avoid a name clash with the tabs ("Overview"→"Opportunity summary", "Evidence"→"Evidence families").
- **Charts (req 7):** the only chart is an **evidence-coverage ring** on the Evidence tab, built from this product's **real** evidence-family states (qualifying / present-but-insufficient / other) — purple + teal. No market-share or sales-trend chart was fabricated (no such data in the drawer).
- **White cards, subtle borders, rounded corners, clear typography** applied throughout; responsive layout.

## Data & security preserved (all hold)
- Never invents metrics/suppliers/prices/evidence/scores; none of the reference screenshot's numbers/labels were copied.
- Real product images + rights restrictions preserved; country-isolated intelligence preserved; authenticated access, tenant isolation, RLS, Product Asset Lock and all source-rights gates unchanged.
- Founder-only store/advertising controls remain restricted; the **BE314 founder-only `/dev` social-attention preview is unchanged**; the **customer `SocialAttentionPanel` stays gated** (`GPD07_SOCIAL_ATTENTION_RELEASED` still **false**); withheld Meta/eBay/DataForSEO observations keep their DISPLAY_PENDING_RIGHTS / NOT_AUTHORISED gating.

## Tests (all green)
| Group | Pass/Fail |
|---|---|
| Requested product-research regression (9 files) | **35 / 0** |
| **Full suite (117 files)** | **1,091 / 0** |
| Typecheck | **pass (exit 0)** |
| Build | pass |

(One test broke on the first pass from two sections sharing a tab name; the renames above fixed it and the suite is green.)

## How the founder inspects it (preview path)
1. Open the Lovable preview: `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app`
2. Sign in with your account.
3. Go to **/workspace → Products**, open any product → the redesigned Design-2 detail drawer.
4. Check on desktop and mobile: light theme, navy top bar, product-image header, the six compact cards, the four tabs, the evidence ring, and the Compare/Save pills.

*(This container's network blocks the lovable.app preview host and authenticated views need your login, so I could not screenshot it here; functional correctness is covered by the full green suite, and the visual acceptance is yours.)*

## Unresolved UI items (for your visual acceptance / possible next pass)
1. **Commercial-rights card = "Not verified"** always — the product-detail contract has no per-product commercial-rights field, so a real status would need that data wired into the drawer (a small backend/contract follow-up). Flagged rather than faked.
2. **Fidelity to the exact Design-2 mockup** was built from your written requirements (I can't see the pixel mockup); spacing/typography/exact shades may need your tweaks after viewing.
3. **Workspace overview page** (the dashboard the screenshot most resembles) was left as-is per the agreed "restyle the detail drawer in place" scope; say the word if you want the overview page restyled to match too.
4. **App-wide chrome:** the light background + navy nav apply across the authenticated app (shared shell). Confirm that's the intended scope, or ask to narrow it.

## Controls
0 paid calls; 0 credits on providers; **no production deploy**; **no subscriber release**; **no rights-flag change**; RLS / PAL / country isolation / source-rights gates preserved; **GOLD 11/22 unchanged**. Lovable commit `6ff369d` (6.8 Lovable credits). Build Evidence row **BE316**. **Await founder visual acceptance before any production deployment.**
