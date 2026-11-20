# STRATELOQ — Active-Source Rights Matrix (BE231, 2026-11-20)

Authoritative inputs: `public.catalogue_source_rights` (the system rights register — every
clearance dimension is FALSE for every provider as of this review), the provider
correspondence on file, and the system's enforced posture. Provider public terms pages
(dataforseo.com, kalodata.com, cjdropshipping.com) are **not retrievable from the
engineering session** (network-restricted): no external licence text was read, and none is
interpreted here. `display_cleared`-style flags on individual assets are system
rights-model markers, **never** legal authorisation.

Legend: **P** = Permitted (written evidence on file) · **X** = Prohibited (by evidence or
enforced posture pending approval) · **U** = Unconfirmed (no document either way) ·
**W** = Requires additional written approval before use.

## DataForSEO (incl. Merchant / Google Shopping)

| Permission | Status | Basis |
|---|---|---|
| Derived research findings → paying SaaS customers | **W** | No licence text on file; register display_derived=false; internal posture research-only (founder 19-Nov alignment) |
| Country-local observed product prices (display) | **W** | Same; prices are Shopping-SERP-derived — upstream conditions unknown |
| Observed seller/retailer & competition findings (display) | **W** | Same; system already refuses national-seller claims (observed floors only) |
| Source attribution + observation dates | **U** | Shown by our practice; whether required/permitted/forbidden by terms unconfirmed |
| Google Shopping / Merchant upstream redistribution | **W** | Register flags explicitly; no written Google-conditions analysis on file |
| Merchant imagery (storage/display) | **X** (posture) / **W** | Zero Merchant images stored or displayed (verified BE229); stays prohibited pending written approval |
| Retention / caching / derived-data reuse | **U** | Raw task results stored TENANT_PRIVATE; terms limits unknown |

**GB five-product text-only pilot: NOT AUTHORISED by documents on file.** The exact
missing document: DataForSEO written confirmation that derived listing TEXT data (titles,
observed prices, merchant names) from Google Shopping SERPs may be displayed to paying
research customers, plus the applicable retention terms and any upstream Google
conditions. `customer_source_release.released` stays FALSE (left untouched).

## Kalodata

| Permission | Status | Basis |
|---|---|---|
| Derived analytics (est. revenue/sales/growth, labelled) → customers | **U→W** | LIVE under the founder's direct build authorisation; register display_derived=false; no provider statement on file — needs provider written confirmation or a documented founder risk-acceptance recorded in the register |
| Customer-facing reference images (master_image_url) | **U→W** | Same as above; need_image=1 is a product feature, not a licence; images hotlinked DIRECT_URL (no byte caching) |
| Attribution + dates | **U** | Shown by practice; requirement status unconfirmed |
| Caching / storage of media bytes | **X** (posture) | Not done; keep prohibited pending terms |
| Commercial reuse of media (ads/stores) | **X** | commercial_cleared=false enforced system-wide (PAL) |
| Correspondence on file | — | Andrew Lin, 2026-11-20: API authentication guidance ONLY; contains no rights statements |

**Flagged inconsistency (founder decision):** live customer display vs register FALSE.
Resolve by (a) provider written confirmation (draft email below), or (b) founder
documented risk-acceptance written into `catalogue_source_rights`.

## CJ Dropshipping

| Permission | Status | Basis |
|---|---|---|
| Customer-facing supplier research (identity, SKU, cost, stock, freight) | **W** | Register false; no written SaaS display terms on file |
| Product references / outbound product links | **U** | Low-risk by nature; unconfirmed in writing |
| Supplier images (display) | **U→W** | System practice treats SUPPLIER_PROVIDED media as gallery-eligible while the register holds display=false — flagged inconsistency, same resolution options as Kalodata |
| Commercial reuse of supplier media | **X** | Restricted; unverified |
| Retention / caching | **U** | 1,317 records cached since Aug–Oct; terms limits unknown |

