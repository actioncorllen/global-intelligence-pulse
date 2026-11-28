-- STRATELOQ — BE350 P2: Product Discovery-only launch plan configuration. PREPARED,
-- NOT applied. Production remains df1e2f6 (BE336). 0 paid calls. NO price invented,
-- NO plan activated, NO checkout opened, NO live subscription.
--
-- CONTEXT (live state, BE349/BE350): the launch plan `ecommerce_monthly`
-- ("Product Discovery — Monthly") carries the COMP entitlements (founder/comp grants)
-- but has provider=NULL and NO plan_feature_allowance rows, so its entitlement
-- controls are undefined. The three priced tiers (strateloq_starter/growth/pro) each
-- have a complete 5-feature allowance set. This migration gives the launch plan the
-- correct Product Discovery-only entitlement mapping, reusing the existing feature
-- keys + limit model (the BE348-verified billing engine is reused, not rebuilt).
--
-- DISCOVERY-ONLY POSTURE (the part that is launch-scope-correct and non-negotiable):
--   research_actions  : ENABLED  (core discovery — fresh product research)
--   tracked_products  : ENABLED  (save / monitor)
--   problem_journeys  : ENABLED  (Problem-to-Product premium research)
--   product_images    : 0        (creative image generation is FOUNDER-ONLY at launch)
--   video_metadata    : 0        (GPD.07 social video is OFF)
-- The monthly_limit numbers for the three ENABLED features are a FOUNDER-ADJUSTABLE
-- DEFAULT mirrored from the strateloq_growth tier; the founder confirms/tunes them at
-- launch. The PRICE is intentionally left unset (provider_price_id / _live / amount
-- unchanged) — a live price is created at 9-Dec registration, not here. active stays
-- false (not sellable) and pilot_active stays true (public checkout closed).

BEGIN;

-- 1) Declare the launch plan bills via Stripe. No price set, not activated.
UPDATE public.billing_plan
   SET provider = 'stripe', updated_at = now()
 WHERE plan_code = 'ecommerce_monthly'
   AND provider IS DISTINCT FROM 'stripe';

-- 2) Correct Product Discovery-only entitlement mapping (idempotent upsert).
INSERT INTO public.plan_feature_allowance (plan_code, feature, limit_kind, monthly_limit, display_label, updated_at)
VALUES
  ('ecommerce_monthly', 'research_actions', 'consumable', 100, 'Fresh product research actions', now()),
  ('ecommerce_monthly', 'tracked_products', 'concurrent',  75, 'Tracked products',               now()),
  ('ecommerce_monthly', 'problem_journeys', 'consumable',   5, 'Problem-to-Product journeys',     now()),
  ('ecommerce_monthly', 'product_images',   'consumable',   0, 'Product image requests',          now()),
  ('ecommerce_monthly', 'video_metadata',   'consumable',   0, 'Video metadata requests',         now())
ON CONFLICT (plan_code, feature) DO UPDATE
   SET limit_kind    = EXCLUDED.limit_kind,
       monthly_limit = EXCLUDED.monthly_limit,
       display_label = EXCLUDED.display_label,
       updated_at    = now();

-- 3) End-state assertions (fail the migration if the config is wrong). These do NOT
--    change the config; they verify it. Prices/activation are deliberately NOT set.
DO $$
DECLARE
  v_provider text; v_active boolean; v_live text; v_amount integer;
  v_feat int; v_pi int; v_vm int; v_ra int;
BEGIN
  SELECT provider, active, provider_price_id_live, amount_minor
    INTO v_provider, v_active, v_live, v_amount
  FROM public.billing_plan WHERE plan_code='ecommerce_monthly';
  IF v_provider IS DISTINCT FROM 'stripe' THEN RAISE EXCEPTION 'BE350: provider not stripe (%)', v_provider; END IF;
  IF v_active IS DISTINCT FROM false THEN RAISE EXCEPTION 'BE350: launch plan must NOT be active'; END IF;
  IF v_live IS NOT NULL THEN RAISE EXCEPTION 'BE350: no live price may be set here'; END IF;

  SELECT count(*) INTO v_feat FROM public.plan_feature_allowance WHERE plan_code='ecommerce_monthly';
  IF v_feat <> 5 THEN RAISE EXCEPTION 'BE350: expected 5 feature rows, got %', v_feat; END IF;

  SELECT monthly_limit INTO v_pi FROM public.plan_feature_allowance WHERE plan_code='ecommerce_monthly' AND feature='product_images';
  SELECT monthly_limit INTO v_vm FROM public.plan_feature_allowance WHERE plan_code='ecommerce_monthly' AND feature='video_metadata';
  SELECT monthly_limit INTO v_ra FROM public.plan_feature_allowance WHERE plan_code='ecommerce_monthly' AND feature='research_actions';
  IF v_pi <> 0 THEN RAISE EXCEPTION 'BE350: product_images must be 0 (creative is founder-only)'; END IF;
  IF v_vm <> 0 THEN RAISE EXCEPTION 'BE350: video_metadata must be 0 (GPD.07 OFF)'; END IF;
  IF v_ra <= 0 THEN RAISE EXCEPTION 'BE350: research_actions must be enabled (>0)'; END IF;

  RAISE NOTICE 'BE350 plan config OK: ecommerce_monthly provider=stripe, inactive, no live price, 5 features, discovery-only (images/video=0).';
END $$;

COMMIT;
