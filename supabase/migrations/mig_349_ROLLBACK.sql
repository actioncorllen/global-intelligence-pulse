-- mig_349_ROLLBACK.sql
ALTER TABLE public.onboarding_policy DROP COLUMN IF EXISTS comp_refresh_allowance_approved;
