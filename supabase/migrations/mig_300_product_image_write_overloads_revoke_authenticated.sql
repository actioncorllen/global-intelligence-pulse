-- ============================================================================
-- mig_300_product_image_write_overloads_revoke_authenticated.sql
-- STRATELOQ-STAGE4D-SECURE-INTERNAL-PRODUCT-ASSET-WRITE-FUNCTIONS
--
-- SECURITY DEFECT (the sibling flagged OUT OF SCOPE by mig_299): the two internal
-- asset-resolution/write overloads
--   public.fn_resolve_product_image(p_tenant uuid, p_product uuid, p_supplier uuid, p_persist boolean)
--   public.fn_resolve_product_image(p_tenant uuid, p_product uuid, p_supplier uuid, p_persist boolean, p_exact_link boolean)
-- are SECURITY DEFINER and EXECUTE-granted to `authenticated`, yet they take an
-- EXPLICIT caller-supplied p_tenant and PERSIST to product_asset_intelligence
-- (INSERT ... ON CONFLICT DO UPDATE) keyed on that p_tenant, and also run
-- fn_ingest_supplier_product_assets (a write). Neither verifies p_tenant = auth.uid().
-- So any authenticated user could invoke these with a FORGED p_tenant and write into
-- another tenant's asset intelligence — a cross-tenant WRITE escalation.
--
-- EXCLUSIVELY INTERNAL (verified before change):
--   * ACL today: postgres=X | authenticated=X | service_role=X  (anon: no grant).
--   * Every in-database caller — fn_storefront_publish, fn_product_image_selftest,
--     fn_product_gallery_selftest, fn_enrich_product_image_from_ebay — is itself
--     SECURITY DEFINER and calls ONLY the display overload fn_resolve_product_image(uuid,text).
--     NONE call these 4-arg / 5-arg write overloads.
--   * The write overloads are invoked only externally by the asset-resolution pipeline
--     via service_role (n8n), never from an end-user/client (authenticated) path.
--
-- SMALLEST SAFE FIX (per task: "if exclusively internal, prefer the smallest safe
-- EXECUTE privilege restriction over adding tenant guards"): REVOKE EXECUTE from
-- `authenticated` (and from PUBLIC, belt-and-suspenders) on both overloads. This removes
-- the forged-tenant client attack surface entirely. It does NOT disrupt legitimate
-- internal processing:
--   * service_role retains EXECUTE (n8n pipeline unaffected).
--   * The internal SECURITY DEFINER callers execute as the owner (postgres), whose
--     EXECUTE is never affected by a client-role revoke — and they call only the
--     display overload anyway.
-- No function body, signature, return contract, Product Asset Lock handling, tenant/
-- country isolation, or supplier-neutral behaviour is changed. Fully reversible
-- (GRANT EXECUTE ... TO authenticated restores prior state). Non-destructive to data.
--
-- The display overload fn_resolve_product_image(uuid,text) is deliberately UNCHANGED:
-- it is the legitimate client RPC and was tenant-authorised in mig_299.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid, uuid, uuid, boolean) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid, uuid, uuid, boolean) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid, uuid, uuid, boolean, boolean) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid, uuid, uuid, boolean, boolean) FROM PUBLIC;
