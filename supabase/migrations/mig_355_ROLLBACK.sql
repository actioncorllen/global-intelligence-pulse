-- mig_355_ROLLBACK.sql
-- 1. Restore the mig_354 trial-autogrant trigger function (without the acceptance-signature
--    condition) from supabase/migrations/mig_354_monetisation_foundation.sql section 5.
-- 2. Then:
DROP FUNCTION IF EXISTS public.get_own_credit_wallet(integer);
DROP FUNCTION IF EXISTS public.fn_psp_card_detached(text);
DROP FUNCTION IF EXISTS public.fn_psp_card_registered(uuid,text,text,text,text,integer,integer);
DROP FUNCTION IF EXISTS public.fn_psp_webhook_finish(text,text);
DROP FUNCTION IF EXISTS public.fn_psp_webhook_begin(text,text,boolean);
DROP TABLE IF EXISTS public.psp_webhook_event;
