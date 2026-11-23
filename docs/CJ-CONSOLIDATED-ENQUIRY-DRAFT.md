# CJ Dropshipping — Consolidated Enquiry (DRAFT — NOT SENT)

**Status:** Single consolidated enquiry prepared on founder instruction. **Do not send without explicit founder authorisation.**
**Date prepared:** 2026-11-23
**Supersedes / merges:** `docs/BE266-CJ-SUPPLIER-ENQUIRY-DRAFT.md` (product identity + sourcing) and `docs/BE267-CJ-IMAGE-RIGHTS-CLARIFICATION-DRAFT.md` (image rights). Those remain on file for audit; this is the single message to send.

**Already answered by CJ (22 November 2026 reply) — NOT re-asked here:** permission to display supplier product **data, SKUs, variants, stock information and product-page links** to authenticated, paying SaaS customers. We are relying on that.

**Product in scope:** CJ PID `2610010255571606100`, reference SKU `CJJT3213323`, product "USB Star Projector Night Light With Interchangeable Film Discs…", 15 variants (CJ-native VIDs/SKUs on file). We are evaluating it for US generic dropshipping.

**Internal note (not part of the message):** From CJ's stored data we already hold the 15 variant SKUs/VIDs and per-variant prices ($6.08–$10.76), `AVAILABLE_PROBED`, shipping countries `[CN, CN_US]`. We do **not** hold a product-page URL, a GTIN/UPC/EAN, a manufacturer/model reference, per-variant US stock, or a US shipping quote. Everything below seeks only that genuinely-missing authoritative evidence. No image, name, category or similarity match is treated as exact identity.

---

**To:** CJ Dropshipping account / partner support
**Subject:** Authoritative product/variant evidence + image-display authorisation for PID 2610010255571606100

Hello,

Thank you for confirming display permission for supplier product data, SKUs, variants, stock and product-page links for our authenticated paying customers — we are relying on that and are **not** re-asking it. For the product above we have two short sets of questions.

**Part A — Authoritative product & variant evidence**

1. **Official product URL** — the canonical CJ product-page link for PID `2610010255571606100`.
2. **Per-variant links/confirmation** — a direct link or confirmation for each of the 15 variant SKU/VID references we hold (so each customer-selected variant maps to a current, orderable SKU).
3. **Manufacturer / factory identity** — any manufacturer name, factory model number or MPN you hold for this item (the authoritative identifier we are missing).
4. **Documented cross-references** — any records you maintain linking this product to the same item on other platforms (a shared identifier or source reference).
5. **Exact-equivalence confirmation** — whether CJ can confirm, with verifiable documentation, that PID `2610010255571606100` is the exact same product as a specific independently-listed US product we will provide for comparison (not an assumption from images or titles).
6. **Current US stock** — current availability for the main variants for US fulfilment.
7. **US shipping quotation** — whether per-variant shipping quotations to the United States are available (cost, carrier, estimated delivery).

**Part B — Product-image display authorisation**

8. **Supplier image authorisation** — can individual CJ suppliers authorise their generic-product images to be displayed in our authenticated, paid research workspace?
9. **Scope** — can a supplier-level authorisation cover a whole catalogue or a defined product set, or must it be per image/product?
10. **Documented rights signal** — does CJ provide a documented rights flag, permission record or supplier declaration (ideally machine-readable via the API) indicating which images are authorised?
11. **Verification & retention** — how can we verify and retain that authorisation for audit?
12. **Temporary processing / caching** — may authorised images be temporarily processed or cached to serve to authenticated customers?
13. **Image analysis** — do image-based analysis or similarity uses require a separate approval, distinct from display?
14. **Revocation** — how is a withdrawal of image permission communicated to us?

We will only display images and treat a product as an exact match once we can document the authorisation/identity above; everything else stays withheld or unverified. No other permissions are requested.

Thank you,
Strateloq Technologies

---

**Internal acceptance note:** Part A items 1–5 supply the authoritative US↔CJ bridge (SHARED_GTIN or AUTHORITATIVE_SUPPLIER_REF — no GTIN required if a manufacturer/model or documented cross-reference is given) that the BE246 engine needs to move the candidate beyond `CANDIDATE_REQUIRES_VERIFICATION`; item 1 supplies the direct link the Product Card requires (captured by the ingestion URL mapping when provided); items 6–7 feed the supplier-economics landed-cost calculation (UNKNOWN until received). Part B, if answered, is recorded in `commerce_supplier_image_rights` and admitted by the image-rights classifier; image/analysis/caching rights stay separate, and customer download is never offered.