## Register state after BE231
No clearance flag was changed (all remain FALSE). The four active-source
`rights_evidence` entries now carry the BE231 reconciliation verbatim, including both
flagged inconsistencies and the pilot release decision.

## Draft permission-request emails (for founder review — NOT sent)

### 1 → DataForSEO support/legal
Subject: Permission confirmation — displaying derived research findings to our SaaS customers

We operate a market-research SaaS (Strateloq) and use the DataForSEO API (incl. Merchant/
Google Shopping endpoints) under our account. Before enabling any customer-facing use we
want written confirmation of what our licence permits: (1) displaying derived research
findings (opportunity assessments, demand estimates, deduplicated listing statistics) to
our paying customers; (2) displaying observed country-local product prices, titles and
merchant names from Shopping SERP results as clearly-attributed research data; (3)
displaying observed seller/competition findings; (4) your attribution requirements; (5)
any upstream Google Shopping redistribution restrictions we must honour; (6) permitted
retention/caching of task results and reuse of derived data. We do not display or store
Shopping images and do not resell raw API data. Could you confirm each point, or send the
applicable licence sections?

### 2 → Kalodata (ref: Andrew Lin correspondence, 2026-11-20)
Subject: Follow-up — display permissions for analytics and product reference images

Thank you for the API authentication guidance on 20 November. Separately from the
technical integration we want written confirmation of display rights under our plan: (1)
showing Kalodata-derived analytics (estimated revenue/sales/growth, clearly labelled as
estimates with attribution) to paying customers of our research SaaS; (2) displaying the
master_image_url product reference images (returned via need_image=1) to those customers
as research reference covers — hotlinked, not cached; (3) your attribution requirements;
(4) any caching/retention limits; (5) confirmation that commercial reuse of media (ads,
storefronts) is excluded — which we already enforce. Could you confirm each point, or
send the applicable terms?

### 3 → CJ Dropshipping partner/API team
Subject: Permission confirmation — supplier research display in our sourcing SaaS

We use the CJ developer API for sourcing research inside our SaaS (Strateloq). Before any
customer-facing use we want written confirmation of: (1) displaying supplier/product data
(product names, SKUs/variants, costs, stock state, shipping options) to our paying
customers as sourcing research; (2) linking to CJ product pages; (3) displaying
supplier-provided product images in that research context; (4) permitted
retention/caching of catalogue data; (5) exclusion of commercial media reuse unless
separately agreed. Could you confirm each point, or send the applicable API terms?

---

## BE232 amendment (2026-11-20): founder-reported Kalodata permissions correspondence

**Correction of scope.** BE231's statement that Kalodata correspondence contained only
authentication guidance was true of the correspondence **on file in the system** (repo +
register + tracker), but the founder reports an earlier provider permissions email from
Andrew Lin covering: derived SaaS analytics, raw-data resale restrictions, Product Rank
images (need_image), the Product Images API, attribution, caching and hosting. BE231's
claim is therefore re-scoped: *the system record was incomplete*, and whether any Kalodata
clearance is a missing register entry (right exists, unrecorded) or a missing contractual
right is **INDETERMINATE** until the original thread is read.

