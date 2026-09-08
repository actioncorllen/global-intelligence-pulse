-- PULSE-ECOM-P13-META-CAPI-CONNECTION-001
-- Smallest safe delta: extend meta_tracking_config with NON-SECRET verification state.
-- The CAPI access token itself is NEVER stored here; only its secret-reference name.

ALTER TABLE public.meta_tracking_config
  ADD COLUMN IF NOT EXISTS capi_enabled            boolean      NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS tracking_adapter        text,
  ADD COLUMN IF NOT EXISTS integration_method      text,
  ADD COLUMN IF NOT EXISTS verification_state      text         NOT NULL DEFAULT 'UNVERIFIED',
  ADD COLUMN IF NOT EXISTS last_verified_at        timestamptz,
  ADD COLUMN IF NOT EXISTS last_verification_result jsonb       NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS dataset_quality_state   text,
  ADD COLUMN IF NOT EXISTS pixel_state             text,
  ADD COLUMN IF NOT EXISTS updated_at              timestamptz  NOT NULL DEFAULT now();

-- verification_state honest enum backstop (UNVERIFIED / VERIFIED / FAILED / ERROR)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'meta_tracking_config_verif_state_chk') THEN
    ALTER TABLE public.meta_tracking_config
      ADD CONSTRAINT meta_tracking_config_verif_state_chk
      CHECK (verification_state IN ('UNVERIFIED','VERIFIED','FAILED','ERROR'));
  END IF;
END $$;

-- one config row per tenant
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'meta_tracking_config_tenant_uk') THEN
    ALTER TABLE public.meta_tracking_config
      ADD CONSTRAINT meta_tracking_config_tenant_uk UNIQUE (tenant_id);
  END IF;
END $$;

-- Founder (actioncorllen@gmail.com) Meta CAPI configuration — NON-SECRET values only.
-- Dataset: Smart Action Store (954179950185340). Token stays in Supabase Secrets
-- under the reference name META_CAPI_ACCESS_TOKEN (value never stored in the DB).
INSERT INTO public.meta_tracking_config
  (tenant_id, pixel_id, dataset_id, capi_token_ref, domain_verified, state,
   capi_enabled, tracking_adapter, integration_method, verification_state)
VALUES
  ('3d0eb793-685a-4ec2-aea7-8b95fda7112a',
   NULL, '954179950185340', 'META_CAPI_ACCESS_TOKEN', false, 'PARTIAL',
   true, 'META_CAPI_DIRECT', 'DIRECT_INTEGRATION', 'UNVERIFIED')
ON CONFLICT (tenant_id) DO UPDATE
  SET dataset_id        = EXCLUDED.dataset_id,
      capi_token_ref    = EXCLUDED.capi_token_ref,
      capi_enabled      = EXCLUDED.capi_enabled,
      tracking_adapter  = EXCLUDED.tracking_adapter,
      integration_method= EXCLUDED.integration_method,
      updated_at        = now();
