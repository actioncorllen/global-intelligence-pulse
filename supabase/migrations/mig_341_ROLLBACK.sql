-- mig_341 ROLLBACK — removes the customer-credit Refresh Discovery scaffold.
-- Safe while inert (no production rows written). Drops functions then tables.
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_settle(uuid,integer,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_reserve(text,text);
DROP FUNCTION IF EXISTS public.fn_discovery_refresh_quote(text);
DROP FUNCTION IF EXISTS public.fn_discovery_credit_balance();
DROP TABLE IF EXISTS public.discovery_refresh_request;
DROP TABLE IF EXISTS public.discovery_credit_ledger;
DROP TABLE IF EXISTS public.discovery_credit_price;
