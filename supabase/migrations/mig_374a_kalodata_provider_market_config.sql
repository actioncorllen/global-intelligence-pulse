-- mig_374a — Kalodata provider market config + COMMERCE lane activation
--
-- ROOT CAUSE CLOSED: the COMMERCE discovery lane was GAP_NO_PRODUCT_NATIVE_PROVIDER
-- because no connected provider could return market product entities WITHOUT a seed.
-- Kalodata's TikTok-Shop product/rank endpoint is product-native and seed-free, proven
-- live for DE (region DE, currency EUR, 0.1 credit / 10 products). This migration fills
-- the EXISTING COMMERCE lane with Kalodata as the product-native provider — no parallel
-- pipeline — with DATA-DRIVEN market support (never prompt/memory).
--
-- Country isolation is a hard invariant: a Strateloq market that Kalodata does not support
-- returns UNSUPPORTED_MARKET; coverage is never treated as zero and never substituted.

-- 1) Authoritative, data-driven provider→market support map.
CREATE TABLE IF NOT EXISTS public.discovery_provider_market_config (
  provider         text        NOT NULL,
  market           text        NOT NULL,
  supported        boolean     NOT NULL DEFAULT true,
  region           text,
  language         text,
  currency         text,
  capabilities     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  enabled          boolean     NOT NULL DEFAULT true,
  last_verified_at timestamptz,
  note             text,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, market)
);

-- Config is backend-authoritative: RLS on, no public policy (SECURITY DEFINER functions
-- and service_role read it; no browser/anon row visibility). Fail closed.
ALTER TABLE public.discovery_provider_market_config ENABLE ROW LEVEL SECURITY;

-- 2) Seed Kalodata-supported TikTok-Shop markets (DE verified live; others supported,
--    unverified until a live call). ON CONFLICT never downgrades an existing live
--    verification timestamp.
INSERT INTO public.discovery_provider_market_config
  (provider, market, supported, region, language, currency, capabilities, enabled, last_verified_at, note)
VALUES
  ('KALODATA','DE',true,'DE','en-US','EUR','{"product_rank":true,"endpoint":"/openapi/v1/tiktok/product/rank"}'::jsonb,true, now(), 'Verified live (founder proof: region DE, product/rank, 0.1 credit/10 products)'),
  ('KALODATA','GB',true,'GB','en-US','GBP','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop UK; unverified until live call'),
  ('KALODATA','US',true,'US','en-US','USD','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop US; unverified until live call'),
  ('KALODATA','FR',true,'FR','en-US','EUR','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop FR; unverified until live call'),
  ('KALODATA','IT',true,'IT','en-US','EUR','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop IT; unverified until live call'),
  ('KALODATA','ES',true,'ES','en-US','EUR','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop ES; unverified until live call'),
  ('KALODATA','IE',true,'IE','en-US','EUR','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop IE; unverified until live call'),
  ('KALODATA','MY',true,'MY','en-US','MYR','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop MY; unverified until live call'),
  ('KALODATA','PH',true,'PH','en-US','PHP','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop PH; unverified until live call'),
  ('KALODATA','SG',true,'SG','en-US','SGD','{"product_rank":true}'::jsonb,true, NULL, 'TikTok Shop SG; unverified until live call')
ON CONFLICT (provider, market) DO UPDATE SET
  supported        = EXCLUDED.supported,
  region           = EXCLUDED.region,
  language         = EXCLUDED.language,
  currency         = EXCLUDED.currency,
  capabilities     = EXCLUDED.capabilities,
  enabled          = EXCLUDED.enabled,
  note             = COALESCE(public.discovery_provider_market_config.note, EXCLUDED.note),
  last_verified_at = COALESCE(public.discovery_provider_market_config.last_verified_at, EXCLUDED.last_verified_at),
  updated_at       = now();

-- 3) Fill the existing COMMERCE lane with Kalodata (was PRODUCT_NATIVE_GAP).
UPDATE public.discovery_lane_registry
SET provider        = 'KALODATA',
    capability_class = 'DISCOVERY_CAPABLE',
    discovery_mode  = 'AUTONOMOUS',
    availability    = 'AVAILABLE',
    note            = 'Kalodata product-native TikTok-Shop commerce discovery (POST /openapi/v1/tiktok/product/rank, secret-key header). Market support is data-driven via discovery_provider_market_config. Discovers candidates only; never decides opportunity.',
    updated_at      = now()
WHERE lane_key = 'COMMERCE';
