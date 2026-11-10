-- mig_347_ROLLBACK.sql
-- Reverts mig_347. Drops the backfill helper only. Does NOT unlink any member or
-- delete backfill applications/profiles already created (those are legitimate data).
DROP FUNCTION IF EXISTS public.fn_ensure_member_business_profile();