**Recovery attempts (all from this session, 2026-11-20):**
- Gmail (the near-certain location — the FastMoss enquiry precedent is recorded as sent
  from the user's Gmail): **connector authentication expired**; a session cannot start
  OAuth. Unblock: re-authorize the Gmail connector in claude.ai → Settings → Connectors,
  after which the full thread (all messages + dates) will be read and reconciled.
- Repository docs (incl. the Kalodata master doc), Lovable project docs, all tracker tabs
  (incl. hidden "VERIFIED — Do Not Repeat" and "Stage 1 — Provider Preflight"), the
  `catalogue_source_rights` register, Google Drive (single Kalodata mention = the tracker
  itself), Notion: **no copy of the permissions email**.

**Consequences, pending the thread:** no clearance field was changed (the email text, not
its description, is the evidence rule 4 requires); the live Kalodata customer display
remains flagged as provider-unconfirmed in the register; the DataForSEO five-product
release stays disabled on its own upstream/display verification; CJ permissions remain
separate and unresolved; the three draft emails stand untrimmed because nothing has yet
been conclusively answered by correspondence readable in-session.

**Prepared reconciliation (to run immediately after Gmail re-auth):** for each of the six
permission dimensions, quote the exact sentence + message date into
`catalogue_source_rights.rights_evidence`, set the specific clearance flag only where the
quoted text supports that exact permission, re-check for referenced separate terms that
impose additional restrictions, restrict any current display use the correspondence does
not support, trim answered questions from the Kalodata draft email, and update GPD.01/02
with precisely the justified changes.

---

## BE233 (2026-11-20): Kalodata permissions RESOLVED — corrected matrix

**Source document:** Andrew Lin <andrew.lin@kalodata.com>, **2026-11-11**,
"Re: Commercial API Licensing and Product Image Usage — Strateloq Technologies".
Recovered by the founder via their connected Gmail; Gmail message link:
https://mail.google.com/mail/u/?authuser=actioncorllen%40gmail.com#all/1a1c976c3cfc53e3
Provenance in-session: founder-supplied transcription (the Gmail connector remains
unauthenticated here, so the message was not independently re-read; same evidentiary
class as the register's existing founder-supplied eBay entry). BE231/BE232's conclusion
is corrected: the Kalodata correspondence on file was incomplete — **the gap was a
missing register entry, not a missing contractual right.**

### Corrected Kalodata matrix

| Permission | Status | Basis (2026-11-11 email) |
|---|---|---|
| Derived/analysed intelligence → paying SaaS customers (multi-country/account) | **P** | Point 1; also point 6 (no separate commercial licence for described use) |
| Raw-data resale | **X (documented prohibition)** | Point 2 |
| Product Rank main images in authenticated SaaS research | **P — conditions: authenticated display + Kalodata attribution** | Point 3 |
| Caching / proxying / hosting of customer-facing research images | **P** | Point 4 (current practice hotlinks DIRECT_URL — within scope; Product Images API links expire after 5 min, point 5, so caching permission is operationally relevant) |
| Attribution | **Required condition** | Point 3; rendered today in evidence meta / source labels — must be maintained |
| Creative / storefront / advertising reuse of media | **X** | Not covered by points 1–6; founder instruction; PAL + commercial_cleared=false + founder gates unchanged |
| Pricing | — | Per-call; need_image adds no separate credits (point 7) |

### Reconciliation of current customer display
The live workspace use — labelled derived analytics + Product Rank reference images shown
to the authenticated founding member with source attribution, hotlinked, never
commercially reused — is **within the documented scope**. The BE231-flagged Kalodata
register-vs-practice inconsistency is resolved as a register omission. Register updated
(four clearances TRUE with scopes; raw resale recorded as documented prohibition;
creative/commercial reuse remains FALSE).

### Residual caveats (why "complete legal clearance" is still not claimed)
Kalodata's standard terms-of-service text is still not on file, and upstream TikTok-Shop
data conditions are not addressed in the email. These are recorded caveats, not blockers
to the described research-display use the provider confirmed in writing.

### Draft-email changes
The **Kalodata draft is withdrawn** — every question it asked (derived display, reference
images, attribution, caching, commercial exclusion) is conclusively answered by the
2026-11-11 email; no repeat enquiry is needed. The **DataForSEO** and **CJ** drafts stand
unchanged and unresolved.

---

## BE234 (2026-11-20): DataForSEO terms captured and read in full; CJ blocked at human verification

**DataForSEO — complete public ToS now on file** (capture:
`docs/legal/captures/DATAFORSEO-TERMS-OF-SERVICE-CAPTURE-2026-11-20.md`; document stamp
"UPDATED: 12 JUNE, 2026"; fetched 2026-11-20 via server-side egress because the session's
own network cannot reach the host). Read in full, sections 1–8. Findings:
- **No express prohibition anywhere** on resale, redistribution, sublicensing, display to
  one's own customers, retention or caching; **no attribution requirement**.
- The **only** data-usage restriction is **§7.1**: SERP data "shall not be used to compete
  with or adversely affect the business interests of the search engine providers", with
  **§7.2** indemnifying DataForSEO and expressly putting upstream search-engine-ToS risk
  on the customer.
- §5.1 distinguishes API credits from database purchases (retention of purchased data is
  an anticipated use); §6.2 jurisdiction exclusions do not apply to Strateloq.

**Matrix consequence (flags unchanged — silence is not a grant):** every DataForSEO
display dimension moves from "no document either way" to **"ToS text on file: not
prohibited; conditioned on §7.1; upstream Google leg = customer's own legal judgment
(§7.2)."** The exact authorised release path for the gated GB five-product text pilot:
1. Founder sends the trimmed enquiry below (or records a documented founder/legal
   judgment that §7.1-compliant research display to paying customers is permitted use);
2. Founder/legal resolves the upstream Google Shopping leg (expressly our risk per §7.2);
3. Founder authorises production release → flip the five `customer_source_release` rows.
Until all three: rows stay FALSE (unchanged today).

### Trimmed DataForSEO draft (supersedes the BE231 six-point draft)
Subject: Confirmation of permitted use — displaying derived research to our SaaS customers

We reviewed your Terms of Service (updated 12 June 2026). Three confirmations, please:
(1) that displaying derived research findings built from Shopping/Merchant and SERP
results — product titles, observed local prices, merchant names, deduplicated
listing/competition statistics, always as attributed research, never raw-data resale —
to paying customers of our research SaaS is a permitted use consistent with §7.1;
(2) whether you have an attribution preference or requirement for such display;
(3) any Google Shopping-specific display guidance you provide customers in view of §7.2.

**CJ — terms unretrievable non-interactively:** both known terms paths return an
interactive "Human verification" challenge to server fetches. No text on file; the BE231
five-point draft stands; alternatively the founder can open the terms in a browser and
supply the text for capture (as with the Kalodata email).

**Kalodata — unchanged from BE233** (no new asks; the standard-terms caveat remains, now
with the recorded detail that kalodata.com/terms-of-service is a client-rendered app
shell whose text a static fetch cannot read).

---

## BE235 (2026-11-20): FINAL provider enquiry drafts — awaiting founder approval, NOT sent

These two drafts supersede all earlier versions in this document. The Kalodata enquiry
remains withdrawn (resolved by the 2026-11-11 provider email). All five
`customer_source_release` rows remain `released=false`.

### FINAL DRAFT 1 — DataForSEO
**Intended recipient:** support@dataforseo.com (DataForSEO's published support address;
the in-dashboard contact/ticket channel is an equally valid route — founder's choice).
**Reference:** your Terms of Service, updated 12 June 2026 (reviewed in full).

> **Subject: Written confirmation of permitted use — displaying derived research to our SaaS customers**
>
> Hello,
>
> Strateloq Technologies operates a paid product-research SaaS platform for e-commerce
> sellers. We use the DataForSEO API (including Merchant/Google Shopping and SERP
> endpoints) under our account, and we have reviewed your Terms of Service (updated
> 12 June 2026). Before enabling any customer-facing use we would like written
> confirmation of three points:
>
> 1. May Strateloq display appropriately attributed/labelled **derived research findings**
>    built from Shopping/Merchant and SERP results — including observed product titles,
>    merchant names and country-local observed prices, presented as research with
>    honest "observed/estimated" labelling — to **authenticated paying customers** of our
>    platform, without reselling or redistributing raw API datasets? We read this as
>    consistent with §7.1 (we do not compete with or adversely affect the search-engine
>    providers), and we would value your confirmation.
>
> 2. Does DataForSEO require any particular **attribution**, or impose any **retention or
>    caching restrictions**, for this display use?
>
> 3. Could you clarify how your licence applies to this use, and share any **known
>    upstream Google Shopping / Merchant or search-engine conditions** you advise
>    customers about (in view of §7.2)? We recognise that Google's own rights are not
>    DataForSEO's to grant and that upstream compliance remains our responsibility.
>
> We do not display or store Shopping images, and raw API data is never resold.
> Thank you — a short written confirmation of each point, or the applicable licence
> sections, would be ideal.
>
> Kind regards,
> Strateloq Technologies

### FINAL DRAFT 2 — CJ Dropshipping
**Intended recipient:** support@cjdropshipping.com (CJ's published support address; the
in-dashboard ticket system or the assigned agent channel may be the surer route —
founder's choice). CJ's public terms pages reject non-interactive review (human
verification), so this enquiry asks for the applicable terms as well.

> **Subject: Written confirmation of permitted use — supplier research display in our sourcing SaaS**
>
> Hello,
>
> Strateloq Technologies operates a paid product-research SaaS platform for e-commerce
> sellers and uses the CJ developer API under our account for sourcing research. Before
> any customer-facing use we would like written confirmation of five points:
>
> 1. May we display **supplier research data** (supplier identity and product data) to
>    authenticated paying customers of our platform as sourcing research?
> 2. May that display include **exact SKU, variant and stock information**?
> 3. May it include **country-specific shipping options and landed-cost estimates**
>    computed from CJ freight and cost data (always labelled as estimates)?
> 4. May we show **links to CJ product pages** and display **supplier-provided product
>    images** in that research context?
> 5. What **retention/caching limits, attribution requirements and commercial-use
>    restrictions** apply? To be explicit about scope: this is research display only —
>    we do **not** seek rights for advertising creative, storefront publication or any
>    other commercial reuse of supplier media, which our platform blocks separately.
>
> If there is an applicable API licence or terms document covering these points, we would
> appreciate a copy or link.
>
> Kind regards,
> Strateloq Technologies

### Outstanding rights questions after BE235 (complete list)
- **DataForSEO:** the three questions above + the upstream Google Shopping display
  judgment that §7.2 places on Strateloq (a founder/legal decision, not a provider grant).
- **CJ:** the five questions above (+ obtaining the terms text itself).
- **Kalodata:** none (2026-11-11 email controls; standard-ToS caveat recorded as
  unresolvable by static fetch — client-rendered page).


---

## BE236 (2026-11-20): finals verified against the approved scope — awaiting explicit send authorisation

**Verification result:** both final drafts contain ONLY the approved research-only
permission questions. Neither asks for advertising, storefront publishing, raw-data
resale or creative-media reuse anywhere (DataForSEO Q1 expressly disclaims raw-dataset
resale; CJ Q5 expressly states those uses are not sought and are blocked platform-side).
One refinement applied per the founder's item 3: DataForSEO Q3 now explicitly recognises
that Google's own rights are not DataForSEO's to grant and that upstream compliance
remains Strateloq's responsibility. CJ draft unchanged (already requests the applicable
terms document alongside the five research/sourcing permissions).

**Send authorisation status:** approved in substance; explicit SEND authorisation not yet
granted — the exact outgoing texts above (Draft 1 as refined, Draft 2 unchanged) are
presented to the founder for that final go. Send channels: the founder's own mail client,
or this session's Gmail connector once re-authorised (currently expired).

**Dispatch recording procedure (runs when each email is actually sent):** record in
`catalogue_source_rights.rights_evidence` and the live tracker — sent timestamp (UTC),
sender account, recipient address/channel, subject line, Gmail message id/link (or
ticket id), and a response-status field (AWAITING_REPLY → acknowledged → substantive
reply quoted verbatim with date), following the FastMoss-enquiry recording precedent.
Release rows and clearance flags change only on substantive written replies (or the
founder's documented judgments), never on dispatch.
