# GPD.01 Rights-Clearance Preparation — final counsel questions, provider enquiry & founder decisions

**Prepared:** 2026-11-24 · **Status: PREPARATION ONLY.** No legal clearance is granted or implied; no correspondence sent; no credits spent; no rights/release flag changed; GOLD **11/22**; revised GPD.16/GPD.19/GPD.22 remain founder-accepted; GPD.17 retired. **The build/software team cannot and does not issue legal clearance** — a qualified Irish/EU IP & technology solicitor must review (Section 5).

## 0. Outstanding input — DataForSEO public legal FAQ (NOT yet read)
The founder asked me to fetch `https://dataforseo.com/help-center/quick-answers-to-frequently-asked-legal-questions` directly. Two things happened:
- **Network allowlist:** `dataforseo.com` (+ `www.`) was **added to this environment's allowlist** on founder approval (2026-11-24) — so the host is now permitted at the network layer.
- **Permission mode:** the outbound fetch itself was then **blocked by this session's Claude Code permission-mode classifier** ("Unauthorized Access") — both a web-fetch agent and a `curl` attempt were refused. This is a *separate* gate from the network allowlist, and I did not attempt to bypass it.

**To read the FAQ, one of:** (a) add a permission rule allowing the fetch / run a less-restricted permission mode and ask again; (b) paste the FAQ text; or (c) fetch it in a session that permits outbound web requests. Until then, the counsel questions below rest on the **captured 12 June 2026 Terms of Service** (§7.1/§7.2/§8.1) and the **recorded provider correspondence**; they must be re-checked against the FAQ (expected to confirm, not contradict) before counsel sign-off.

## 1. Comparison basis actually held (for counsel)
- **Captured ToS (12 June 2026):** §7.1 — SERP data "shall not be used to compete with or adversely affect the business interests of the search engine providers"; §7.2 — customer indemnifies DataForSEO for §7.1 violations "including any use of SERP data that violates the terms of service or legal rights of the search engine providers"; §8.1 — certain services are **resold**. (`docs/legal/captures/DATAFORSEO-TERMS-OF-SERVICE-CAPTURE-2026-11-20.md`.)
- **Provider reply (Gmail `1a1fb5da11e1432d`, 2026-11-20):** provider-level storage / resale-to-clients / no-attribution confirmed → `analyse_cleared=TRUE`. **Provider permission ≠ Google upstream permission.**
- **5 Nov 2026 FAQ:** pending (Section 0).

---

## 2. FINAL counsel questions — two separate legs (for a qualified Irish/EU solicitor)

**Shared framing:** Strateloq Technologies operates an authenticated, paid B2B SaaS product-research platform. All Google-origin data is obtained **via DataForSEO**; Strateloq holds no Google account, makes no direct Google API call, and has never assented to a Google term. DataForSEO has confirmed provider-level rights to store, derive from, and resell derived intelligence to Strateloq's clients without attribution. The two legs below concern **different** Google data categories with **different** upstream profiles; a clearance for one does **not** clear the other.

### LEG 1 — Google Ads-derived keyword / search-volume analytics
*Proposed display to authenticated paying customers:* attributed, country-specific **search-volume estimates and growth/trend** for a researched product or keyword — numeric demand analytics labelled "search demand," attributed to DataForSEO. No raw dataset display or resale; no third-party listings, images or links.

