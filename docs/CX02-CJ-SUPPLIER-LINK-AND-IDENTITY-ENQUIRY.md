# CJ Dropshipping — CX.02 Supplier Link + Same-Product Confirmation (DRAFT — NOT SENT)

**Status:** Prepared under the CX.02 External Evidence Resolution directive (2026-11-24). **Do not send without explicit founder approval.**
**Channel:** send via the existing authorised CJ support thread if one is open (reply to the CJ representative), otherwise email **support@cjdropshipping.com**.
**Scope:** two things only — (A) the official customer-accessible product/variant URL + website sourceability, and (B) a *documented* same-product and same-variant confirmation against one specific independently-discovered US listing. Image-rights questions are deliberately **excluded** (out of scope for this request).

**Why this is needed (internal note — not part of the message):** CJ's authorised API (`product/query`) returns the full product and all 15 variants but **no product-page URL** (re-confirmed on live run exec 30726, 2026-11-24). We must not invent a URL. Separately, the exact-product identity engine requires an *authoritative* same-product link; the CJ item exposes only CJ-internal sequential barcodes (non-GS1) and the US discovery exposes only a platform-scoped Google product id — neither bridges the two. A documented CJ confirmation is the smallest external evidence that can establish the bridge.

---

## Message to CJ

**Subject:** Official product URL + website sourceability + same-product confirmation — PID 2610010255571606100

Hello,

We access CJ products through the authorised API. For the product below, `product/query` returns the full product and its 15 variants, but no customer-facing product-page link, so we have three short requests.

**Product in scope (CJ):**
- PID: `2610010255571606100`
- Product SKU: `CJJT3213323`
- Product name: "USB Star Projector Night Light With Interchangeable Film Discs (Moon / Galaxy / Saturn patterns), for Kids' Bedroom Decor"
- Selected variant: VID `2610010255571607000`, variant SKU `CJJT321332301AZ` ("HD-3 Glass Cover")

**A. Official URL and website sourceability**
1. Please provide the **official customer-accessible CJ product-page URL** for PID `2610010255571606100`.
2. If variant-level links exist, the **direct URL for variant VID `2610010255571607000`** (SKU `CJJT321332301AZ`).
3. Please confirm whether this API-listed item is **visible and sourceable through the CJ website** — a keyword search on the CJ site for the SKU/PID currently returns no result for us, and we want to confirm the item is live and orderable.

**B. Documented same-product / same-variant confirmation**
4. We are evaluating whether this CJ product is the **same product** as one specific independently-listed US product (details below). Please confirm, **with verifiable documentation** (a shared manufacturer/factory reference, a shared GTIN/UPC/EAN, or CJ's own cross-reference records) whether:
   - (i) PID `2610010255571606100` is the same product as the US listing below, and
   - (ii) variant SKU `CJJT321332301AZ` (VID `2610010255571607000`) corresponds to a specific variant of that US listing.

   A statement that the items merely *look similar* or share a category is **not sufficient** for our records — we need a documented product-and-variant identification.

**US product for comparison:**
- Title: "Star Projector Night Light 1-Pack 360 Sky Projector with **25 Slide Discs** for Bedroom Living Room Decor, Size: 6.3 x 5.12 x 1.57 in"
- Retailer: **Walmart (US marketplace seller)**; observed price ≈ **US$14.99**
- (Google Shopping product reference `17536943141369248154`.)

For your reference, from the API we already hold this CJ item's 15 variants with their SKUs/VIDs and per-variant barcodes (e.g. variant `CJJT321332301AZ` / VID `2610010255571607000` / barcode `1600016885203`), a price range of US$6.08–US$10.76, and CN→US shipping.

Thank you,
Strateloq Technologies

---

## Internal handling (not part of the message)
- **Do not send** until the founder approves. Prefer the existing authorised CJ thread; otherwise support@cjdropshipping.com.
- **On a URL reply:** verify the returned link resolves to the correct product/variant **before** recording it, then record it only through `fn_record_supplier_product_url` (service-role; validates an https cjdropshipping.com product-level URL; provenance `FOUNDER_VERIFIED_SUPPLIER_PORTAL`). Never construct or assume a URL.
- **On a same-product reply:** a documented confirmation that specifically names PID `2610010255571606100` **and** variant `CJJT321332301AZ` as the same product/variant as the US listing becomes the `AUTHORITATIVE_SUPPLIER_REF` evidence; record it, then run the existing identity resolver. Generic similarity is recorded as **not** confirming identity.
- **If CJ cannot confirm this product:** use CJ's reply to pick a different existing **US generic** discovery (do not substitute the CJ-origin record `534d98bc`); candidate US generic analogs already screened GENERIC_OK include `ca945686` (this one), `61a8f517`, `bf40764c`, `84af56b0`, `a37f20e0`, `0863986d`.

## Evidence package (for audit)
- **Independent US discovery (proposed anchor):** `commerce_products` id `ca945686-18ca-40a9-94a8-2eafcb3bf5a7`; market **US**; source `dataforseo_merchant` / google_shopping; seller Walmart (US); price US$14.99; native identity = Google product id `17536943141369248154` (platform-scoped, **not** a manufacturer GTIN); brand screen **GENERIC_OK**; **no stored listing URL** (DataForSEO listing URL was not retained at ingestion — recovering it would require a new paid DataForSEO query, not performed).
- **CJ candidate (live-verified, exec 30726):** PID `2610010255571606100` / SKU `CJJT3213323`; 15 variants; selected VID `2610010255571607000` / SKU `CJJT321332301AZ` ("HD-3 Glass Cover") / barcode `1600016885203` (CJ-internal, non-GS1); price range US$6.08–$10.76; stock 6246 (CN warehouse; no US-warehouse stock); US freight CN→US US$6.11–$30.92 (3–13 days typical); currency USD; category Home Improvement > Indoor Lighting > Night Lights; HS code 8513109000.
- **Identity status:** no shared authoritative identifier on either side → `CANDIDATE_REQUIRES_VERIFICATION`. CJ's documented confirmation (item 4) is the pending external evidence.
- **Correction:** the product previously referenced as "the US star projector" (`9128d818`) is recorded in the database as market **IE** with seller **Amazon.ie** — it is an **Irish** discovery, not a US one. It is retained as a non-US research candidate and is **not** used as the US anchor. No US evidence was fabricated to retain it.
