# Rights-Resolution Activation Status — GPD.01/06/07/08/09/10/11

**Prepared:** 2026-11-25 · **Status: ACTIVATION PREP — nothing sent, no paid calls, no flag flips, no publish.** GOLD **11/22**; GPD.16/19/22 (revised) founder-accepted; GPD.17 retired; RLS/PAL/tenant+country isolation/provider budgets/founding-member controls preserved. This records **new evidence and decisions**, not a restatement of BE305–BE308.

## A. New this pass (genuinely new evidence)
- **DataForSEO 5 Nov 2026 legal FAQ retrieved and captured** — via an **authorised n8n HTTP workflow** (zero-cost, read-only; this container's direct web access is blocked by the permission-mode classifier, so an authorised connector was used, as the founder directed). Verbatim §§1–5 saved to `docs/legal/captures/DATAFORSEO-LEGAL-FAQ-CAPTURE-2026-11-05.md`. It **confirms**: derived/transformed display is **not** the restricted activity (only **raw** resale/redistribution needs a separate agreement — §3); **no attribution/branding/transformation-threshold** requirement from DataForSEO (§4); the **client** bears Google-upstream compliance and the **§7.2 indemnity** (§5); client **retention is unrestricted** (§2).
- **eBay API License Agreement NOT retrieved** — the static URL `developer.ebay.com/api-docs/static/api-license-agreement.html` returned **404 (page moved)**. Its current URL is needed (or a founder paste) to cite §§3/4/8.4/9 exactly.

## B. Deliverable — practical rights-resolution status

**1. Public terms + prior grants that already cover the required uses**
- **DataForSEO:** analyse + derive + store + **commercial derived display to customers** — the FAQ (§3/§4) confirms our derived-analytics display is **not** the restricted raw-resale and carries **no attribution duty**; plus the 20 Nov written permission. Provider side is **cleared** for GPD.06/08/10/11 (display still gated on Google-upstream, below).
- **Kalodata:** derived commercial SaaS display with attribution (11 Nov) — covers GPD.07 **display**.
- **CJ:** supplier identity/product/SKU/variant/stock display + links (22 Nov) — covers GPD.16 (revised).

**2. Precise external decisions still outstanding**
- **Google-upstream (the only DataForSEO residual):** an Irish/EU IP-counsel opinion on **Leg 1** (Ads search-volume) and **Leg 2** (Shopping compilation), then a **founder** flag flip. FAQ §5 makes this unambiguously the client's to resolve.
- **Kalodata:** Product Detail **operation entitlement** + **country coverage** + a **founder credit budget**.
- **Meta:** commercial-SaaS display rights (Track A) **or** a licensed alternative (Track B).
- **eBay:** derived-aggregate-statistics permission (clause citation pending the current agreement URL).

**3. Enquiries actually SENT: NONE.** There is **no authenticated send channel** available — Gmail is de-authorised and there is no provider send connector. The exact finished messages are prepared (BE307 §2/§3, BE308 §4, and below). The n8n workflow **retrieves** public documents; it is **not** a send channel. No delivery is claimed or fabricated. **To send, the founder must re-authorise Gmail or name an authenticated channel.**

**4. Kalodata entitlement / field availability + capped pilot**
- **Finding:** our stored Kalodata data is **Product Rank** revenue (`live/video/showcase_revenue`, `ad_growth`), **not** Product **Detail** counts — `creator_number`/`video_number`/`live_number` are **absent** (0 rows). So a **fresh paid Product Detail ingest is genuinely required**; display is already permitted (11 Nov).
- **Capped pilot (for founder approval, not executed):** operation `/openapi/v1/tiktok/product/detail`; scope = resolved exact products that already carry a Kalodata product id (33 Kalodata products, predominantly US), **one period**, matched to our exact identities + selected country; **explicit hard cost cap to be set once the per-call price is confirmed** (the per-call price is the first thing the entitlement enquiry asks). **Sequence:** (i) send the free entitlement/price enquiry → (ii) founder sets a hard $ cap and approves the exact operation → (iii) run the capped pilot → (iv) test identity accuracy, country isolation, confidence, freshness, truthful "social attention, not demand" labels, permitted display; **no media download/rehost.** No chargeable call until amount **and** operation are separately approved.

**5. Meta — primary route, fallback, coverage (GPD.09 mandatory, NOT deferred)**
- **Track A (official Meta):** the key limitation (founder-confirmed and consistent with Ad Library policy): ads **not reaching the EU are generally absent** from the Ad Library API unless they are political/social-issue — so **GB (non-EU) and US ordinary commercial-ad coverage is limited**, while **DE/IE/IT (EU, DSA) is broader**; and standard Platform Terms do not grant commercial SaaS redistribution. **Primary request:** written confirmation of (a) per-country commercial-ad coverage for GB/DE/IE/IT/US and (b) a commercial SaaS display/retention licence for derived advertiser counts/activity/dates. *(Current Meta docs not fetched this pass — Meta is JS-heavy; the Track-A request should be finalised against a fresh fetch of the Ad Library API docs + Platform Terms.)*
- **Track B (licensed alternative — verify, do not pick on sight):** candidate **categories** to evaluate are commercial competitive-ad-intelligence APIs/OEMs. **I did not and cannot verify any vendor's actual API/rights/pricing this session (web blocked), so no vendor is recommended.** Each candidate must be verified against this checklist before any choice: programmatic API availability; **legal provenance** of the Meta-derived observations; **contractual permission to redistribute in a paid multi-tenant SaaS**; derived advertiser counts + observed activity; GB/DE/IE/IT/US coverage; product matching + permitted advertiser/page identity; freshness/windows/dedup/limits; storage/retention/attribution/revocation; pricing/minimum commitment. A written licence/quotation is requested where those rights aren't documented. **Public API access ≠ redistribution right.**
- **Recommendation:** **primary = Meta Track A** written request; **fallback = a checklist-verified licensed ad-intelligence provider**. **GPD.09 stays BLOCKED** until genuine, authorised advertiser evidence is available and accepted in production. No substitute by ad links or public TikTok.

**6. eBay status for the existing observations**
- The **1,992 observations remain NOT_AUTHORISED** for analysis/display. The narrow derived-statistics permission request is drafted (BE308 §4) citing §§3/4/8.4/9; the **agreement text could not be fetched** (static URL 404). Not a mandatory dependency for the separately-cleared Google-Shopping pilot (9 products). CJ/BigBuy are **not** a marketplace-seller substitute.

**7. DataForSEO counsel package + unresolved legal questions**
- **Complete and now FAQ-reinforced.** The two leg questions (BE307 §2) stand; the FAQ (`…FAQ-CAPTURE-2026-11-05.md`) is added to the package as provider documentation. **Unresolved legal questions:** the two Google-upstream legs (EU/UK sui-generis database right + §7.1/§7.2 for the specific aggregated display). Provide counsel with: the captured ToS, the captured FAQ, the provider reply, a sample output, and the current display architecture.

**8. Exact source-by-source sequence to clear the remaining GOLD gates**
1. **Counsel** (founder approves engagement + fee) → **Leg 1** clears GPD.06; **Leg 2** clears GPD.08/10/11 (9-product Google-Shopping) → founder flips the relevant `display_derived_cleared` flag(s).
2. **Kalodata** → founder budget + entitlement/price enquiry → capped Product Detail pilot → GPD.07 (test + label) → display.
3. **Meta (mandatory)** → Track A written request (+ Track B verification in parallel) → on authorised evidence, GPD.09 production acceptance.
4. **eBay** → obtain the current agreement URL → send the derived-statistics request → on grant, broadens GPD.08/10/11 beyond the 9 Shopping products.
*(Per the founder: a separately-cleared source is activated without waiting for all others — the Google-Shopping/search pilot can proceed on the counsel legs + founder flag flips independently of Meta/eBay.)*

## C. Founder actions required now
1. **Approve the Irish/EU IP-counsel engagement + fixed fee** (then I hand over the package).
2. **Approve a Kalodata credit budget + authorise the entitlement/price enquiry** → then the capped pilot with your hard $ cap.
3. **Direct Meta:** authorise the Track A written request and Track B vendor verification.
4. **Provide the current eBay API License Agreement URL** (or paste it) for exact clause citation.
5. **Re-authorise Gmail (or name an authenticated send channel)** so the prepared enquiries can actually be sent — **until then, none can be sent.**

**Controls:** $0; 0 provider/API calls; 0 orders; no n8n chargeable runs (the one n8n run was a free public-doc GET; workflow archived); no flips/publish; isolation/PAL/RLS/budgets/founding-member controls preserved. GOLD **11/22**. Recorded as Build Evidence **BE309**.
