-- mig_363_ROLLBACK.sql
-- Reverses mig_363 by dropping the tenant-scoped wrapper. The unscoped helper
-- fn_product_commercial_asset_readiness is untouched by mig_363, so nothing to restore there.
-- NOTE: after this rollback the frontend must NOT reference
-- fn_product_commercial_asset_readiness_owned (revert the frontend change too, or the
-- commerce-actions readiness read returns function-not-found and the badge falls back to
-- the current fail-closed/unavailable behaviour).
DROP FUNCTION IF EXISTS public.fn_product_commercial_asset_readiness_owned(uuid, text);