> **Questions for counsel:**
> 1. Does displaying these Google Ads-derived search-volume/growth figures to paying SaaS customers extract or re-utilise a *substantial part* of any Google database protected by the UK/EU **sui generis** database right (Directive 96/9/EC Art. 7, including the Art. 7(5) prohibition on repeated/systematic extraction of insubstantial parts at SaaS scale; retained in UK via the Copyright and Rights in Databases Regulations 1997) — bearing in mind these are metrics **Google itself generates/estimates**, so that under *British Horseracing Board v William Hill* (C-203/02) they are arguably **"created" rather than "obtained"** data, attracting weaker or no sui-generis protection?
> 2. Does such display breach DataForSEO ToS **§7.1** (data not to be used to compete with or adversely affect the search-engine provider), or expose Strateloq under the **§7.2** indemnity, or breach any Google term capable of binding Strateloq despite the absence of any direct relationship?
> 3. Does the **attributed, aggregated, analytic (non-raw, non-redistributive)** nature of the presentation reduce any residual risk to an acceptable level for ongoing SaaS-scale operation?
> 4. Given ToS **§8.1** (resold services), can DataForSEO's permission convey a downstream display right to Strateloq, or is an independent upstream assessment required?

### LEG 2 — Google Shopping / Merchant-derived aggregate competitor intelligence
*Proposed display to authenticated paying customers:* **aggregate seller counts**, **observed local price ranges** (min–max, single currency), and **derived competition/saturation classifications** for a researched product in a given country. **Withheld on every customer surface:** verbatim per-seller identities, individual offers, merchant/product links, and images. No raw-data resale.

> **Questions for counsel:**
> 1. Does displaying these Google Shopping-derived **aggregate** values extract or re-utilise a *substantial part* of Google's Shopping compilation under Directive 96/9/EC Art. 7 / Art. 7(5) (UK CRDR 1997) — bearing in mind Shopping is a **compilation of third-party merchant listings that Google obtains, verifies and presents** (so, unlike Leg 1, the *BHB* "obtaining" limb is engaged and the sui-generis right is more plausibly available)?
> 2. Does the **aggregation** (counts + ranges + classifications, with the verbatim seller list, offers, links and images withheld) materially reduce both the quantum extracted and the "reproduction of the compiled list" character, such that it is **not** a substantial-part extraction and does **not** offend Art. 7(5) at SaaS scale?
> 3. Does such display breach DataForSEO ToS **§7.1**, or expose Strateloq under **§7.2**, or breach any Google Shopping/Merchant term capable of binding Strateloq despite no direct relationship (Strateloq is not a merchant and makes no Merchant Center or Content API use)?
> 4. Given ToS **§8.1** (resold services), can DataForSEO convey a downstream display right for Shopping-derived data, or is an independent upstream assessment required — and is a controlled five-product GB pilot an appropriate first step?

*(Full supporting context — the four distinctions, rights register, per-field display inventory, EU/UK database-right analysis and CJEU authority — is assembled in `docs/GPD01-LEGAL-REVIEW-PACKAGE.md` Parts 2–6; send that package with these two questions.)*

---

## 3. FINAL Kalodata provider enquiry (for founder approval to send — NOT sent)
**To:** Kalodata (Andrew Lin / provider contact of record) · **Subject:** Confirmation of fields, countries, entitlement and derived-display rights for product-matched social-attention metrics

> We operate an authenticated, paid B2B product-research SaaS and hold your 2026-11-11 permission to show derived Kalodata intelligence to our paying customers with attribution. Before we ingest, please confirm, for our **current subscription**:
> 1. **Fields & operations** — which API operations return **product-matched, country-specific** creator counts, video counts, and growth metrics (view growth / share growth / creator growth), and the exact field names.
> 2. **Country coverage** — for which supported countries those fields are actually populated (we operate across GB, DE, IE, IT, US and other markets).
> 3. **Entitlement** — whether those specific fields are included in our current subscription tier or require an upgrade, and the associated cost.
> 4. **Derived-display rights** — confirmation that displaying them to authenticated paying customers as a **derived, aggregate "social attention" signal** (labelled *attention, not verified demand*; no raw export) is within the permission already granted.
>
> We will not download, cache or rehost any video or creator media; only a derived, attributed aggregate signal would be shown.

*Context for the founder:* our `kalodata_video_research` store is currently **empty (0 rows)** and these metrics are **not** stored anywhere in our database — so this enquiry (plus a separately-approved credit budget for the ingest) is the prerequisite for any GPD.07 social-attention display. No paid call is made by preparing this.

