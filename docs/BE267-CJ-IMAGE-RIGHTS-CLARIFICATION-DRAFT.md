# CJ Dropshipping — Image-Rights Clarification (DRAFT — NOT SENT)

**Status:** DRAFT prepared under BE267 §11. **Do not send without explicit founder authorisation.**
**Date prepared:** 2026-11-23
**Prepared for:** Strateloq Technologies founder review

**Context (internal — not part of the message):** CJ's written reply of 22 November 2026 already confirms permission to display supplier product **data, SKUs, variants, stock and product-page links** to authenticated paying SaaS customers — these are **not** being re-asked here. CJ separately stated that supplier **images** are not automatically licensed for third-party paid SaaS display and that individual copyright/supplier authorisation may be required. Strateloq's stored CJ records contain **no machine-readable per-image or per-supplier image authorisation** (only a blanket `SUPPLIER_PROVIDED_REFERENCE_ONLY` marker and provenance-level `rights_state`), so images currently classify as RIGHTS_UNVERIFIED and are withheld from customer display. This enquiry seeks only a documented way to recognise genuinely authorised images.

---

**To:** CJ Dropshipping account / partner support
**Subject:** Image-display authorisation for authenticated SaaS research (generic products)

Hello,

Thank you for confirming display permission for supplier product data, SKUs, variants, stock and product-page links for our authenticated paying customers — we are relying on that and are **not** re-asking it. We have a narrow follow-up specifically about product **images**, which you noted may need individual authorisation:

1. **Supplier image authorisation** — Can individual CJ suppliers authorise their generic-product images to be displayed inside our authenticated, paid research workspace?

2. **Scope of authorisation** — Can a supplier-level authorisation cover an entire catalogue or a defined set of products, or must it be given per image/product?

3. **Documented rights signal** — Does CJ provide a documented rights flag, permission record, or supplier declaration (ideally machine-readable via the API) that tells us which images are authorised for this display?

4. **Verification & retention** — How can Strateloq verify such an authorisation and retain the evidence (e.g. a reference, document, or API field) for audit?

5. **Temporary processing / caching** — May authorised images be temporarily processed or cached by our platform to serve them to authenticated customers?

6. **Image-analysis rights** — Do image-based analysis or similarity-matching uses require a separate approval, distinct from display?

7. **Revocation** — How is a withdrawal of image permission communicated to us, so we can stop displaying affected images promptly?

We will only display images we can document as authorised; everything else stays withheld. No other permissions are requested.

Thank you,
Strateloq Technologies

---

**Internal note:** A documented per-image or per-supplier authorisation (items 1–4) would be recorded in `commerce_supplier_image_rights` as `DISPLAY_AUTHORISED` with the stated scope and evidence, and the classifier (`fn_cj_image_display_classification`) would then admit exactly those images to the customer display path — analysis/cache rights (items 5–6) would be recorded separately and never implied by display permission. Revocation (item 7) sets `revoked_at` and immediately returns affected images to RIGHTS_UNVERIFIED.
