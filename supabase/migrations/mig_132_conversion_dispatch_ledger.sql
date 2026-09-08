-- PULSE-ECOM-P13-META-CONVERSION-TRACKING-001
-- Durable, provider-generic conversion dispatch ledger.
-- Records the lifecycle of every outbound conversion event to a measurement
-- provider (Meta CAPI first). NEVER stores the CAPI token or raw customer PII.

CREATE TABLE IF NOT EXISTS public.conversion_dispatch_ledger (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  provider           text NOT NULL DEFAULT 'META',
  event_id           text NOT NULL,                 -- canonical Pulse event_id (shared with Pixel)
  commerce_event_uuid uuid,                          -- optional link to public.commerce_events.id
  event_name         text NOT NULL,
  order_id           text,
  state              text NOT NULL DEFAULT 'RECEIVED',
  consent_state      text NOT NULL DEFAULT 'UNKNOWN',
  attempt_count      integer NOT NULL DEFAULT 0,
  max_attempts       integer NOT NULL DEFAULT 5,
  last_attempt_at    timestamptz,
  provider_ref       text,                           -- e.g. Meta fbtrace_id (non-secret)
  provider_response  jsonb NOT NULL DEFAULT '{}'::jsonb, -- non-secret ack only
  event_fingerprint  text,
  error_class        text,
  is_test            boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversion_dispatch_ledger_state_chk CHECK (state IN
    ('RECEIVED','VALIDATED','QUEUED','SENT','ACCEPTED','FAILED','RETRYABLE','REJECTED','DEDUPLICATED')),
  CONSTRAINT conversion_dispatch_ledger_consent_chk CHECK (consent_state IN
    ('GRANTED','DENIED','UNKNOWN')),
  CONSTRAINT conversion_dispatch_ledger_idem UNIQUE (tenant_id, provider, event_id)
);

CREATE INDEX IF NOT EXISTS conversion_dispatch_ledger_tenant_idx
  ON public.conversion_dispatch_ledger (tenant_id, provider, state);
CREATE INDEX IF NOT EXISTS conversion_dispatch_ledger_retry_idx
  ON public.conversion_dispatch_ledger (state) WHERE state IN ('RETRYABLE','QUEUED');

ALTER TABLE public.conversion_dispatch_ledger ENABLE ROW LEVEL SECURITY;
-- RLS on with no permissive policy: only service role / SECURITY DEFINER reach it.
