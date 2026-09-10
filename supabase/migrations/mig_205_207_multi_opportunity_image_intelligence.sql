-- PULSE-ECOM-MULTI-OPPORTUNITY-IMAGE-INTELLIGENCE-001
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as:
--   mig_205  product_asset_intelligence (canonical SOURCE product image contract; separate from creative)
--   mig_206  fn_resolve_product_image (identity + rights aware image resolution; persists asset rows)
--   mig_207  fn_monday_top_opportunities (multi-opportunity portfolio; reads persisted assets in 207b)
-- Image safety: a comparable supplier image can NEVER masquerade as EXACT — hero_eligible requires
-- identity_state=EXACT_PRODUCT AND usable rights; CLOSE_COMPARABLE/CATEGORY images are shown as labelled
-- reference only. Competitor/marketplace creative is never resolved as a hero (SOURCE_PRODUCT_IMAGE only,
-- never PULSE_GENERATED_CREATIVE). Rights preserved (SUPPLIER_PROVIDED / OWNED / REFERENCE_ONLY / UNKNOWN).
-- Portfolio: up to N strongest LEGITIMATE Product x Market opportunities, AVOID excluded, READY_TO_TEST
-- separated from WATCHLIST, quality ranked over popularity (validated local price + low saturation beat
-- raw score), fewer-than-N allowed, no weak fill. Backend/contract only — no Lovable UI in this unit.
-- SECURITY DEFINER, SET search_path='', REVOKE'd from PUBLIC/anon. Full bodies follow.

CREATE TABLE IF NOT EXISTS public.product_asset_intelligence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, product_id uuid NOT NULL,
  supplier_product_id text, source text NOT NULL, source_url text, source_ref text,
  asset_type text NOT NULL DEFAULT 'SOURCE_PRODUCT_IMAGE', rights_state text NOT NULL DEFAULT 'UNKNOWN',
  identity_state text NOT NULL DEFAULT 'UNKNOWN', match_class text, match_confidence text,
  hero_eligible boolean NOT NULL DEFAULT false, is_primary boolean NOT NULL DEFAULT false,
  observed_at timestamptz, provenance jsonb NOT NULL DEFAULT '{}'::jsonb, is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, product_id, source, source_ref));
CREATE INDEX IF NOT EXISTS idx_pai_product ON public.product_asset_intelligence (tenant_id, product_id);
ALTER TABLE public.product_asset_intelligence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_asset_intelligence FROM PUBLIC, anon;

-- fn_resolve_product_image(p_tenant, p_product, p_supplier, p_persist): resolves the best legitimate CJ
--   supplier SOURCE image; identity_state from fn_resolve_supplier_identity; rights_state SUPPLIER_PROVIDED
--   for CJ; hero_eligible = (EXACT_PRODUCT AND usable rights). No supplier image -> {available:false,
--   reason:NO_SUPPLIER_IMAGE}. Full body deployed as mig_206 (see database).
-- fn_monday_top_opportunities(p_tenant, p_limit): DISTINCT ON product best-market pod row (non-AVOID),
--   quality-ranked (decision -> validated-local-price -> sweet-spot -> saturation penalty -> score),
--   capped at p_limit, split READY_TO_TEST / WATCHLIST, each card carrying the persisted primary image
--   (product_asset_intelligence) or IMAGE_UNAVAILABLE. Full body deployed as mig_207b (see database).

-- Real founder preview (manual, NOT published): tenant 7c8ddf9d -> 0 READY_TO_TEST, 4 WATCHLIST
--   (kids nightlight projector FR / digital picture frame GB — both CJ COMPARABLE images, hero_eligible
--   false; red light therapy mask GB / over-door shoe organizer GB — IMAGE_UNAVAILABLE). Quality ranking
--   placed the higher raw-score (89.6) red-light mask BELOW the validated-local-price projector (75.5) and
--   digital frame (74.6). 24/24 acceptance tests PASS. No customer publication; campaign_activation=FALSE;
--   advertising_spend=0.
