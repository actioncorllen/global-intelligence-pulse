-- mig_341 ROLLBACK — removes the customer-credit Refresh Discovery scaffold.
-- Safe while inert (no production rows written). Drops functions then tables.
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_status(uuid);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_complete_from_edge(uuid,uuid[],integer,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_is_refund(text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_reconcile(integer);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_complete(uuid,integer,integer,integer,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_fire(uuid,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_dispatch(uuid);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_settle(uuid,integer,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_authorize(uuid);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_reserve(text,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_quote(text);
DROP FUNCTION IF EXISTS public.fn_discovery_credit_balance();
DROP TABLE IF EXISTS public.discovery_refresh_request;
DROP TABLE IF EXISTS public.discovery_credit_ledger;
DROP TABLE IF EXISTS public.discovery_credit_price;
