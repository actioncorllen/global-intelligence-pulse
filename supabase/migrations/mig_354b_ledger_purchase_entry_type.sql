-- mig_354b: allow the prepaid-wallet funding entry type on the customer credit ledger.
-- Purely additive: every previously valid entry_type remains valid.
ALTER TABLE public.discovery_credit_ledger DROP CONSTRAINT discovery_credit_ledger_entry_type_check;
ALTER TABLE public.discovery_credit_ledger ADD CONSTRAINT discovery_credit_ledger_entry_type_check
  CHECK (entry_type = ANY (ARRAY['GRANT','RESERVE','SETTLE','REFUND','ADJUST','PURCHASE']));
