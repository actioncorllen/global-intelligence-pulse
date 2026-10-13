# PULSE-ECOM-PRODUCT-MEDIA-TENANT-ISOLATION-001

**Launch-critical tenant-isolation security fix for the product-media service (`mig_297`).**

## Vulnerability (introduced in `mig_296`)
`fn_product_media_state(p_tenant uuid, p_product uuid, p_market text)` is `SECURITY DEFINER`,
granted to `anon`/`authenticated`/`PUBLIC`, and authorized access **solely on the caller-supplied
`p_tenant`**. Worse, its `product_image_assets` and `media_assets` reads were keyed on `product_id`
alone (no tenant filter) and its `commerce_products` read on `id` alone. Consequences:

- An **unauthenticated** caller (or any caller) could pass any `product_id` and receive that product's
  reference image URL, provider id, source entity id, provenance, observed-at, and existence.
- A caller could **forge `p_tenant`** to another tenant and the supplier-resolution branch would read
  that tenant's row.
- No `auth.uid()` was ever consulted — identity was entirely client-asserted.

## Fix (`mig_297`) — identity is server-owned
- Authorization derives from **`auth.uid()` only** (resolved from `request.jwt.claims->>'sub'` in the
  server JWT context). `p_tenant` is retained in the signature for backward compatibility (the deployed
  Lovable frontend passes it) but is **ignored for authorization** — recorded as the invariant
  `caller_tenant_arg_ignored_for_authorization`.
- **Fail closed** when `auth.uid()` is NULL (unauthenticated) or when the product is not owned by the
  authenticated tenant (`commerce_products WHERE id=p_product AND user_id=auth.uid()`). Both return the
  **same** `v_denied` contract — `status=unauthorized`, `image_state=IMAGE_UNAVAILABLE`,
  `video_state=VIDEO_UNAVAILABLE`, `supplier_media_state=SUPPLIER_MEDIA_PENDING`,
  `card_media_state=MEDIA_INCOMPLETE`, `primary_image=null`, `gallery_count=0`, `authority=REFERENCE_ONLY` —
  so **nothing is disclosed**: no image URL, no media metadata, no provider id, no provenance, and
  crucially no `product_id`/`market` echo, so product/tenant existence cannot be probed.
- **Every read** (`product_image_assets`, `media_assets`, `commerce_products`,
  `commerce_concrete_supplier_resolution`) is scoped to `auth.uid()`; the supplier branch no longer
  trusts `p_tenant`. **Market isolation preserved** (the optional `p_market` filter is unchanged, applied
  on top of ownership).

## Frontend contract — unchanged (no Lovable change)
The success-path response field shape is identical to `mig_296`: `status`, `product_id`, `market`,
`image_state`, `primary_image.url` (+ provider/source_entity_id/observed_at/rights_state/authority),
`gallery_count`, `video_state`, `supplier_media_state`, `card_media_state`, `authority`, `contract`.
The denied path returns the same keys an empty product would, so the card renders MEDIA_INCOMPLETE with
no fabricated image rather than erroring. An authenticated owner's request is unaffected.

## Product Asset Lock — untouched (authorization-only change)
REFERENCE_ONLY semantics, the structural separation from the Stage-4 authoritative
`supplier_product_assets` table, and every commercial gate (Create Free Store / Create Ad / Publish /
Generate Creative) are byte-for-byte unchanged. Reference media still never unlocks merchant actions.

## Least privilege
`fn_product_media_state` keeps `anon`/`authenticated` EXECUTE — it fails closed in-function, so an
unauthenticated call yields the documented no-disclosure contract, not a leak, and the live frontend
contract is preserved. The two diagnostic selftests (`fn_product_media_auth_selftest`,
`fn_discovery_media_integrity_selftest`) write fixtures and manipulate `request.jwt.claims` as definer
and have no frontend contract, so EXECUTE is **revoked** from `PUBLIC`/`anon`/`authenticated` and
restricted to `service_role`.

## Verification
- **`fn_product_media_auth_selftest()` → 5/5** (durable, `service_role`-only). Simulates callers via
  `request.jwt.claims`: `OWNER_allowed` (Tenant A, real owned product → ok), `CROSS_TENANT_denied`
  (Tenant B → unauthorized, no disclosure), `FORGED_ID_denied` (uid=Tenant B, `p_tenant` forged to
  Tenant A → unauthorized), `UNAUTHENTICATED_denied` (no `sub` → unauthorized), `COUNTRY_ISOLATION`
  (owner, `JP` market → ok, market JP).
- **Real-path image proof** (temporary REFERENCE_ONLY image attached to the real owned product Hit the
  Slab, then removed): owner read returned `IMAGE_AVAILABLE` / `MEDIA_COMPLETE` with the genuine URL,
  while cross-tenant, forged-`p_tenant`, and unauthenticated reads **all** returned `unauthorized` /
  `IMAGE_UNAVAILABLE` / null primary / `gallery_count=0` / no `product_id`. This is the decisive proof:
  the pre-fix function would have handed the URL to all three (product-id-only read, client-asserted
  tenant). Fixture removed afterward; 0 residual rows on the real product.
- **Regression**: `fn_discovery_media_integrity_selftest()` → 7/7 (checks E/F updated to exercise the
  hardened function through the authenticated owner path; the pre-fix E/F were written against the
  insecure contract). `fn_stage2g_boundary_integrity_selftest()` → 10/10 (Stage-1 qualification,
  Krippen history, Ankerkraut branded-exclusion, Hit the Slab, country isolation, tenant isolation all
  unchanged). FastMoss/Kalodata ingest cover-persistence unchanged (check G green).

## Boundaries honored
No CJ call. No Stage 3. No provider calls. No frontend redesign. No fabricated media. No change to
qualification, matching, or evidence rules. No secrets touched. Authorization-only change.
