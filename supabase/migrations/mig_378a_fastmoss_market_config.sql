-- mig_378a — FastMoss provider market config (second product-native COMMERCE provider)
--
-- FastMoss New Listed = early/new product-native discovery. Market support is DATA-DRIVEN
-- from FastMoss's own documented regions (NOT Strateloq's 18-market list). IE is NOT a
-- documented FastMoss region -> IE returns UNSUPPORTED_MARKET for FastMoss, never substituted.
-- Reuses the existing discovery_provider_market_config table (provider,market PK).

INSERT INTO public.discovery_provider_market_config
  (provider, market, supported, region, language, currency, capabilities, enabled, last_verified_at, note)
VALUES
  ('FASTMOSS','DE',true,'DE',NULL,'EUR','{"new_listed":true,"endpoint":"/product/v1/rank/newListed"}'::jsonb,true, now(), 'FastMoss New Listed; founder real trial observed (region DE)'),
  ('FASTMOSS','US',true,'US',NULL,'USD','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','GB',true,'GB',NULL,'GBP','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','ID',true,'ID',NULL,'IDR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','VN',true,'VN',NULL,'VND','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','TH',true,'TH',NULL,'THB','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','MY',true,'MY',NULL,'MYR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','PH',true,'PH',NULL,'PHP','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','SG',true,'SG',NULL,'SGD','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','ES',true,'ES',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','MX',true,'MX',NULL,'MXN','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','FR',true,'FR',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','PT',true,'PT',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','NL',true,'NL',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','BE',true,'BE',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','AT',true,'AT',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','PL',true,'PL',NULL,'PLN','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','IT',true,'IT',NULL,'EUR','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','BR',true,'BR',NULL,'BRL','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call'),
  ('FASTMOSS','JP',true,'JP',NULL,'JPY','{"new_listed":true}'::jsonb,true, NULL, 'FastMoss New Listed; unverified until live call')
ON CONFLICT (provider, market) DO UPDATE SET
  supported=EXCLUDED.supported, region=EXCLUDED.region, currency=EXCLUDED.currency,
  capabilities=EXCLUDED.capabilities, enabled=EXCLUDED.enabled,
  note=COALESCE(public.discovery_provider_market_config.note, EXCLUDED.note),
  last_verified_at=COALESCE(public.discovery_provider_market_config.last_verified_at, EXCLUDED.last_verified_at),
  updated_at=now();
