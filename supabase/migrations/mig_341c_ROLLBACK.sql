-- mig_341c ROLLBACK — removes the subscription credit allowance scaffold. Safe while inert.
DROP FUNCTION IF EXISTS public.fn_discovery_grant_subscription_credits_sweep();
DROP FUNCTION IF EXISTS public.fn_discovery_grant_subscription_credits();
DROP INDEX IF EXISTS public.uq_dcl_grant_idem;
DROP TABLE IF EXISTS public.discovery_credit_allowance;
