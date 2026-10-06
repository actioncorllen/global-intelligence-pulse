-- mig_366a — Creative Studio one-click design-family routing (schema)
-- Adds the design-family linkage columns to creative_production_requests so a
-- request routed through the Creative Intelligence design-family system can carry
-- its resolved concept set + design family, exactly as STATIC/VIDEO requests carry
-- their generated_image_job_id / generated_video_job_id. Nullable + additive; no
-- existing column or path is changed.

ALTER TABLE public.creative_production_requests
  ADD COLUMN IF NOT EXISTS generated_concept_set_id uuid,
  ADD COLUMN IF NOT EXISTS resolved_design_family   text;

COMMENT ON COLUMN public.creative_production_requests.generated_concept_set_id IS
  'CI design-family concept set produced for this request (SAAS/business creative). Mirrors generated_image_job_id/generated_video_job_id for the design-family generation system.';
COMMENT ON COLUMN public.creative_production_requests.resolved_design_family IS
  'Design family the Creative Director adaptively resolved for this request (e.g. BOLD_SIGNAL, EDITORIAL_INTELLIGENCE). NULL for product-static / video formats.';
