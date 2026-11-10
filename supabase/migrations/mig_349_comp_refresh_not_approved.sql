-- mig_349_comp_refresh_not_approved.sql
-- Stage 5: complimentary Refresh Discovery research is a founder-approved membership
-- benefit, NOT an unlimited provider budget, and the 10-refresh/month default in
-- onboarding_policy is PROVISIONAL and NOT YET APPROVED. Encode that explicitly so no
-- future activation logic can treat the provisional cap as approved. No credits granted,
-- no provider activated; the existing fail-closed credit/price/budget controls are intact
-- (0 active prices / allowances / provider budgets).
ALTER TABLE public.onboarding_policy
  ADD COLUMN IF NOT EXISTS comp_refresh_allowance_approved boolean NOT NULL DEFAULT false;
UPDATE public.onboarding_policy SET comp_refresh_allowance_approved = false WHERE id;
COMMENT ON COLUMN public.onboarding_policy.comp_refresh_allowance_approved IS
  'FALSE until the founder explicitly approves the complimentary refresh allowance (caps + '
  'renewal). Provider calls additionally remain fail-closed (discovery_credit_price inactive) '
  'until the commercial price + Kalodata image-licensing decisions permit paid Refresh Discovery.';
