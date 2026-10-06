-- mig_366c — Re-home the founder-approved Strateloq brand DNA to the real tenant
--
-- The Creative Intelligence design-family path requires active brand DNA for the
-- acting tenant (fn_ci_design_director_plan -> fn_ci_brand_dna_resolve). The
-- founder-approved brand-DNA seed existed only under a non-member fixture tenant
-- (5351ad83-…, used by the design-system selftests), while every real Creative
-- Studio request runs under the real tenant 7c8ddf9d-…, which had no brand DNA.
-- So even once routing was fixed, the design path would fail with
-- 'no_active_brand_dna' for the real user. This re-homes the SAME founder-approved
-- seed values (no new/invented brand content) to the real tenant.
--
-- Idempotent: inserts only if the real tenant has no active brand DNA. Uses
-- existing architecture (creative_brand_dna); no new tables/columns/families.

INSERT INTO public.creative_brand_dna (
  tenant_id, version, colors, typography, logo_treatment, spacing, cta_treatment,
  visual_tone, imagery_rules, dataviz_language, prohibited_treatments,
  platform_safe_zones, approved_asset_classes, is_active, provenance, created_at)
SELECT
  '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
  src.version, src.colors, src.typography, src.logo_treatment, src.spacing, src.cta_treatment,
  src.visual_tone, src.imagery_rules, src.dataviz_language, src.prohibited_treatments,
  src.platform_safe_zones, src.approved_asset_classes, true,
  jsonb_build_object(
    'basis','founder-approved reference direction + observed public site',
    'source','mig_366 re-home from fixture tenant to real Creative Studio tenant',
    'status','seed_awaiting_founder_confirmation'),
  now()
FROM public.creative_brand_dna src
WHERE src.tenant_id = '5351ad83-5ce8-47b1-aef6-23f64daf415f'
  AND src.is_active
  AND NOT EXISTS (
    SELECT 1 FROM public.creative_brand_dna d
    WHERE d.tenant_id = '7c8ddf9d-172c-4a89-a402-bb7066228b61' AND d.is_active)
LIMIT 1;
