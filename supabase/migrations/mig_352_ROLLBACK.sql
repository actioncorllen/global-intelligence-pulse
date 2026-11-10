-- mig_352_ROLLBACK.sql
-- Reverts mig_352. NOTE: redeploy the pre-guard Edge Functions FIRST (prepare-product,
-- translate-text, product-image-import, commercial-image-generate, meta-insights-reader),
-- otherwise their guard RPC call fails and they DENY everything (fail closed by design).
DROP FUNCTION IF EXISTS public.fn_edge_onboarding_allowed(uuid);
