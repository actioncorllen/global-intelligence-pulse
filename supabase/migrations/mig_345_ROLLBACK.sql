-- mig_345_ROLLBACK.sql
-- Reverts mig_345_founding_member_comp_grant.sql.
-- Drops the founder-admin COMP grant RPC. Does NOT touch any account_entitlement
-- rows (grants already made remain; they are ordinary COMP rows).

DROP FUNCTION IF EXISTS public.fn_grant_founding_member_entitlement(uuid, text, text);