---

## 4. FOUNDER DECISION — GPD.09 (Meta advertiser intelligence): licence vs deferral
GPD.09 is an **optional** gate. We hold **440 stored Meta Ad Library observations (11 products)** but `META_AD_LIBRARY.analyse_cleared=FALSE` — we are not cleared even to analyse them, so no lawful derived display exists today. The existing rights gate is **preserved** (observations remain withheld; nothing enabled).

| | **Option A — pursue Meta licence** | **Option B — defer optional GPD.09 from launch (recommended)** |
|---|---|---|
| Action | Send the smallest written display-licence request (fields below) | Formally remove optional GPD.09 from the 18 Dec launch scope; keep observations withheld |
| Unblocks | Derived advertiser-presence for up to 11 products (if granted) | Nothing new — but removes a non-essential blocker |
| Risk / cost | Meta commercial-data licences are slow, restrictive and may not grant SaaS display; timeline and cost unknown; unlikely before 18 Dec | None to launch; advertiser intelligence simply not offered at launch |
| Launch impact | Does **not** gate launch either way (optional) | Clean: launch proceeds without it |

**Requested fields if Option A (no creatives, no advertiser identities):** derived **advertiser count**, **observed ad-activity presence**, and **observation date windows**, for markets **GB, DE, IE, IT, US** (and others only on founder instruction). Draft licence text: `docs/GPD07-09-PROVIDER-RIGHTS-REQUESTS-DRAFT.md` Draft 1.

> **Decision required (tick one):** ☐ **Defer** optional GPD.09 from the 18 Dec launch (recommended). ☐ **Authorise sending** the Meta licence request now. *(Not auto-deferred; awaiting your explicit choice.)*

---

## 5. Required external dependency — qualified Irish/EU IP & technology solicitor
Clearing Leg 1 and/or Leg 2 is a **legal** decision that only a qualified lawyer can make. The build/software team **cannot** and **does not** issue legal clearance, set `display_derived_cleared=TRUE`, or self-authorise release.

- **Who:** an **Irish/EU-qualified technology & intellectual-property solicitor** with working knowledge of the **EU/UK sui generis database right** (Directive 96/9/EC; UK Copyright and Rights in Databases Regulations 1997), the relevant CJEU authority (*British Horseracing Board v William Hill* C-203/02; *Innoweb v Wegener* C-202/12), **SaaS data-licensing**, and third-party-provider ToS/indemnity interpretation (ideally with data-protection adjacency).
- **What to send:** `docs/GPD01-LEGAL-REVIEW-PACKAGE.md` (full context) + the captured ToS + the two leg questions in Section 2 of this document.
- **Where it sits:** this solicitor engagement is the **required external dependency on the critical path** to customer display for GPD.01/06/08/10/11. Provider permission (DataForSEO) is necessary but **not** sufficient.

---

## 6. Founder authorisations required (summary checklist)
1. **Enable the FAQ fetch** — add a permission rule / use a session that allows the outbound request, or paste the 5 Nov FAQ text, so it can be reconciled against Section 1 before counsel sign-off.
2. **Engage** a qualified Irish/EU IP & technology solicitor (Section 5) and send the Leg 1 + Leg 2 questions (Section 2) with the legal package.
3. **GPD.07 social** — approve a Kalodata-credit budget **and** authorise sending the Kalodata enquiry (Section 3), or defer the social leg.
4. **GPD.09** — tick Defer or Authorise-send (Section 4).
5. On a **positive** counsel opinion (per leg): the **founder** records the clearance and flips the relevant `display_derived_cleared` flag — a founder action, reversible, **never** performed by the build session.

**Controls:** $0; 0 provider/API calls; 0 orders; no n8n; no publish; no code/DB change; no rights/release/budget flag flipped; no legal-clearance assertion. Source-rights flags and customer-release gates unchanged. GOLD **11/22**; GPD.16/19/22 (revised) founder-accepted; GPD.17 retired.
