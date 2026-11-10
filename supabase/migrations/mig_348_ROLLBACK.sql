-- mig_348_ROLLBACK.sql
-- Reverts mig_348. If the gate was wired to PostgREST, UNWIRE IT FIRST:
--   ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';
-- then drop the functions.
DROP FUNCTION IF EXISTS public.fn_pre_request_gate();
DROP FUNCTION IF EXISTS public.fn_onboarding_complete(uuid);
