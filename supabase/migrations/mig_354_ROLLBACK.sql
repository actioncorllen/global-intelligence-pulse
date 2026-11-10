-- mig_354_ROLLBACK.sql — reverts the inert monetisation foundation.
-- Order matters: restore the state machine FIRST (it references payment_method_registry).
-- 1. fn_member_onboarding_state: re-apply the mig_346/351-era definition preserved verbatim in
--    supabase/tests/local-acceptance/04_prod_exact_overrides.sql (fn_member_onboarding_state block).
-- 2. Then:
DROP TRIGGER IF EXISTS trg_member_trial_autogrant ON public.member;
DROP FUNCTION IF EXISTS public.fn_member_trial_autogrant();
DROP FUNCTION IF EXISTS public.fn_grant_founding_member_trial(uuid,text,text);
DROP FUNCTION IF EXISTS public.fn_wallet_credit_purchase(uuid,text,text,jsonb);
DROP FUNCTION IF EXISTS public.get_own_payment_methods();
DROP INDEX IF EXISTS public.dcl_purchase_idem_uniq;
DROP TABLE IF EXISTS public.wallet_price_point;
DROP TABLE IF EXISTS public.payment_method_registry;
ALTER TABLE public.onboarding_policy
  DROP COLUMN IF EXISTS trial_days,
  DROP COLUMN IF EXISTS trial_autogrant_active,
  DROP COLUMN IF EXISTS card_enforcement_active;
